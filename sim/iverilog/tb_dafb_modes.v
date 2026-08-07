//============================================================================
//  tb_dafb_modes - checks the programmable CRTC timing table (vmode)
//  Verifies active dimensions and totals for each of the four Apple modes.
//============================================================================
`timescale 1ns/1ps

module tb_dafb_modes;
	reg        clk = 0;
	reg [1:0]  vmode = 0;
	wire [31:0] dout; wire ack;
	wire ce_pix, HBlank, HSync, VBlank, VSync, vbl_irq;
	wire [7:0] r,g,b;

	integer errors = 0;

	dafb #(.TESTTIMING(0)) dut (
		.clk(clk), .reset(1'b1), .vmode(vmode),
		.sel(1'b0), .addr(24'd0), .din(32'd0), .dout(dout), .be(4'd0), .rw(1'b1), .ack(ack),
		.ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
		.r(r), .g(g), .b(b), .vbl_irq(vbl_irq)
	);

	task chk(input [127:0] nm, input [11:0] got, input [11:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %0d exp %0d", nm, got, exp); errors=errors+1; end
		else $display("ok   %0s = %0d", nm, got);
	end
	endtask

	initial begin
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

		if (errors == 0) $display("PASS: DAFB modes all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end
endmodule
