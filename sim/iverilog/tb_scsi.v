//============================================================================
//  tb_scsi - Icarus testbench for the NCR 53C96 datapath
//    READ(6):  CDB -> block-interface fetch -> FIFO read-back matches disk.
//    WRITE(6): FIFO push -> block-interface store -> disk matches.
//  Includes a behavioral HPS block responder backed by a disk model.
//============================================================================
`timescale 1ns/1ps

module tb_scsi;
	reg         clk = 0, reset = 1;
	reg         sel = 0, rw = 1;
	reg  [3:0]  addr = 0;
	reg  [7:0]  din = 0;
	wire [7:0]  dout;
	wire        ack, irq, active;

	reg  [31:0] sd_lba_x;    // (unused; core drives sd_lba)
	wire [31:0] sd_lba;
	wire        sd_rd, sd_wr;
	reg         sd_ack = 0;
	reg  [13:0] sd_buff_addr = 0;
	reg  [15:0] sd_buff_dout = 0;
	wire [15:0] sd_buff_din;
	reg         sd_buff_wr = 0;

	integer errors = 0;
	reg [7:0] q;

	scsi_ncr53c96 dut (
		.clk(clk), .reset(reset),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .rw(rw), .ack(ack), .irq(irq),
		.img_mounted(1'b1), .img_readonly(1'b0), .img_size(64'd1048576),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr), .active(active)
	);

	always #10 clk = ~clk;

	// ---- disk model + behavioral HPS block responder ----
	reg [15:0] disk [0:4095];
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

	// ---- CPU register access ----
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

	task chk(input [127:0] name, input [15:0] got, input [15:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %04h exp %04h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %04h", name, got);
	end
	endtask

	integer i;
	initial begin
		// preload disk: LBA 5 -> word i = 0x1000+i
		for (i = 0; i < 256; i = i + 1) disk[5*256 + i] = 16'h1000 + i[15:0];

		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// ---- READ(6) LBA=5, len=1 ----
		swr(4'h3, 8'h01);                                      // flush FIFO
		swr(4'h2, 8'h08); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h05); swr(4'h2, 8'h01); swr(4'h2, 8'h00);   // CDB
		swr(4'h3, 8'h10);                                       // Transfer Info
		wait (irq);
		srd(4'h5, q); chk("int", {8'd0, q}, 16'h0018);          // interrupt + clear
		// read first 4 bytes -> 0x10 0x00 0x10 0x01
		srd(4'h2, q); chk("rd0", {8'd0, q}, 16'h0010);
		srd(4'h2, q); chk("rd1", {8'd0, q}, 16'h0000);
		srd(4'h2, q); chk("rd2", {8'd0, q}, 16'h0010);
		srd(4'h2, q); chk("rd3", {8'd0, q}, 16'h0001);

		// ---- WRITE(6) LBA=6, len=1: push 512 bytes (byte j = j) ----
		// finish the read state first
		@(posedge clk);
		swr(4'h3, 8'h01);                                      // flush FIFO
		swr(4'h2, 8'h0A); swr(4'h2, 8'h00); swr(4'h2, 8'h00);
		swr(4'h2, 8'h06); swr(4'h2, 8'h01); swr(4'h2, 8'h00);
		swr(4'h3, 8'h10);                                       // WRITE(6)
		for (i = 0; i < 512; i = i + 1) swr(4'h2, i[7:0]);      // data
		wait (irq);
		srd(4'h5, q);                                           // clear int
		chk("wr word0", disk[6*256 + 0], 16'h0001);            // {byte0,byte1}
		chk("wr word1", disk[6*256 + 1], 16'h0203);

		if (errors == 0) $display("PASS: SCSI all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #2000000; $display("TIMEOUT"); $finish; end
endmodule
