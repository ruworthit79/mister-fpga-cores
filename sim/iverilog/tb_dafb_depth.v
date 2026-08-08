//============================================================================
//  tb_dafb_depth - DAFB direct-colour scanout at 16 bpp and 32 bpp.
//    16 bpp: xRGB1555, two pixels per 32-bit word (even=high halfword).
//    32 bpp: xRGB8888 ($00RRGGBB), one pixel per word.
//  Uses the same tiny-CRTC (8x4) harness as tb_dafb.v so a frame is short.
//============================================================================
`timescale 1ns/1ps

module tb_dafb_depth;
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

	localparam VRAM_BASE = 24'h80_0000;
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

	task cwr(input [23:0] a, input [31:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d; be=4'hF;
		wait (ack); @(posedge clk); #1 sel=0; rw=1;
	end
	endtask

	task chk(input [127:0] name, input [31:0] got, input [31:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %06h exp %06h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %06h", name, got);
	end
	endtask

	task step_pix; begin @(posedge clk); while (!ce_pix) @(posedge clk); end endtask

	reg [23:0] pix [0:3];
	integer n2;

	// Capture line-0 pixels 0..3 by their pipelined coordinate (aligned with rgb).
	task capture;
	begin : collect
		reg seen_nonzero, started;
		pix[0]=~0; pix[1]=~0; pix[2]=~0; pix[3]=~0;
		seen_nonzero = 0; started = 0;
		for (n2 = 0; n2 < 8000; n2 = n2 + 1) begin
			step_pix;
			if (dut.s2_y != 0) begin
				if (started) disable collect;
				seen_nonzero = 1;
			end else if (seen_nonzero) begin
				started = 1;
				if (!HBlank && !VBlank && dut.s2_x < 4)
					pix[dut.s2_x] = {r, g, b};
			end
		end
	end
	endtask

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0;
		@(posedge clk);

		// ================= 16 bpp =================
		cwr(REG_BASE + 24'h04, 32'd0);    // base
		cwr(REG_BASE + 24'h08, 32'd16);   // stride = 8px * 2 bytes
		cwr(REG_BASE + 24'h0C, 32'd1);    // depth = 16bpp
		cwr(REG_BASE + 24'h00, 32'h1);    // ctrl: enable
		// word0: pixel0 (even, high halfword) = 0x7C00 (R=31 -> red)
		//        pixel1 (odd,  low  halfword) = 0x03E0 (G=31 -> green)
		cwr(VRAM_BASE + 0, 32'h7C00_03E0);
		capture;
		chk("16 pix0", {8'd0, pix[0]}, 32'h00FF0000);   // red
		chk("16 pix1", {8'd0, pix[1]}, 32'h0000FF00);   // green

		// ================= 32 bpp =================
		cwr(REG_BASE + 24'h08, 32'd32);   // stride = 8px * 4 bytes
		cwr(REG_BASE + 24'h0C, 32'd2);    // depth = 32bpp
		// word0 = pixel0 = $00112233, word1 = pixel1 = $00445566
		cwr(VRAM_BASE + 0, 32'h0011_2233);
		cwr(VRAM_BASE + 4, 32'h0044_5566);
		capture;
		chk("32 pix0", {8'd0, pix[0]}, 32'h00112233);
		chk("32 pix1", {8'd0, pix[1]}, 32'h00445566);

		if (errors == 0) $display("PASS: DAFB depth all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #400000; $display("TIMEOUT"); $finish; end
endmodule
