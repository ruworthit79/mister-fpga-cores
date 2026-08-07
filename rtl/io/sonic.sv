//============================================================================
//  sonic - National Semiconductor DP83932 SONIC Ethernet (Quadra 900/950)
//
//  Built-in Ethernet on the I/O bus (NOT bridged through NuBus), presented to
//  the outside world via an AAUI connector. The 950 uses the 25 MHz SONIC to
//  match its faster I/O bus. The SONIC is a DMA-driven controller with
//  descriptor rings in main memory.
//
//  STATUS: stub, and lowest priority. Networking on MiSTer would require
//  bridging to real network hardware; most use cases do not need it.
//============================================================================

module sonic
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

	always @(posedge clk) begin
		dout <= 32'h0;
		ack  <= sel & ~ack;
	end

endmodule
