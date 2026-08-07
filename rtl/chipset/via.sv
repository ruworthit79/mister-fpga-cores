//============================================================================
//  via - 6522 Versatile Interface Adapter (VIA1 + VIA2 on the Quadra)
//
//  The Mac uses two VIAs. VIA1 handles the RTC/PRAM interface (via Caboose),
//  the ADB (via IOP), sound enable, the ROM overlay bit, and the 1-second /
//  vertical-blank interrupts. VIA2 handles NuBus/SCSI/slot interrupts and
//  miscellaneous control. Both are memory-mapped in I/O space.
//
//  STATUS: stub. A well-tested open 6522 core can be dropped in here; the
//  register file, timers, shift register and interrupt logic are TODO.
//============================================================================

module via
(
	input             clk,
	input             reset,
	input             sel,
	input      [3:0]  addr,     // 16 VIA registers
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,        // 1 = read
	output            irq,

	// Port A/B (function differs VIA1 vs VIA2)
	input      [7:0]  pa_in,
	output     [7:0]  pa_out,
	input      [7:0]  pb_in,
	output     [7:0]  pb_out
);

	assign irq    = 1'b0;
	assign pa_out = 8'h00;
	assign pb_out = 8'h00;

	always @(posedge clk) dout <= 8'h00;

	// TODO: integrate a 6522 core (register file, T1/T2 timers, SR, IER/IFR).

endmodule
