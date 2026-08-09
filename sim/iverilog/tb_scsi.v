//============================================================================
//  tb_scsi - Icarus testbench for the NCR 53C96 SCSI target model
//
//  Two DUT instances share one behavioral HPS block responder each, both
//  backed by a common disk[] model (256 words per 512-byte sector, keyed by
//  sd_lba). The CD instance (IS_CDROM=1) maps each 2048-byte CD block to four
//  512-byte sectors, so its READ path walks the same disk[] model 4 sectors
//  at a time.
//
//  Coverage:
//    disk : READ(6) LBA=5 single sector       (backward compatible)
//    disk : WRITE(6) LBA=6 single sector      (backward compatible)
//    disk : INQUIRY (device type 0x00, "APPLE")
//    disk : TEST UNIT READY (irq / GOOD)
//    disk : READ CAPACITY (block size 512, last-LBA from img_size)
//    disk : READ(10) 2-block transfer across a sector boundary
//    cd   : INQUIRY (device type 0x05, "APPLE")
//    cd   : READ CAPACITY (block size 2048, last-LBA from img_size)
//    cd   : READ TOC (header + track 1 + lead-out)
//============================================================================
`timescale 1ns/1ps

module tb_scsi;
	reg         clk = 0, reset = 1;

	// ---- disk DUT (IS_CDROM=0) CPU + HPS signals ----
	reg         sel = 0, rw = 1;
	reg  [3:0]  addr = 0;
	reg  [7:0]  din = 0;
	wire [7:0]  dout;
	wire        ack, irq, active;

	wire [31:0] sd_lba;
	wire        sd_rd, sd_wr;
	reg         sd_ack = 0;
	reg  [13:0] sd_buff_addr = 0;
	reg  [15:0] sd_buff_dout = 0;
	wire [15:0] sd_buff_din;
	reg         sd_buff_wr = 0;

	// ---- CD DUT (IS_CDROM=1) CPU + HPS signals ----
	reg         selc = 0, rwc = 1;
	reg  [3:0]  addrc = 0;
	reg  [7:0]  dinc = 0;
	wire [7:0]  doutc;
	wire        ackc, irqc, activec;

	wire [31:0] sd_lbac;
	wire        sd_rdc, sd_wrc;
	reg         sd_ackc = 0;
	reg  [13:0] sd_buff_addrc = 0;
	reg  [15:0] sd_buff_doutc = 0;
	wire [15:0] sd_buff_dinc;
	reg         sd_buff_wrc = 0;

	integer errors = 0;
	reg [7:0] q;

	scsi_ncr53c96 #(.IS_CDROM(0)) dut (
		.clk(clk), .reset(reset),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .rw(rw), .ack(ack), .irq(irq),
		.img_mounted(1'b1), .img_readonly(1'b0), .img_size(64'd1048576),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr), .active(active)
	);

	scsi_ncr53c96 #(.IS_CDROM(1)) dutc (
		.clk(clk), .reset(reset),
		.sel(selc), .addr(addrc), .din(dinc), .dout(doutc), .rw(rwc), .ack(ackc), .irq(irqc),
		.img_mounted(1'b1), .img_readonly(1'b1), .img_size(64'd1048576),
		.sd_lba(sd_lbac), .sd_rd(sd_rdc), .sd_wr(sd_wrc), .sd_ack(sd_ackc),
		.sd_buff_addr(sd_buff_addrc), .sd_buff_dout(sd_buff_doutc),
		.sd_buff_din(sd_buff_dinc), .sd_buff_wr(sd_buff_wrc), .active(activec)
	);

	always #10 clk = ~clk;

	// ---- shared disk model ----
	reg [15:0] disk [0:4095];

	// ---- behavioral HPS block responder for the disk DUT ----
	integer hi, hstate;
	always @(posedge clk) begin
		if (reset) begin hstate <= 0; sd_ack <= 0; sd_buff_wr <= 0; end
		else begin
			sd_buff_wr <= 0; sd_ack <= 0;
			case (hstate)
				0: begin hi <= 0; if (sd_rd) hstate <= 1; else if (sd_wr) hstate <= 2; end
				1: begin  // fill core buffer from disk (read)
					sd_buff_addr <= hi[7:0];
					sd_buff_dout <= disk[sd_lba*256 + hi];
					sd_buff_wr   <= 1'b1;
					if (hi == 255) hstate <= 3; else hi <= hi + 1;
				end
				2: begin sd_buff_addr <= hi[7:0]; hstate <= 5; end   // drain: set addr
				5: begin  // capture core buffer -> disk (write)
					disk[sd_lba*256 + hi] <= sd_buff_din;
					if (hi == 255) hstate <= 3; else begin hi <= hi + 1; hstate <= 2; end
				end
				3: begin sd_ack <= 1'b1; hstate <= 4; end
				4: if (!sd_rd && !sd_wr) hstate <= 0;
			endcase
		end
	end

	// ---- behavioral HPS block responder for the CD DUT (same disk model) ----
	integer hic, hstatec;
	always @(posedge clk) begin
		if (reset) begin hstatec <= 0; sd_ackc <= 0; sd_buff_wrc <= 0; end
		else begin
			sd_buff_wrc <= 0; sd_ackc <= 0;
			case (hstatec)
				0: begin hic <= 0; if (sd_rdc) hstatec <= 1; else if (sd_wrc) hstatec <= 2; end
				1: begin
					sd_buff_addrc <= hic[7:0];
					sd_buff_doutc <= disk[sd_lbac*256 + hic];
					sd_buff_wrc   <= 1'b1;
					if (hic == 255) hstatec <= 3; else hic <= hic + 1;
				end
				2: begin sd_buff_addrc <= hic[7:0]; hstatec <= 5; end
				5: begin
					disk[sd_lbac*256 + hic] <= sd_buff_dinc;
					if (hic == 255) hstatec <= 3; else begin hic <= hic + 1; hstatec <= 2; end
				end
				3: begin sd_ackc <= 1'b1; hstatec <= 4; end
				4: if (!sd_rdc && !sd_wrc) hstatec <= 0;
			endcase
		end
	end

	// ---- CPU register access: disk DUT ----
	task swr(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d;
		wait (ack); @(posedge clk); #1 sel=0;
	end
	endtask
	task srd(input [3:0] a, output [7:0] qq);
	begin
		@(posedge clk); #1 sel=1; rw=1; addr=a;
		wait (ack); #1 qq = dout; @(posedge clk); #1 sel=0;
	end
	endtask

	// ---- CPU register access: CD DUT ----
	task swrc(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk); #1 selc=1; rwc=0; addrc=a; dinc=d;
		wait (ackc); @(posedge clk); #1 selc=0;
	end
	endtask
	task srdc(input [3:0] a, output [7:0] qq);
	begin
		@(posedge clk); #1 selc=1; rwc=1; addrc=a;
		wait (ackc); #1 qq = doutc; @(posedge clk); #1 selc=0;
	end
	endtask

	task chk(input [127:0] name, input [15:0] got, input [15:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %04h exp %04h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %04h", name, got);
	end
	endtask

	integer i;
	reg [7:0] rbuf [0:1023];
	initial begin
		// preload disk model
		for (i = 0; i < 256; i = i + 1) disk[5*256  + i] = 16'h1000 + i[15:0]; // READ(6) LBA5
		for (i = 0; i < 256; i = i + 1) disk[10*256 + i] = 16'h2000 + i[15:0]; // READ(10) sec0
		for (i = 0; i < 256; i = i + 1) disk[11*256 + i] = 16'h3000 + i[15:0]; // READ(10) sec1

		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// ==================== disk: READ(6) LBA=5, len=1 ====================
		swr(4'h3, 8'h01);                                      // flush FIFO
		swr(4'h2, 8'h08); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h05); swr(4'h2, 8'h01); swr(4'h2, 8'h00);   // CDB
		swr(4'h3, 8'h10);                                       // Transfer Info
		wait (irq);
		srd(4'h5, q); chk("int", {8'd0, q}, 16'h0018);          // interrupt + clear
		srd(4'h2, q); chk("rd0", {8'd0, q}, 16'h0010);
		srd(4'h2, q); chk("rd1", {8'd0, q}, 16'h0000);
		srd(4'h2, q); chk("rd2", {8'd0, q}, 16'h0010);
		srd(4'h2, q); chk("rd3", {8'd0, q}, 16'h0001);

		// ==================== disk: WRITE(6) LBA=6, len=1 ====================
		@(posedge clk);
		swr(4'h3, 8'h01);                                      // flush FIFO
		swr(4'h2, 8'h0A); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h06); swr(4'h2, 8'h01); swr(4'h2, 8'h00);
		swr(4'h3, 8'h10);                                       // WRITE(6)
		for (i = 0; i < 512; i = i + 1) swr(4'h2, i[7:0]);      // data
		wait (irq);
		srd(4'h5, q);                                           // clear int
		chk("wr word0", disk[6*256 + 0], 16'h0001);
		chk("wr word1", disk[6*256 + 1], 16'h0203);

		// ==================== disk: INQUIRY ====================
		swr(4'h3, 8'h01);
		swr(4'h2, 8'h12); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h00); swr(4'h2, 8'h24); swr(4'h2, 8'h00);   // alloc len 36
		swr(4'h3, 8'h10);
		wait (irq);
		srd(4'h5, q);
		for (i = 0; i < 13; i = i + 1) begin srd(4'h2, q); rbuf[i] = q; end
		chk("disk inq devtype", {8'd0, rbuf[0]}, 16'h0000);    // device type 0x00
		chk("disk inq rmb",     {8'd0, rbuf[1]}, 16'h0000);    // not removable
		chk("disk inq vendorA", {8'd0, rbuf[8]},  16'h0041);   // 'A'
		chk("disk inq vendorP", {8'd0, rbuf[9]},  16'h0050);   // 'P'
		chk("disk inq vendorP2",{8'd0, rbuf[10]}, 16'h0050);   // 'P'
		chk("disk inq vendorL", {8'd0, rbuf[11]}, 16'h004C);   // 'L'
		chk("disk inq vendorE", {8'd0, rbuf[12]}, 16'h0045);   // 'E'

		// ==================== disk: TEST UNIT READY ====================
		swr(4'h3, 8'h01);
		swr(4'h2, 8'h00); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h00); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h3, 8'h10);
		wait (irq);
		srd(4'h5, q); chk("disk tur int", {8'd0, q}, 16'h0018);

		// ==================== disk: READ CAPACITY ====================
		swr(4'h3, 8'h01);
		swr(4'h2, 8'h25); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h00); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h3, 8'h10);
		wait (irq);
		srd(4'h5, q);
		for (i = 0; i < 8; i = i + 1) begin srd(4'h2, q); rbuf[i] = q; end
		// last-LBA = 1048576/512 - 1 = 2047 = 0x000007FF
		chk("disk cap lba_hi", {rbuf[0], rbuf[1]}, 16'h0000);
		chk("disk cap lba_lo", {rbuf[2], rbuf[3]}, 16'h07FF);
		chk("disk cap bs_hi",  {rbuf[4], rbuf[5]}, 16'h0000);
		chk("disk cap bs_lo",  {rbuf[6], rbuf[7]}, 16'h0200); // 512

		// ==================== disk: READ(10) 2 blocks across boundary ====
		swr(4'h3, 8'h01);
		swr(4'h2, 8'h28); swr(4'h2, 8'h00);
		swr(4'h2, 8'h00); swr(4'h2, 8'h00); swr(4'h2, 8'h00); swr(4'h2, 8'h0A); // LBA=10
		swr(4'h2, 8'h00);
		swr(4'h2, 8'h00); swr(4'h2, 8'h02);                    // len=2 blocks
		swr(4'h2, 8'h00);
		swr(4'h3, 8'h10);
		wait (irq);
		srd(4'h5, q);
		for (i = 0; i < 512; i = i + 1) begin srd(4'h2, q); rbuf[i] = q; end // sector 0
		wait (irq);                                            // next sector ready
		srd(4'h5, q);
		for (i = 0; i < 512; i = i + 1) begin srd(4'h2, q); rbuf[512+i] = q; end // sector 1
		// sector 0 word0 = 0x2000 -> bytes 0x20,0x00 ; word255 = 0x20FF
		chk("r10 s0 b0",  {8'd0, rbuf[0]},   16'h0020);
		chk("r10 s0 b1",  {8'd0, rbuf[1]},   16'h0000);
		chk("r10 s0 b510",{8'd0, rbuf[510]}, 16'h0020);
		chk("r10 s0 b511",{8'd0, rbuf[511]}, 16'h00FF);
		// boundary: first bytes of sector 1 = 0x3000
		chk("r10 s1 b0",  {8'd0, rbuf[512]}, 16'h0030);
		chk("r10 s1 b1",  {8'd0, rbuf[513]}, 16'h0000);
		chk("r10 s1 b510",{8'd0, rbuf[1022]},16'h0030);
		chk("r10 s1 b511",{8'd0, rbuf[1023]},16'h00FF);

		// ==================== CD: INQUIRY ====================
		swrc(4'h3, 8'h01);
		swrc(4'h2, 8'h12); swrc(4'h2, 8'h00); swrc(4'h2, 8'h00);
		swrc(4'h2, 8'h00); swrc(4'h2, 8'h24); swrc(4'h2, 8'h00);
		swrc(4'h3, 8'h10);
		wait (irqc);
		srdc(4'h5, q);
		for (i = 0; i < 13; i = i + 1) begin srdc(4'h2, q); rbuf[i] = q; end
		chk("cd inq devtype", {8'd0, rbuf[0]}, 16'h0005);      // CD-ROM device type
		chk("cd inq rmb",     {8'd0, rbuf[1]}, 16'h0080);      // removable
		chk("cd inq vendorA", {8'd0, rbuf[8]},  16'h0041);     // 'A'
		chk("cd inq vendorP", {8'd0, rbuf[9]},  16'h0050);     // 'P'
		chk("cd inq vendorL", {8'd0, rbuf[11]}, 16'h004C);     // 'L'
		chk("cd inq vendorE", {8'd0, rbuf[12]}, 16'h0045);     // 'E'

		// ==================== CD: READ CAPACITY ====================
		swrc(4'h3, 8'h01);
		swrc(4'h2, 8'h25); swrc(4'h2, 8'h00); swrc(4'h2, 8'h00);
		swrc(4'h2, 8'h00); swrc(4'h2, 8'h00); swrc(4'h2, 8'h00);
		swrc(4'h3, 8'h10);
		wait (irqc);
		srdc(4'h5, q);
		for (i = 0; i < 8; i = i + 1) begin srdc(4'h2, q); rbuf[i] = q; end
		// last-LBA = 1048576/2048 - 1 = 511 = 0x000001FF
		chk("cd cap lba_hi", {rbuf[0], rbuf[1]}, 16'h0000);
		chk("cd cap lba_lo", {rbuf[2], rbuf[3]}, 16'h01FF);
		chk("cd cap bs_hi",  {rbuf[4], rbuf[5]}, 16'h0000);
		chk("cd cap bs_lo",  {rbuf[6], rbuf[7]}, 16'h0800); // 2048

		// ==================== CD: READ TOC ====================
		swrc(4'h3, 8'h01);
		swrc(4'h2, 8'h43); swrc(4'h2, 8'h00); swrc(4'h2, 8'h00);
		swrc(4'h2, 8'h00); swrc(4'h2, 8'h00); swrc(4'h2, 8'h00);
		swrc(4'h2, 8'h00); swrc(4'h2, 8'h00); swrc(4'h2, 8'hC0); // alloc len 192
		swrc(4'h2, 8'h00);
		swrc(4'h3, 8'h10);
		wait (irqc);
		srdc(4'h5, q);
		for (i = 0; i < 16; i = i + 1) begin srdc(4'h2, q); rbuf[i] = q; end
		chk("toc len",       {rbuf[0], rbuf[1]}, 16'h0012);   // TOC data length 18
		chk("toc first trk", {8'd0, rbuf[2]},    16'h0001);
		chk("toc last trk",  {8'd0, rbuf[3]},    16'h0001);
		chk("toc t1 ctrl",   {8'd0, rbuf[5]},    16'h0004);   // data track (byte5)
		chk("toc t1 num",    {8'd0, rbuf[6]},    16'h0001);   // track 1 (byte6)
		chk("toc lo ctrl",   {8'd0, rbuf[13]},   16'h0004);   // lead-out ADR/ctrl (byte13)
		chk("toc leadout",   {8'd0, rbuf[14]},   16'h00AA);   // lead-out track (byte14)

		if (errors == 0) $display("PASS: SCSI all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
