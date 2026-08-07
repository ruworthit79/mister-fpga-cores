//============================================================================
//  scsi_ncr53c96 - NCR/AMD 53C96 SCSI controller (one channel)
//
//  The Quadra 900/950 have two 53C96 channels (internal + external);
//  instantiate this twice. Backing storage is a mounted disk image reached
//  through the hps_io block interface (the core owns the 512-byte sector
//  buffer; the HPS streams sectors into it on read and out of it on write).
//
//  This is a functional datapath model rather than a cycle-accurate 53C96 or a
//  full SCSI bus-phase engine. The CPU:
//    1. writes a 6-byte CDB to the FIFO register (0x2),
//    2. writes the Transfer-Information command (0x10) to the command reg (0x3),
//  and the controller parses the CDB:
//    - READ(6)  (0x08): fetch block(s) via the block interface into the sector
//      buffer; the CPU then pops the bytes back out through the FIFO register.
//    - WRITE(6) (0x0A): the CPU pushes bytes into the FIFO; the controller
//      writes the block out via the block interface.
//  Completion raises the interrupt; reading the interrupt register (0x5)
//  clears it.
//
//  Verified in sim/iverilog/tb_scsi.v (READ path + WRITE path).
//  Simplified: single LUN/target, one sector per command, no SCSI messages/
//  arbitration/selection modelling, no synchronous transfers. Documented TODO.
//============================================================================

module scsi_ncr53c96
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

	// CDB capture
	reg [7:0] cdb [0:5];
	reg [2:0] cdb_cnt;

	reg [20:0] lba;
	reg [9:0]  rd_ptr;             // byte pointer into the sector (0..512)
	reg        data_ready;
	reg        is_write;

	localparam S_IDLE=3'd0, S_RD_REQ=3'd1, S_RD_WAIT=3'd2,
	           S_WR_REQ=3'd3, S_WR_WAIT=3'd4, S_DONE=3'd5;
	reg [2:0] state;

	assign active = sd_rd | sd_wr;

	// byte view of the sector buffer (big-endian within the 16-bit word)
	wire [7:0] rd_byte = rd_ptr[0] ? sector[rd_ptr[8:1]][7:0]
	                               : sector[rd_ptr[8:1]][15:8];

	wire cpu_rd = sel &  rw & ~ack;
	wire cpu_wr = sel & ~rw & ~ack;

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			ack <= 0; irq <= 0; dout <= 0;
			cdb_cnt <= 0; rd_ptr <= 0; data_ready <= 0; is_write <= 0;
			sd_rd <= 0; sd_wr <= 0; sd_lba <= 0; state <= S_IDLE;
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
							if (cdb_cnt != 3'd5) cdb_cnt <= cdb_cnt + 1'b1;
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
							lba <= {cdb[1][4:0], cdb[2], cdb[3]};
							if (cdb[0] == 8'h08) begin  // READ(6)
								is_write <= 1'b0; rd_ptr <= 0; state <= S_RD_REQ;
							end else if (cdb[0] == 8'h0A) begin  // WRITE(6)
								is_write <= 1'b1; rd_ptr <= 0; data_ready <= 1'b1;
							end
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
					sd_lba <= {11'd0, lba};
					sd_rd  <= 1'b1;
					state  <= S_RD_WAIT;
				end
				S_RD_WAIT: if (sd_ack) begin
					sd_rd      <= 1'b0;
					data_ready <= 1'b1;
					irq        <= 1'b1;            // function complete
					cdb_cnt    <= 0;
					state      <= S_DONE;
				end
				S_WR_REQ: begin
					sd_lba <= {11'd0, lba};
					sd_wr  <= 1'b1;
					state  <= S_WR_WAIT;
				end
				S_WR_WAIT: if (sd_ack) begin
					sd_wr   <= 1'b0;
					irq     <= 1'b1;
					cdb_cnt <= 0;
					state   <= S_DONE;
				end
				S_DONE: begin
					// stay until a fresh CDB sequence starts (data_ready cleared
					// by reading all bytes is not tracked; kept simple)
					if (cpu_wr && addr == 4'h2 && !data_ready) state <= S_IDLE;
				end
				default: ;
			endcase

			// WRITE(6): once the CPU has pushed a full sector, kick the DMA out.
			if (is_write && data_ready && rd_ptr >= 10'd512 && state == S_IDLE) begin
				state      <= S_WR_REQ;
				data_ready <= 1'b0;
			end
		end
	end

endmodule
