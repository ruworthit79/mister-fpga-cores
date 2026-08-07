//============================================================================
//  mmu_040 - 68040 Memory Management Unit (Phase 5 interface anchor)
//
//  Sits between the CPU's virtual address and the physical TS/TA bus. See
//  docs/PHASE5_SCOPE.md milestone 5.2.
//
//  STATUS: Level-A stub = transparent (1:1) translation. This is not a
//  placeholder that does nothing useful - a 1:1 MMU that merely answers its
//  register interface is exactly what non-VM Mac OS boot needs. The real
//  3-level table walk + 64-entry ATC (milestone 5.2b) replaces the pass-through
//  below while keeping this interface.
//
//  68040 MMU registers (accessed by the CPU via MOVEC):
//    TC     translation control (enable, 4K/8K page size)
//    ITT0/1 instruction transparent translation
//    DTT0/1 data transparent translation
//    URP    user root pointer      SRP supervisor root pointer
//    MMUSR  status (result of PTEST)
//  Instructions: PFLUSH/PFLUSHA (ATC invalidate), PTESTR/PTESTW (probe->MMUSR).
//============================================================================

module mmu_040
(
	input             clk,
	input             reset,

	// CPU (virtual) side
	input      [31:0] v_addr,
	input      [2:0]  fc,          // function code (user/super, data/prog)
	input             rw,          // 1 = read
	input             req,         // access request

	// Physical side (to the system TS/TA bus)
	output     [31:0] p_addr,
	output            fault,       // translation fault -> bus error (format $7)

	// MMU register interface (from MOVEC in cpu_wrapper)
	input      [2:0]  reg_sel,     // which MMU register
	input             reg_wr,
	input      [31:0] reg_din,
	output     [31:0] reg_dout
);

	// ---- register file (stored; not yet used for translation) ----
	reg [31:0] tc, itt0, itt1, dtt0, dtt1, urp, srp, mmusr;

	always @(posedge clk) begin
		if (reset) begin
			tc <= 0; itt0 <= 0; itt1 <= 0; dtt0 <= 0; dtt1 <= 0;
			urp <= 0; srp <= 0; mmusr <= 0;
		end else if (reg_wr) begin
			case (reg_sel)
				3'd0: tc   <= reg_din;
				3'd1: itt0 <= reg_din;
				3'd2: itt1 <= reg_din;
				3'd3: dtt0 <= reg_din;
				3'd4: dtt1 <= reg_din;
				3'd5: urp  <= reg_din;
				3'd6: srp  <= reg_din;
				default: mmusr <= reg_din;
			endcase
		end
	end

	assign reg_dout = (reg_sel==3'd0)?tc  :(reg_sel==3'd1)?itt0:(reg_sel==3'd2)?itt1:
	                  (reg_sel==3'd3)?dtt0:(reg_sel==3'd4)?dtt1:(reg_sel==3'd5)?urp :
	                  (reg_sel==3'd6)?srp :mmusr;

	// ---- Level-A translation: transparent 1:1, never faults ----
	assign p_addr = v_addr;
	assign fault  = 1'b0;

	// TODO (5.2b): when tc[enable] and the address is not covered by an
	// enabled ITTx/DTTx transparent window, walk the 3-level table from
	// URP/SRP (4K/8K pages), cache results in a 64-entry ATC, drive `fault` +
	// MMUSR on miss/protection, and honour PFLUSH/PTEST.
endmodule
