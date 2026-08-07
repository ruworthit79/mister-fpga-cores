//============================================================================
//  iop - 6502-based Intelligent I/O Processor (Quadra 900/950, from the IIfx)
//
//  Two IOPs are present: the "SWIM IOP" drives the SWIM floppy controller and
//  the ADB transceiver, and the "SCC IOP" drives the Z8530 serial. Each is a
//  small 6502 with its own RAM running Apple firmware, communicating with the
//  68040 through a shared message-passing mailbox.
//
//  Emulation options:
//   A. Faithful: instantiate a 6502 core + IOP firmware ROM + mailbox RAM.
//   B. Bypass (recommended first): emulate the *mailbox protocol* directly in
//      logic and connect ADB/SWIM to the rest of the core, skipping the 6502.
//      This is how several emulators handle the IIfx/Quadra IOPs.
//
//  STATUS: stub for option B (mailbox shell). No 6502 yet.
//============================================================================

module iop
(
	input             clk,
	input             reset,

	// 68040-side mailbox access
	input             sel,
	input      [7:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,
	output reg        ack,
	output            irq
);

	assign irq = 1'b0;

	always @(posedge clk) begin
		dout <= 8'h00;
		ack  <= sel & ~ack;
	end

endmodule
