//============================================================================
//  yancc - "Yet Another NuBus Controller Chip" (Quadra 900/950)
//
//  Real part: bridges the 68040 system bus to the NuBus, together with two
//  16-bit transceivers. Five NuBus slots ($A-$E) plus the built-in video in
//  the slot $9 region. Standard-slot space $F900_0000-$FEFF_FFFF (16MB/slot);
//  superslot space $9000_0000-$EFFF_FFFF (256MB/slot). NuBus '90 features
//  (20MHz 2x clock, block transfers) partially supported. One-longword write
//  buffer with a write-error interrupt.
//
//  STATUS: stub. Needed only once NuBus card emulation is on the table; most
//  software runs without any NuBus cards, so this is low priority.
//============================================================================

module yancc
(
	input             clk,
	input             reset,
	input             sel,
	input      [31:0] addr,
	input      [31:0] din,
	output reg [31:0] dout,
	input             rw,
	output reg        ack,
	output            irq
);

	assign irq = 1'b0;

	// No card present: return bus-error-like behaviour (ack with 0). A real
	// implementation would assert TEA on access to an empty slot.
	always @(posedge clk) begin
		ack  <= 1'b0;
		dout <= 32'hFFFF_FFFF;
		if (sel && !ack) ack <= 1'b1;
	end

endmodule
