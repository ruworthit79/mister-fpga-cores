//============================================================================
//  cpu_wrapper - 68040 bus adapter / CPU integration point
//
//  THIS IS THE CENTRAL UNSOLVED PROBLEM OF THE PROJECT. See docs/ROADMAP.md
//  and docs/CPU_NOTES.md.
//
//  There is no mature, open-source, synthesizable MC68040 (with its integrated
//  FPU, paged MMU and 4KB+4KB caches). Options, in order of realism:
//
//   1. Start from a 68020/030-class core (e.g. the TG68K/aoTG68 family or
//      Moidore's "N68K") to bring the *system* up (video, I/O, boot ROM),
//      accepting that FPU/MMU-dependent software will not run. This is the
//      recommended first milestone.
//   2. Extend that core toward 68040 behaviour incrementally: MMU (needed by
//      A/UX and virtual memory), then the FPU, then cache/burst semantics.
//   3. Evaluate the Apollo/68080 ("AC68080") lineage - very capable but not
//      openly licensed for arbitrary reuse; licensing must be cleared first.
//
//  This wrapper defines the bus the rest of the system expects (a simplified
//  68040-style synchronous handshake: TS asserts a transfer, TA acknowledges)
//  and is where the chosen core's asynchronous/other bus gets translated.
//
//  STATUS: stub. Holds the bus idle (asserts no transfers) so the rest of the
//  scaffold runs without a CPU. Replace the body with the real core + adapter.
//============================================================================

module cpu_wrapper
(
	input             clk,
	input             ce,        // 33 MHz clock enable
	input             reset,

	output     [31:0] addr,
	output     [31:0] dout,      // CPU -> bus (write data)
	input      [31:0] din,       // bus -> CPU (read data)
	output     [3:0]  be,        // byte enables
	output            rw,        // 1 = read, 0 = write
	output            ts,        // transfer start
	input             ta,        // transfer acknowledge
	output     [2:0]  fc,        // function code

	input      [2:0]  ipl        // interrupt priority level
);

	// --- Placeholder: no bus activity until a real core is integrated. ---
	assign addr = 32'h0;
	assign dout = 32'h0;
	assign be   = 4'b0000;
	assign rw   = 1'b1;
	assign ts   = 1'b0;
	assign fc   = 3'b000;

	// Integration checklist (see docs/CPU_NOTES.md):
	//  [ ] Instantiate chosen 68k core here.
	//  [ ] Map its address/data/RW/SIZ signals to addr/dout/din/be/rw.
	//  [ ] Translate its bus handshake (DTACK/STERM or synchronous) to ts/ta.
	//  [ ] Drive fc[2:0] from the core's function-code outputs.
	//  [ ] Wire ipl[2:0] to the core's interrupt inputs.
	//  [ ] Gate the core with `ce` so it advances at the emulated 33 MHz.

endmodule
