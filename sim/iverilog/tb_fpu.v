//============================================================================
//  tb_fpu - 68040 FPU foundation test (Icarus)
//
//  Exercises the register model + structural ops + IEEE classification of
//  rtl/cpu/fpu_040.sv. Extended-precision constants used:
//    +1.0 = 3FFF_8000000000000000   -1.0 = BFFF_8000000000000000
//     0.0 = 0000_0000000000000000   +Inf = 7FFF_8000000000000000
//     NaN = 7FFF_C000000000000000
//============================================================================
`timescale 1ns/1ps
module tb_fpu;
	reg         clk = 0, reset = 1;
	reg         op_valid = 0;
	reg  [4:0]  cmd = 0;
	reg  [2:0]  src_reg = 0, dst_reg = 0, cr_sel = 0;
	reg  [79:0] ext_in = 0;
	wire [79:0] ext_out;
	wire [31:0] fpsr_out, fpcr_out;
	wire        present, done, unimpl;

	fpu_040 dut(
		.clk(clk), .reset(reset), .op_valid(op_valid), .cmd(cmd),
		.src_reg(src_reg), .dst_reg(dst_reg), .cr_sel(cr_sel),
		.ext_in(ext_in), .ext_out(ext_out),
		.fpsr_out(fpsr_out), .fpcr_out(fpcr_out),
		.present(present), .done(done), .unimpl(unimpl)
	);

	always #5 clk = ~clk;

	// command opcodes (mirror the module localparams)
	localparam FPU_FMOVE_RR=1, FPU_FMOVE_LD=2, FPU_FMOVE_ST=3, FPU_FABS=4,
	           FPU_FNEG=5, FPU_FTST=6, FPU_TO_CR=7, FPU_FROM_CR=8, FPU_ARITH=9;
	localparam CR_FPCR=1, CR_FPSR=2, CR_FPIAR=4;

	localparam [79:0] P1 = 80'h3FFF_8000000000000000;  // +1.0
	localparam [79:0] N1 = 80'hBFFF_8000000000000000;  // -1.0
	localparam [79:0] ZERO = 80'h0000_0000000000000000;
	localparam [79:0] PINF = 80'h7FFF_8000000000000000;
	localparam [79:0] QNAN = 80'h7FFF_C000000000000000;

	integer errors = 0;

	// latch the 1-cycle unimpl pulse so we can check it after issue() returns
	reg unimpl_latch = 0;
	always @(posedge clk) if (unimpl) unimpl_latch <= 1'b1;

	task issue(input [4:0] c, input [2:0] s, input [2:0] d, input [2:0] cr, input [79:0] e);
		begin
			@(negedge clk); cmd=c; src_reg=s; dst_reg=d; cr_sel=cr; ext_in=e; op_valid=1;
			@(negedge clk); op_valid=0;
			@(negedge clk);   // let result register settle
		end
	endtask

	// FPSR condition-code bits
	`define CC_N  fpsr_out[27]
	`define CC_Z  fpsr_out[26]
	`define CC_I  fpsr_out[25]
	`define CC_NAN fpsr_out[24]

	task chk(input cond, input [255:0] msg);
		begin if (!cond) begin $display("FAIL: %0s", msg); errors=errors+1; end end
	endtask

	initial begin
		repeat(4) @(negedge clk); reset=0; @(negedge clk);

		chk(present===1'b1, "present should be 1");

		// load +1.0 into FP0 -> N=0 Z=0 I=0 NAN=0
		issue(FPU_FMOVE_LD, 0, 0, 0, P1);
		chk(dut.fpreg[0]===P1, "FP0 load +1.0");
		chk(`CC_N==0 && `CC_Z==0 && `CC_I==0 && `CC_NAN==0, "CC(+1.0)");

		// FMOVE FP0->FP1
		issue(FPU_FMOVE_RR, 0, 1, 0, 0);
		chk(dut.fpreg[1]===P1, "FMOVE FP0->FP1");

		// FNEG FP1->FP2 : -1.0, N=1
		issue(FPU_FNEG, 1, 2, 0, 0);
		chk(dut.fpreg[2]===N1, "FNEG -> -1.0");
		chk(`CC_N==1, "CC N after FNEG");

		// FABS FP2->FP3 : +1.0, N=0
		issue(FPU_FABS, 2, 3, 0, 0);
		chk(dut.fpreg[3]===P1, "FABS -> +1.0");
		chk(`CC_N==0, "CC N cleared after FABS");

		// FTST zero -> Z=1
		issue(FPU_FMOVE_LD, 0, 4, 0, ZERO);
		issue(FPU_FTST, 4, 0, 0, 0);
		chk(`CC_Z==1 && `CC_I==0 && `CC_NAN==0, "CC Z for zero");

		// FTST +Inf -> I=1
		issue(FPU_FMOVE_LD, 0, 5, 0, PINF);
		issue(FPU_FTST, 5, 0, 0, 0);
		chk(`CC_I==1 && `CC_Z==0 && `CC_NAN==0, "CC I for +Inf");

		// FTST NaN -> NAN=1
		issue(FPU_FMOVE_LD, 0, 6, 0, QNAN);
		issue(FPU_FTST, 6, 0, 0, 0);
		chk(`CC_NAN==1, "CC NAN for NaN");

		// FMOVE FP0->ext_out (store)
		issue(FPU_FMOVE_ST, 0, 0, 0, 0);
		chk(ext_out===P1, "FMOVE FP0->ext store");

		// FPCR round-trip
		issue(FPU_TO_CR, 0, 0, CR_FPCR, 80'h0000_0000_0000_0000_0030);  // RZ, ext prec
		chk(fpcr_out===32'h00000030, "FPCR write");
		issue(FPU_FROM_CR, 0, 0, CR_FPCR, 0);
		chk(ext_out[31:0]===32'h00000030, "FPCR read-back");

		// arithmetic not implemented yet -> unimpl (trap to FPSP)
		unimpl_latch = 0;
		issue(FPU_ARITH, 0, 0, 0, 0);
		chk(unimpl_latch===1'b1, "FADD-class op raises unimpl (FPSP)");

		if (errors==0) $display("PASS: FPU foundation (regs, FMOVE/FABS/FNEG/FTST, classify, FPCR, unimpl)");
		else           $display("FAIL: FPU foundation, %0d error(s)", errors);
		$finish;
	end
endmodule
