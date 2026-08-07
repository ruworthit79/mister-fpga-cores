//============================================================================
//  fpu_040 - 68040 Floating-Point Unit (Phase 5 interface anchor)
//
//  Execution unit fed by decoded F-line (coprocessor id 1) instructions. See
//  docs/PHASE5_SCOPE.md milestone 5.3.
//
//  STATUS: Level-A stub = "not present" (68LC040 personality). Every FPU op is
//  reported as unimplemented so the CPU takes the F-line trap; the ROM then
//  sees a CPU without an FPU. This lets Mac OS boot without any FP hardware.
//
//  Path to a real FPU:
//    5.3b hardware arithmetic: FADD/FSUB/FMUL/FDIV/FSQRT/FABS/FNEG/FCMP/FMOVE/
//         FINT(RZ) across single/double/extended, rounding modes, FPSR/FPCR,
//         and the IEEE exception flags.
//    5.3c FPSP trap: unimplemented ops (FSIN/FCOS/FTAN/FETOX/FLOGN/FGETEXP…)
//         and packed-decimal data types trap to the software package (the real
//         68040 does the same; Apple ships the FPSP in the ROM/OS).
//============================================================================

module fpu_040
(
	input             clk,
	input             reset,

	// operation issue (from F-line decode in cpu_wrapper)
	input             op_valid,
	input      [15:0] opcode,      // F-line opword
	input      [15:0] cmdword,     // coprocessor command word
	input      [79:0] op_in,       // source operand (extended precision)
	output     [79:0] result,      // extended-precision result
	output     [31:0] fpsr,        // status (condition/exception bits)

	output            present,     // 1 = FPU present (0 = 68LC040)
	output            busy,
	output            done,
	output            unimpl       // trap to the FPSP (software)
);

	// ---- Level-A: no FPU. Report absent; trap any op. ----
	assign present = 1'b0;
	assign result  = 80'd0;
	assign fpsr    = 32'd0;
	assign busy    = 1'b0;
	assign done    = op_valid;      // "completed" by signalling a trap
	assign unimpl  = op_valid;      // -> F-line / FPSP handler

	// TODO (5.3b/5.3c): set present=1, implement the hardware arithmetic subset
	// with a pipelined datapath (keep it off the CPU critical path), maintain
	// FPSR/FPCR, and raise `unimpl` only for the ops/data-types the real 68040
	// leaves to the FPSP.
endmodule
