//============================================================================
//  tb_mcu - Icarus testbench for the MCU <-> DDR3 controller
//
//  Verifies:
//    1. ROM image load via ioctl, read back through the CPU port in correct
//       68k big-endian order (so instructions would decode right).
//    2. RAM write then read back (full 32-bit).
//    3. Byte-enable writes (partial word update leaves other bytes intact).
//============================================================================
`timescale 1ns/1ps

module tb_mcu;
	reg         clk = 0, reset = 1;
	reg  [31:0] cpu_addr, cpu_din;
	wire [31:0] cpu_dout;
	reg  [3:0]  cpu_be;
	reg         cpu_rw, cpu_req, cpu_rom_sel;
	wire        cpu_ack;

	reg         ioctl_download = 0, ioctl_wr = 0;
	reg  [7:0]  ioctl_index = 0;
	reg  [26:0] ioctl_addr = 0;
	reg  [15:0] ioctl_dout = 0;
	reg  [1:0]  ram_cfg = 2'd0;   // 0=64MB 1=128MB 2=256MB

	wire [7:0]  BURSTCNT;
	wire [28:0] ADDR;
	wire [63:0] DOUT, DIN;
	wire        DOUT_READY, RD, WE, BUSY;
	wire [7:0]  BE;

	integer errors = 0;

	// Small ROM base so DDR addresses stay tiny for the model.
	mcu #(.ROM_BASE(29'h0001_0000)) dut (
		.clk(clk), .reset(reset), .ram_cfg(ram_cfg),
		.cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
		.cpu_be(cpu_be), .cpu_rw(cpu_rw), .cpu_req(cpu_req),
		.rom_sel(cpu_rom_sel), .cpu_ack(cpu_ack),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.DDRAM_BUSY(BUSY), .DDRAM_BURSTCNT(BURSTCNT), .DDRAM_ADDR(ADDR),
		.DDRAM_DOUT(DOUT), .DDRAM_DOUT_READY(DOUT_READY), .DDRAM_RD(RD),
		.DDRAM_DIN(DIN), .DDRAM_BE(BE), .DDRAM_WE(WE)
	);

	ddr3_model #(.AW(15)) ddr (
		.clk(clk), .DDRAM_BURSTCNT(BURSTCNT), .DDRAM_ADDR(ADDR),
		.DDRAM_DOUT(DOUT), .DDRAM_DOUT_READY(DOUT_READY), .DDRAM_RD(RD),
		.DDRAM_DIN(DIN), .DDRAM_BE(BE), .DDRAM_WE(WE), .DDRAM_BUSY(BUSY)
	);

	always #10 clk = ~clk;   // 50 MHz

	// Load one 16-bit ROM word at byte address a.
	task rom_load(input [26:0] a, input [15:0] d);
	begin
		@(posedge clk);
		ioctl_addr <= a; ioctl_dout <= d; ioctl_wr <= 1'b1;
		@(posedge clk);
		ioctl_wr <= 1'b0;
		repeat (4) @(posedge clk);   // let the DDR write settle
	end
	endtask

	// CPU bus transaction. Returns read data in cpu_dout (stable at ack).
	task cpu_xfer(input [31:0] a, input rw, input [3:0] be, input [31:0] wd,
	              output [31:0] rd_data);
	begin
		@(posedge clk);
		cpu_addr <= a; cpu_rw <= rw; cpu_be <= be; cpu_din <= wd; cpu_req <= 1'b1;
		cpu_rom_sel <= a[30];   // $40000000 region targets ROM
		wait (cpu_ack == 1'b1);
		@(posedge clk);
		rd_data = cpu_dout;
		cpu_req <= 1'b0;
		wait (cpu_ack == 1'b0);
		@(posedge clk);
	end
	endtask

	task check(input [127:0] name, input [31:0] got, input [31:0] exp);
	begin
		if (got !== exp) begin
			$display("FAIL %0s: got %08h expected %08h", name, got, exp);
			errors = errors + 1;
		end else begin
			$display("ok   %0s = %08h", name, got);
		end
	end
	endtask

	reg [31:0] rdata;

	initial begin
		cpu_addr = 0; cpu_din = 0; cpu_be = 0; cpu_rw = 1; cpu_req = 0; cpu_rom_sel = 0;
		repeat (5) @(posedge clk);
		reset <= 0;
		repeat (2) @(posedge clk);

		// ---- 1. ROM load + big-endian read-back ----
		// Program bytes: 20 3C 12 34 56 78 (MOVE.L #$12345678,D0)
		ioctl_download <= 1'b1; ioctl_index <= 8'd0;
		rom_load(27'h0, 16'h203C);
		rom_load(27'h2, 16'h1234);
		rom_load(27'h4, 16'h5678);
		rom_load(27'h6, 16'h4E71);   // NOP
		ioctl_download <= 1'b0;
		repeat (2) @(posedge clk);

		cpu_xfer(32'h4000_0000, 1'b1, 4'b1111, 0, rdata);
		check("rom[0]", rdata, 32'h203C_1234);
		cpu_xfer(32'h4000_0004, 1'b1, 4'b1111, 0, rdata);
		check("rom[4]", rdata, 32'h5678_4E71);

		// ---- 2. RAM write + read-back ----
		cpu_xfer(32'h0000_0040, 1'b0, 4'b1111, 32'hAABB_CCDD, rdata);
		cpu_xfer(32'h0000_0040, 1'b1, 4'b1111, 0, rdata);
		check("ram full", rdata, 32'hAABB_CCDD);

		// ---- 3. byte-enable partial write (low 2 bytes only) ----
		cpu_xfer(32'h0000_0040, 1'b0, 4'b0011, 32'h1122_3344, rdata);
		cpu_xfer(32'h0000_0040, 1'b1, 4'b1111, 0, rdata);
		check("ram be", rdata, 32'hAABB_3344);

		// ---- 4. RAM-size masking (installed-size aliasing) ----
		// ram_a = {cpu_addr[28:3],0} masked to the installed size; accesses above it
		// wrap. dut.ram_a is combinational, so drive addr/cfg and sample directly.
		cpu_req = 1'b0;
		ram_cfg = 2'd0; cpu_addr = 32'h0400_0040; #1;   // 64MB+0x40 in 64MB -> alias 0x40
		check("mask 64MB alias",  {3'b0, dut.ram_a}, 32'h0000_0040);
		ram_cfg = 2'd1; cpu_addr = 32'h0400_0040; #1;   // 64MB in 128MB -> valid, no alias
		check("mask 128MB valid", {3'b0, dut.ram_a}, 32'h0400_0040);
		ram_cfg = 2'd2; cpu_addr = 32'h0C00_0040; #1;   // 192MB in 256MB -> valid
		check("mask 256MB valid", {3'b0, dut.ram_a}, 32'h0C00_0040);
		ram_cfg = 2'd0; cpu_addr = 32'h0800_0040; #1;   // 128MB in 64MB -> alias 0x40
		check("mask 64<-128",     {3'b0, dut.ram_a}, 32'h0000_0040);
		ram_cfg = 2'd2; cpu_addr = 32'h1000_0040; #1;   // 256MB in 256MB -> wrap to 0x40
		check("mask 256 wrap",    {3'b0, dut.ram_a}, 32'h0000_0040);

		if (errors == 0) $display("PASS: MCU/DDR3 all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin
		#200000;
		$display("TIMEOUT");
		$finish;
	end
endmodule
