//============================================================================
//  scsi_ncr53c96 - NCR/AMD 53C96 SCSI controller (one channel)
//
//  The Quadra 900/950 have two 53C96 channels (internal + external);
//  instantiate this twice. Backing storage is a mounted disk/CD image reached
//  through the hps_io block interface (the core owns the 512-byte sector
//  buffer; the HPS streams sectors into it on read and out of it on write).
//
//  This is a functional SCSI *target* model rather than a cycle-accurate 53C96
//  or a full SCSI bus-phase engine. The CPU:
//    1. writes a CDB (6 or 10 bytes) to the FIFO register (0x2),
//    2. writes the Transfer-Information command (0x10) to the command reg (0x3),
//  and the controller parses cdb[0] and acts as an implied single target.
//
//  Device personality (parameter IS_CDROM):
//    IS_CDROM=0 : direct-access hard disk. INQUIRY device type 0x00,
//                 512-byte logical blocks (1 hps_io sector per block),
//                 read/write.
//    IS_CDROM=1 : CD-ROM. INQUIRY device type 0x05, removable (RMB) and
//                 read-only, 2048-byte logical blocks. Each CD block maps to
//                 4 consecutive 512-byte hps_io sectors: CD LBA n reaches
//                 sd_lba = n*4 .. n*4+3.
//
//  Command set (parsed from cdb[0]):
//    TEST UNIT READY (0x00)        GOOD status + irq, no data.
//    REZERO/SEEK (0x01,0x0B,0x2B)  accept: GOOD + irq, no data.
//    REQUEST SENSE (0x03)          18-byte fixed-format sense (byte0=0x70,
//                                  byte2=sense key, byte7=0x0A). Clears sense.
//    READ(6)  (0x08)               read block(s); lba={cdb1[4:0],cdb2,cdb3},
//                                  len=cdb4 (0 => 256 blocks).
//    WRITE(6) (0x0A)               disk only; write block(s) (len as READ(6)).
//    INQUIRY (0x12)                standard 36-byte inquiry data; honors the
//                                  allocation length in cdb4 (CPU reads it).
//    MODE SELECT(6) (0x15)         accept: GOOD + irq, no data.
//    MODE SENSE(6) (0x1A)          4-byte mode parameter header (block
//                                  descriptor length 0); enough to probe.
//    START STOP UNIT (0x1B)        accept: GOOD + irq, no data.
//    PREVENT/ALLOW REMOVAL (0x1E)  accept: GOOD + irq, no data.
//    READ CAPACITY (0x25)          8 bytes: last-LBA(4 BE) + block-size(4 BE);
//                                  block size 512(disk)/2048(CD), last-LBA from
//                                  img_size.
//    READ(10)  (0x28)              read block(s); lba=cdb2..cdb5, len=cdb7..8.
//    WRITE(10) (0x2A)              disk only; write block(s) (lba/len as R10).
//    READ TOC (0x43)  [CD only]    minimal single-data-track TOC + lead-out.
//    unknown opcodes               GOOD status + irq, no data (keep boot
//                                  moving). Documented deliberate leniency.
//
//  RESPONSE / DATA path. Commands that return parameter data (INQUIRY,
//  READ CAPACITY, MODE SENSE, REQUEST SENSE, READ TOC) fill the sector buffer
//  with their response bytes (big-endian within each 16-bit word, matching the
//  rd_byte view) then behave exactly like a data-in: data_ready is set, irq is
//  raised (function complete), and the CPU pops the bytes in order through the
//  FIFO register (0x2), reusing rd_ptr/rd_byte.
//
//  MULTI-SECTOR STREAMING. The sector buffer holds one 512-byte hps_io sector,
//  so multi-block transfers stream sector-by-sector. Reads: each sector is
//  fetched, irq is raised, and the CPU drains its 512 bytes through the FIFO;
//  the controller then advances sd_lba and fetches the next sector, repeating
//  until sectors-remaining hits zero (one completion interrupt per sector).
//  Writes: the CPU pushes 512 bytes, the controller writes the sector out and
//  raises irq, then the CPU pushes the next sector's 512 bytes, and so on.
//
//  CD write attempts (read-only media) fail with DATA PROTECT (sense key 0x07)
//  and raise irq without transferring data.
//
//  Verified in sim/iverilog/tb_scsi.v (disk + CD instances: READ(6)/WRITE(6)
//  single sector, INQUIRY, TEST UNIT READY, READ CAPACITY, READ(10) multi-
//  block across a sector boundary, and CD READ TOC).
//  Simplified: single LUN/target, no SCSI messages/arbitration/selection
//  modelling, no synchronous transfers, no real status byte (irq == complete).
//  Documented TODO.
//============================================================================

module scsi_ncr53c96
#(
	parameter IS_CDROM = 0            // 0 = direct-access disk, 1 = CD-ROM
)
(
	input             clk,
	input             reset,

	// CPU register interface
	input             sel,
	input      [3:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,          // 1 = read
	output reg        ack,
	output reg        irq,

	// hps_io block interface (core owns the sector buffer)
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg        sd_rd,
	output reg        sd_wr,
	input             sd_ack,
	input      [13:0] sd_buff_addr,
	input      [15:0] sd_buff_dout, // HPS -> core (read fill)
	output     [15:0] sd_buff_din,  // core -> HPS (write drain)
	input             sd_buff_wr,

	output            active        // drive activity LED
);

	// 512-byte sector buffer as 256 x 16-bit
	reg [15:0] sector [0:255];
	assign sd_buff_din = sector[sd_buff_addr[7:0]];

	// CDB capture (up to 10 bytes for READ(10)/WRITE(10))
	reg [7:0] cdb [0:9];
	reg [3:0] cdb_cnt;

	reg [31:0] cur_lba;            // current hps_io 512-byte sector address
	reg [17:0] sectors_left;       // 512-byte sectors still to transfer
	reg [9:0]  rd_ptr;             // byte pointer into the sector (0..512)
	reg        data_ready;
	reg        is_write;
	reg [7:0]  sense_key;          // for REQUEST SENSE

	localparam S_IDLE=3'd0, S_RD_REQ=3'd1, S_RD_WAIT=3'd2,
	           S_WR_REQ=3'd3, S_WR_WAIT=3'd4, S_DONE=3'd5;
	reg [2:0] state;

	assign active = sd_rd | sd_wr;

	// byte view of the sector buffer (big-endian within the 16-bit word)
	wire [7:0] rd_byte = rd_ptr[0] ? sector[rd_ptr[8:1]][7:0]
	                               : sector[rd_ptr[8:1]][15:8];

	wire cpu_rd = sel &  rw & ~ack;
	wire cpu_wr = sel & ~rw & ~ack;

	// ---- CDB field decode (combinational) ----
	wire [20:0] lba6    = {cdb[1][4:0], cdb[2], cdb[3]};
	wire [31:0] lba6_32 = {11'd0, lba6};
	wire [31:0] lba10   = {cdb[2], cdb[3], cdb[4], cdb[5]};
	wire [15:0] blk6    = (cdb[4] == 8'h00) ? 16'd256 : {8'h00, cdb[4]};
	wire [15:0] blk10   = {cdb[7], cdb[8]};

	// disk => 1 hps_io sector/block, CD => 4 hps_io sectors/block
	wire [31:0] start6  = IS_CDROM ? {lba6_32[29:0], 2'b00} : lba6_32;
	wire [31:0] start10 = IS_CDROM ? {lba10[29:0],   2'b00} : lba10;
	wire [17:0] sec6    = IS_CDROM ? {blk6,  2'b00} : {2'b00, blk6};
	wire [17:0] sec10   = IS_CDROM ? {blk10, 2'b00} : {2'b00, blk10};

	// READ CAPACITY / TOC geometry (block count from image size in bytes)
	wire [31:0] blk_count = IS_CDROM ? img_size[42:11] : img_size[40:9];
	wire [31:0] cap_lba   = blk_count - 1'b1;
	wire [15:0] cap_bsize = IS_CDROM ? 16'h0800 : 16'h0200;  // 2048 / 512

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			ack <= 0; irq <= 0; dout <= 0;
			cdb_cnt <= 0; rd_ptr <= 0; data_ready <= 0; is_write <= 0;
			sd_rd <= 0; sd_wr <= 0; sd_lba <= 0; state <= S_IDLE;
			cur_lba <= 0; sectors_left <= 0; sense_key <= 0;
		end else begin
			ack <= 1'b0;

			// HPS fills the sector buffer on reads (block-interface stream)
			if (sd_buff_wr) sector[sd_buff_addr[7:0]] <= sd_buff_dout;

			// ---------------- CPU register access ----------------
			if (cpu_wr) begin
				ack <= 1'b1;
				case (addr)
					4'h2: begin                        // FIFO: CDB byte or write data
						if (state == S_IDLE && !data_ready) begin
							cdb[cdb_cnt] <= din;
							if (cdb_cnt != 4'd9) cdb_cnt <= cdb_cnt + 1'b1;
						end else if (is_write) begin
							// push write data into the sector buffer
							if (rd_ptr[0]) sector[rd_ptr[8:1]][7:0]  <= din;
							else           sector[rd_ptr[8:1]][15:8] <= din;
							rd_ptr <= rd_ptr + 1'b1;
						end
					end
					4'h3: begin                        // Command
						if (din == 8'h01 || din == 8'h02) begin  // Flush FIFO / reset
							state <= S_IDLE; data_ready <= 1'b0;
							cdb_cnt <= 0; rd_ptr <= 0; is_write <= 1'b0;
						end else if (din == 8'h10) begin  // Transfer Information
							rd_ptr <= 0; cdb_cnt <= 0;
							case (cdb[0])
								// ---- no-data / GOOD status commands ----
								8'h00: begin              // TEST UNIT READY
									sense_key <= 8'h00; irq <= 1'b1; state <= S_DONE;
								end
								8'h01, 8'h0B, 8'h2B,      // REZERO / SEEK(6) / SEEK(10)
								8'h15, 8'h1B, 8'h1E: begin// MODE SELECT / START STOP / PREVENT
									irq <= 1'b1; state <= S_DONE;
								end

								// ---- REQUEST SENSE (0x03): 18-byte fixed format ----
								8'h03: begin
									sector[0] <= {8'h70, 8'h00};
									sector[1] <= {sense_key, 8'h00};
									sector[2] <= 16'h0000;
									sector[3] <= 16'h000A;       // additional length = 10
									sector[4] <= 16'h0000; sector[5] <= 16'h0000;
									sector[6] <= 16'h0000; sector[7] <= 16'h0000;
									sector[8] <= 16'h0000;
									sense_key  <= 8'h00;         // clear on read
									data_ready <= 1'b1; irq <= 1'b1; state <= S_DONE;
								end

								// ---- INQUIRY (0x12): standard 36-byte data ----
								8'h12: begin
									// b0 device type, b1 RMB (0x80 if removable)
									sector[0] <= {IS_CDROM ? 8'h05 : 8'h00,
									              IS_CDROM ? 8'h80 : 8'h00};
									sector[1] <= {8'h02, 8'h02};  // version, response fmt
									sector[2] <= {8'h1F, 8'h00};  // addl length=31, flags
									sector[3] <= 16'h0000;
									// bytes 8..15 vendor "APPLE   "
									sector[4] <= {8'h41, 8'h50}; // A P
									sector[5] <= {8'h50, 8'h4C}; // P L
									sector[6] <= {8'h45, 8'h20}; // E ' '
									sector[7] <= {8'h20, 8'h20}; // ' ' ' '
									// bytes 16..31 product id (16 chars)
									sector[8]  <= IS_CDROM ? 16'h4344 : 16'h4D61; // "CD"/"Ma"
									sector[9]  <= IS_CDROM ? 16'h2D52 : 16'h6369; // "-R"/"ci"
									sector[10] <= IS_CDROM ? 16'h4F4D : 16'h6E74; // "OM"/"nt"
									sector[11] <= IS_CDROM ? 16'h2043 : 16'h6F73; // " C"/"os"
									sector[12] <= IS_CDROM ? 16'h4455 : 16'h6820; // "DU"/"h "
									sector[13] <= IS_CDROM ? 16'h2D35 : 16'h566F; // "-5"/"Vo"
									sector[14] <= IS_CDROM ? 16'h3553 : 16'h6C20; // "5S"/"l "
									sector[15] <= 16'h2020;                       // "  "
									// bytes 32..35 revision "1.0 "
									sector[16] <= {8'h31, 8'h2E}; // 1 .
									sector[17] <= {8'h30, 8'h20}; // 0 ' '
									data_ready <= 1'b1; irq <= 1'b1; state <= S_DONE;
								end

								// ---- MODE SENSE(6) (0x1A): 4-byte header ----
								8'h1A: begin
									sector[0] <= 16'h0300;  // mode data len=3, medium type=0
									sector[1] <= 16'h0000;  // dev-specific=0, blk desc len=0
									data_ready <= 1'b1; irq <= 1'b1; state <= S_DONE;
								end

								// ---- READ CAPACITY (0x25): 8 bytes ----
								8'h25: begin
									sector[0] <= cap_lba[31:16];
									sector[1] <= cap_lba[15:0];
									sector[2] <= 16'h0000;
									sector[3] <= cap_bsize;
									data_ready <= 1'b1; irq <= 1'b1; state <= S_DONE;
								end

								// ---- READ(6) / READ(10) ----
								8'h08: begin
									is_write <= 1'b0;
									cur_lba <= start6; sectors_left <= sec6;
									if (sec6 == 18'd0) begin irq <= 1'b1; state <= S_DONE; end
									else state <= S_RD_REQ;
								end
								8'h28: begin
									is_write <= 1'b0;
									cur_lba <= start10; sectors_left <= sec10;
									if (sec10 == 18'd0) begin irq <= 1'b1; state <= S_DONE; end
									else state <= S_RD_REQ;
								end

								// ---- WRITE(6) / WRITE(10) (disk only) ----
								8'h0A: begin
									if (IS_CDROM) begin
										sense_key <= 8'h07;   // DATA PROTECT
										irq <= 1'b1; state <= S_DONE;
									end else begin
										is_write <= 1'b1;
										cur_lba <= start6; sectors_left <= sec6;
										if (sec6 == 18'd0) begin irq <= 1'b1; state <= S_DONE; end
										else data_ready <= 1'b1;   // collect bytes in S_IDLE
									end
								end
								8'h2A: begin
									if (IS_CDROM) begin
										sense_key <= 8'h07;   // DATA PROTECT
										irq <= 1'b1; state <= S_DONE;
									end else begin
										is_write <= 1'b1;
										cur_lba <= start10; sectors_left <= sec10;
										if (sec10 == 18'd0) begin irq <= 1'b1; state <= S_DONE; end
										else data_ready <= 1'b1;
									end
								end

								// ---- READ TOC (0x43): CD only, minimal TOC ----
								8'h43: begin
									if (IS_CDROM) begin
										sector[0] <= 16'h0012;  // TOC data length = 18
										sector[1] <= 16'h0101;  // first track=1, last track=1
										sector[2] <= 16'h0004;  // reserved, ADR/ctrl=data track
										sector[3] <= 16'h0100;  // track#=1, reserved
										sector[4] <= 16'h0000;  // track1 start addr (hi)
										sector[5] <= 16'h0000;  // track1 start addr (lo)
										sector[6] <= 16'h0004;  // lead-out reserved, ADR/ctrl
										sector[7] <= 16'hAA00;  // lead-out track 0xAA, reserved
										sector[8] <= blk_count[31:16]; // lead-out addr (hi)
										sector[9] <= blk_count[15:0];  // lead-out addr (lo)
										data_ready <= 1'b1;
									end
									irq <= 1'b1; state <= S_DONE;
								end

								// ---- unknown: GOOD status, keep boot moving ----
								default: begin irq <= 1'b1; state <= S_DONE; end
							endcase
						end
					end
					4'h4: sd_lba[7:0]  <= din;         // Dest Bus ID (unused here)
					default: ;
				endcase
			end else if (cpu_rd) begin
				ack <= 1'b1;
				case (addr)
					4'h2: begin                        // FIFO read: next sector byte
						dout   <= rd_byte;
						rd_ptr <= rd_ptr + 1'b1;
					end
					4'h4: dout <= {3'b0, data_ready, 2'b0, |{sd_rd,sd_wr}, irq};  // Status
					4'h5: begin dout <= irq ? 8'h18 : 8'h00; irq <= 1'b0; end     // Interrupt (clear)
					4'h7: dout <= 8'd0;                // FIFO flags
					default: dout <= 8'h00;
				endcase
			end

			// ---------------- block-interface DMA ----------------
			case (state)
				S_RD_REQ: begin
					sd_lba <= cur_lba;
					sd_rd  <= 1'b1;
					state  <= S_RD_WAIT;
				end
				S_RD_WAIT: if (sd_ack) begin
					sd_rd        <= 1'b0;
					data_ready   <= 1'b1;
					irq          <= 1'b1;           // sector ready / function complete
					cdb_cnt      <= 0;
					sectors_left <= sectors_left - 1'b1;
					cur_lba      <= cur_lba + 1'b1;
					state        <= S_DONE;
				end
				S_WR_REQ: begin
					sd_lba <= cur_lba;
					sd_wr  <= 1'b1;
					state  <= S_WR_WAIT;
				end
				S_WR_WAIT: if (sd_ack) begin
					sd_wr        <= 1'b0;
					irq          <= 1'b1;
					cdb_cnt      <= 0;
					sectors_left <= sectors_left - 1'b1;
					cur_lba      <= cur_lba + 1'b1;
					if (sectors_left <= 18'd1) begin
						state <= S_DONE;            // last sector written
					end else begin
						rd_ptr     <= 0;            // collect the next sector's bytes
						data_ready <= 1'b1;
						state      <= S_IDLE;
					end
				end
				S_DONE: begin
					// multi-sector read: once the CPU has drained this sector and
					// more remain, fetch the next one transparently.
					if (!is_write && data_ready && sectors_left != 18'd0
					    && rd_ptr >= 10'd512) begin
						rd_ptr     <= 0;
						data_ready <= 1'b0;
						state      <= S_RD_REQ;
					end
				end
				default: ;
			endcase

			// WRITE: once the CPU has pushed a full sector, kick the DMA out.
			if (is_write && data_ready && rd_ptr >= 10'd512 && state == S_IDLE) begin
				state      <= S_WR_REQ;
				data_ready <= 1'b0;
			end
		end
	end

endmodule
