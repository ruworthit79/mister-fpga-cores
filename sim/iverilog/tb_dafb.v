//============================================================================
//  tb_dafb - Icarus testbench for the DAFB framebuffer
//    1. CPU VRAM aperture write + read-back.
//    2. CPU CLUT write + read-back.
//    3. Scanout: 8bpp pixels indexed through the CLUT appear on r/g/b in order.
//  Uses a tiny CRTC (8x4 active) so a frame is short.
//============================================================================
`timescale 1ns/1ps

module tb_dafb;
	reg         clk = 0, reset = 1;
	reg         sel = 0, rw = 1;
	reg  [23:0] addr = 0;
	reg  [31:0] din = 0;
	reg  [3:0]  be = 4'hF;
	wire [31:0] dout;
	wire        ack;
	wire        ce_pix, HBlank, HSync, VBlank, VSync, vbl_irq;
	wire [7:0]  r, g, b;

	integer errors = 0;
	reg [31:0] rdata;

	localparam VRAM_BASE = 24'h80_0000;
	localparam CLUT_BASE = 24'h10_0000;
	localparam REG_BASE  = 24'h00_0000;

	reg [1:0] vmode = 0;

	dafb #(.VRAM_WORDS(256), .TESTTIMING(1),
	       .H_ACT(8), .H_FP(1), .H_SY(1), .H_BP(1),
	       .V_ACT(4), .V_FP(1), .V_SY(1), .V_BP(1)) dut (
		.clk(clk), .reset(reset), .vmode(vmode),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .be(be), .rw(rw), .ack(ack),
		.ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
		.r(r), .g(g), .b(b), .vbl_irq(vbl_irq)
	);

	always #10 clk = ~clk;

	task cwr(input [23:0] a, input [31:0] d, input [3:0] ben);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d; be=ben;
		wait (ack); @(posedge clk); #1 sel=0; rw=1;
	end
	endtask

	task crd(input [23:0] a, output [31:0] q);
	begin
		@(posedge clk); #1 sel=1; rw=1; addr=a; be=4'hF;
		wait (ack); #1 q = dout;
		@(posedge clk); #1 sel=0;
	end
	endtask

	task chk(input [127:0] name, input [31:0] got, input [31:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %08h exp %08h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %08h", name, got);
	end
	endtask

	// advance to the next cycle where ce_pix is high (outputs just updated)
	task step_pix;
	begin
		@(posedge clk); while (!ce_pix) @(posedge clk);
	end
	endtask

	reg [23:0] pix [0:7];
	integer n, n2;

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0;
		@(posedge clk);

		// ---- setup: stride=8, base=0, video on ----
		cwr(REG_BASE + 24'h08, 32'd8,     4'hF);   // stride
		cwr(REG_BASE + 24'h04, 32'd0,     4'hF);   // base
		cwr(REG_BASE + 24'h00, 32'h1,     4'hF);   // ctrl: enable

		// ---- CLUT ----
		cwr(CLUT_BASE + 0*4, 32'h00_000000, 4'hF);
		cwr(CLUT_BASE + 1*4, 32'h00_FF0000, 4'hF);
		cwr(CLUT_BASE + 2*4, 32'h00_00FF00, 4'hF);
		cwr(CLUT_BASE + 3*4, 32'h00_0000FF, 4'hF);
		cwr(CLUT_BASE + 4*4, 32'h00_112233, 4'hF);

		// ---- VRAM: word0 bytes = pixel indices 1,2,3,4 ----
		cwr(VRAM_BASE + 0, 32'h01020304, 4'hF);

		// ---- 1&2: read-back ----
		crd(VRAM_BASE + 0, rdata); chk("vram rd", rdata, 32'h01020304);
		crd(CLUT_BASE + 1*4, rdata); chk("clut1 rd", rdata, 32'h00FF0000);

		// ---- 3: scanout ----
		// Capture line-0 pixels 0..3 by their pipelined coordinate (s2_x/s2_y),
		// which is aligned with the r/g/b output. Bounded to avoid any hang.
		pix[0]=~0; pix[1]=~0; pix[2]=~0; pix[3]=~0;
		begin : collect
			reg seen_nonzero, started;
			seen_nonzero = 0; started = 0;
			for (n2 = 0; n2 < 8000; n2 = n2 + 1) begin
				step_pix;
				if (dut.s2_y != 0) begin
					if (started) disable collect;          // line 0 finished
					seen_nonzero = 1;
				end else if (seen_nonzero) begin           // fresh frame's line 0
					started = 1;
					if (!HBlank && !VBlank && dut.s2_x < 4)
						pix[dut.s2_x] = {r, g, b};
				end
			end
		end

		chk("pix0", {8'd0, pix[0]}, 32'h00FF0000);
		chk("pix1", {8'd0, pix[1]}, 32'h0000FF00);
		chk("pix2", {8'd0, pix[2]}, 32'h000000FF);
		chk("pix3", {8'd0, pix[3]}, 32'h00112233);

		if (errors == 0) $display("PASS: DAFB all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
