//============================================================================
//  fpu_040 - 68040 Floating-Point Unit (Phase 8 / roadmap 5.3)
//
//  Owns the FPU programming model (FP0-FP7 in 80-bit extended precision, plus
//  FPCR / FPSR / FPIAR) and executes decoded F-line coprocessor-id-1
//  instructions issued by the CPU's F-line decode (see docs/FPU_SCOPE.md).
//
//  IMPLEMENTED (this phase - the "structural" ops, no arithmetic datapath):
//    - Register model: FP0-FP7, FPCR, FPSR, FPIAR.
//    - FMOVE FPm,FPn ; FMOVE <ext-operand>,FPn (load) ; FMOVE FPn,<out> (store)
//    - FABS / FNEG / FTST  (sign / classify only)
//    - FMOVE to/from the control registers (FPCR/FPSR/FPIAR)
//    - IEEE classification -> FPSR condition codes (N,Z,Inf,NaN)
//    - present = 1 (reports an FPU to the ROM/OS for the ops it handles)
//
//  NOT YET (raise `unimpl` -> FPSP software, exactly as a real 68040 does for
//  its unimplemented set):
//    - Arithmetic: FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/FINT and format conversions
//      needing rounding (single<->double<->extended). These need the IEEE
//      datapath (roadmap 5.3b) - the big remaining lift.
//    - Transcendentals (FSIN/FCOS/FETOX/...) and packed decimal: FPSP (5.3c).
//
//  The extended-precision format (80 bits):
//    [79]     sign
//    [78:64]  15-bit biased exponent
//    [63]     explicit integer bit
//    [62:0]   fraction
//============================================================================

module fpu_040
(
	input             clk,
	input             reset,

	// ---- command issue (from F-line decode) ----
	input             op_valid,   // 1-cycle strobe: execute `cmd`
	input      [4:0]  cmd,        // FPU_* command (below)
	input      [2:0]  src_reg,    // FPm source register select
	input      [2:0]  dst_reg,    // FPn destination register select
	input      [2:0]  cr_sel,     // control-reg select for TO/FROM_CR (below)
	input      [79:0] ext_in,     // external operand (FMOVE <ea>,FPn ; TO_CR)
	output reg [79:0] ext_out,    // external result (FMOVE FPn,<ea> ; FROM_CR)

	// ---- status / handshake ----
	output     [31:0] fpsr_out,   // live FPSR (condition + exception bits)
	output     [31:0] fpcr_out,   // live FPCR
	output            present,    // 1 = FPU present (vs 68LC040 = 0)
	output reg        done,       // op completed this cycle
	output reg        unimpl      // op not implemented here -> trap to FPSP
);

	// ---- command encoding ----
	localparam [4:0]
		FPU_NOP      = 5'd0,   // FNOP (and unrecognised -> unimpl if not listed)
		FPU_FMOVE_RR = 5'd1,   // FPn <- FPm
		FPU_FMOVE_LD = 5'd2,   // FPn <- ext_in            (FMOVE <ea>,FPn)
		FPU_FMOVE_ST = 5'd3,   // ext_out <- FPn           (FMOVE FPn,<ea>)
		FPU_FABS     = 5'd4,   // FPn <- |FPm|
		FPU_FNEG     = 5'd5,   // FPn <- -FPm
		FPU_FTST     = 5'd6,   // set CC from FPm
		FPU_TO_CR    = 5'd7,   // ctrl-reg <- ext_in       (FMOVE <ea>,FPcr)
		FPU_FROM_CR  = 5'd8,   // ext_out <- ctrl-reg      (FMOVE FPcr,<ea>)
		FPU_ARITH    = 5'd9;   // FADD/FSUB/... -> unimpl for now (needs datapath)

	// control-reg select (cr_sel) for TO_CR / FROM_CR
	localparam [2:0] CR_FPCR = 3'd1, CR_FPSR = 3'd2, CR_FPIAR = 3'd4;

	// ---- programming model ----
	reg [79:0] fpreg [0:7];       // FP0..FP7
	reg [31:0] FPCR;              // control  (rounding/precision + exc enables)
	reg [31:0] FPSR;              // status   (CC[27:24], quotient, exc, accrued)
	reg [31:0] FPIAR;            // instruction address register

	assign present  = 1'b1;
	assign fpsr_out = FPSR;
	assign fpcr_out = FPCR;

	// ---- IEEE classification of an extended-precision value ----
	//   FPSR condition codes: N=bit27, Z=bit26, I(nf)=bit25, NAN=bit24
	function [3:0] classify(input [79:0] v);
		reg        s;
		reg [14:0] e;
		reg [63:0] m;      // integer bit + fraction
		reg n, z, inf, nan;
		begin
			s = v[79];
			e = v[78:64];
			m = v[63:0];
			z   = (e == 15'd0)      && (m == 64'd0);
			inf = (e == 15'h7FFF)   && (v[62:0] == 63'd0);   // integer bit ignored
			nan = (e == 15'h7FFF)   && (v[62:0] != 63'd0);
			n   = s && !nan;         // NaN has no sign meaning for the N bit
			classify = {n, z, inf, nan};
		end
	endfunction

	// merge new condition codes into FPSR[27:24], leaving other bits intact
	task set_cc(input [3:0] cc);
		begin
			FPSR[27] <= cc[3];   // N
			FPSR[26] <= cc[2];   // Z
			FPSR[25] <= cc[1];   // I (infinity)
			FPSR[24] <= cc[0];   // NAN
		end
	endtask

	integer i;
	reg [79:0] src;              // FPm operand
	reg [3:0]  cc;

	always @(posedge clk) begin
		done   <= 1'b0;
		unimpl <= 1'b0;

		if (reset) begin
			for (i = 0; i < 8; i = i + 1) fpreg[i] <= 80'd0;
			FPCR  <= 32'd0;
			FPSR  <= 32'd0;
			FPIAR <= 32'd0;
			ext_out <= 80'd0;
		end
		else if (op_valid) begin
			src = fpreg[src_reg];
			done <= 1'b1;                 // most ops complete in one cycle
			case (cmd)
				FPU_NOP: ;                 // FNOP: nothing (CC unchanged)

				FPU_FMOVE_RR: begin
					fpreg[dst_reg] <= src;
					set_cc(classify(src));
				end

				FPU_FMOVE_LD: begin
					fpreg[dst_reg] <= ext_in;
					set_cc(classify(ext_in));
				end

				FPU_FMOVE_ST: begin
					ext_out <= fpreg[src_reg];
				end

				FPU_FABS: begin
					fpreg[dst_reg] <= {1'b0, src[78:0]};
					set_cc(classify({1'b0, src[78:0]}));
				end

				FPU_FNEG: begin
					fpreg[dst_reg] <= {~src[79], src[78:0]};
					set_cc(classify({~src[79], src[78:0]}));
				end

				FPU_FTST: begin
					set_cc(classify(src));
				end

				FPU_TO_CR: begin
					case (cr_sel)
						CR_FPCR:  FPCR  <= ext_in[31:0];
						CR_FPSR:  FPSR  <= ext_in[31:0];
						CR_FPIAR: FPIAR <= ext_in[31:0];
						default:  ;
					endcase
				end

				FPU_FROM_CR: begin
					case (cr_sel)
						CR_FPCR:  ext_out <= {48'd0, FPCR};
						CR_FPSR:  ext_out <= {48'd0, FPSR};
						CR_FPIAR: ext_out <= {48'd0, FPIAR};
						default:  ext_out <= 80'd0;
					endcase
				end

				// Arithmetic and rounding conversions are not implemented yet:
				// signal unimpl so the CPU takes the F-line trap and the FPSP
				// software package handles it (exactly what a real 040 does for
				// its unimplemented instruction/data-type set).
				default: begin
					done   <= 1'b0;
					unimpl <= 1'b1;
				end
			endcase
		end
	end

endmodule
