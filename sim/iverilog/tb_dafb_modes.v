//============================================================================
//  tb_dafb_modes - CRTC timing (vmode presets + programmable CRTC) and the
//  depth/pixel-divider registers.
//    A. vmode preset timing table: active dimensions and totals per mode.
//    B. programmable CRTC (reg_ctrl[1]): absolute total/sync/active override.
//    C. depth + pixel-divider register read-back.
//============================================================================
`timescale 1ns/1ps

module tb_dafb_modes;
	reg         clk = 0, reset = 1;
	reg  [1:0]  vmode = 0;
	reg         sel = 0, rw = 1;
	reg  [23:0] addr = 0;
	reg  [31:0] din = 0;
	reg  [3:0]  be = 4'hF;
	wire [31:0] dout; wire ack;
	wire ce_pix, HBlank, HSync, VBlank, VSync, vbl_irq;
	wire [7:0] r,g,b;

	integer errors = 0;
	reg [31:0] rdata;

	dafb #(.TESTTIMING(0)) dut (
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

	task crd(input [23:0] a, output [31:0] q);
	begin
		@(posedge clk); #1 sel=1; rw=1; addr=a; be=4'hF;
		wait (ack); #1 q = dout;
		@(posedge clk); #1 sel=0;
	end
	endtask

	task chk(input [127:0] nm, input [31:0] got, input [31:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %0d exp %0d", nm, got, exp); errors=errors+1; end
		else $display("ok   %0s = %0d", nm, got);
	end
	endtask

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0;
		@(posedge clk);

		// ---- A. vmode preset timing (reg_ctrl default: use_prog=0) ----
		vmode = 2'd0; #1;
		chk("m0 hact", dut.H_ACTs, 640);  chk("m0 vact", dut.V_ACTs, 480);
		chk("m0 htot", dut.H_TOT, 800);   chk("m0 vtot", dut.V_TOT, 525);
		vmode = 2'd1; #1;
		chk("m1 hact", dut.H_ACTs, 832);  chk("m1 vact", dut.V_ACTs, 624);
		chk("m1 htot", dut.H_TOT, 1152);  chk("m1 vtot", dut.V_TOT, 667);
		vmode = 2'd2; #1;
		chk("m2 hact", dut.H_ACTs, 1024); chk("m2 vact", dut.V_ACTs, 768);
		chk("m2 htot", dut.H_TOT, 1344);  chk("m2 vtot", dut.V_TOT, 806);
		vmode = 2'd3; #1;
		chk("m3 hact", dut.H_ACTs, 1152); chk("m3 vact", dut.V_ACTs, 870);
		chk("m3 htot", dut.H_TOT, 1456);  chk("m3 vtot", dut.V_TOT, 915);

		// ---- B. programmable CRTC (reg_ctrl[1]=1 overrides the presets) ----
		// Register block: reg n at byte offset n*4. htot@0x20 hss@0x24 hse@0x28
		// hact@0x2C vtot@0x30 vss@0x34 vse@0x38 vact@0x3C.
		cwr(24'h00_0020, 32'd900);   // h total
		cwr(24'h00_0024, 32'd700);   // h sync start
		cwr(24'h00_0028, 32'd750);   // h sync end
		cwr(24'h00_002C, 32'd640);   // h active
		cwr(24'h00_0030, 32'd600);   // v total
		cwr(24'h00_0034, 32'd485);   // v sync start
		cwr(24'h00_0038, 32'd490);   // v sync end
		cwr(24'h00_003C, 32'd480);   // v active
		cwr(24'h00_0000, 32'h03);    // ctrl: enable + use programmed CRTC
		vmode = 2'd3; #1;            // vmode should now be ignored
		chk("prog htot", dut.H_TOT,  900);  chk("prog hss", dut.H_SE,   700);
		chk("prog hse",  dut.H_SEND, 750);  chk("prog hact",dut.H_ACTs, 640);
		chk("prog vtot", dut.V_TOT,  600);  chk("prog vss", dut.V_SE,   485);
		chk("prog vse",  dut.V_SEND, 490);  chk("prog vact",dut.V_ACTs, 480);

		// ---- C. depth + pixel divider register read-back ----
		cwr(24'h00_000C, 32'd2);     // depth = 32bpp
		crd(24'h00_000C, rdata);     chk("depth rb", rdata, 32'd2);
		cwr(24'h00_001C, 32'd3);     // pixdiv = 3 (clk/4)
		crd(24'h00_001C, rdata);     chk("pixdiv rb", rdata, 32'd3);

		if (errors == 0) $display("PASS: DAFB modes all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
