//============================================================================
//  iobus - JDB + Relayer I/O bus adapter (Quadra 900/950)
//
//  Real parts: the JDB (Junction Data Bus) handles the data path and the
//  Relayer handles chip-selects / DSACK / arbitration, bridging the 68040
//  system bus to an IIfx-style I/O bus. That I/O bus carries VIA1, VIA2, the
//  two IOPs (SWIM+ADB, SCC), the two NCR 53C96 SCSI controllers, the SONIC
//  Ethernet, and the sound cluster. I/O space is $5000_0000-$5FFF_FFFF.
//
//  This module aggregates those peripherals, muxes their read data and rolls
//  up their interrupts into the 68040 IPL[2:0].
//
//  STATUS: stub. Sub-decode and peripheral instantiations are TODO. Acks
//  cycles and returns 0 so the bus does not hang; IPL held at 0 (no IRQ).
//============================================================================

module iobus
(
	input             clk,
	input             reset,
	input             sel,
	input      [23:0] addr,
	input      [31:0] din,
	output reg [31:0] dout,
	input             rw,
	output reg        ack,
	output     [2:0]  ipl
);

	assign ipl = 3'b000;   // TODO: prioritise VIA/SCSI/SONIC/IOP interrupts.

	always @(posedge clk) begin
		ack  <= 1'b0;
		dout <= 32'h0;
		if (sel && !ack) ack <= 1'b1;
	end

	// TODO: sub-address decode within $50xx_xxxx and instantiate:
	//   via  (x2), iop (x2), scsi_ncr53c96 (x2), sonic, asc/DFAC control.

endmodule
