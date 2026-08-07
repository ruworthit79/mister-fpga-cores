//============================================================================
//  adb - Apple Desktop Bus host (Quadra 900/950)
//
//  On this machine ADB is managed by an IOP + an ADB transceiver (NOT by
//  Egret/Cuda). ADB is a single-wire, open-collector, host-polled serial bus
//  for keyboard and mouse (and other low-speed devices).
//
//  For MiSTer, the host side connects PS/2 keyboard/mouse from hps_io and
//  presents them to the OS as ADB devices (default addresses: keyboard $2,
//  mouse $3). This module translates PS/2 events into ADB register data.
//
//  STATUS: stub. PS/2 -> ADB translation and the ADB host state machine (Talk/
//  Listen/Flush, SRQ, address resolution) are TODO.
//============================================================================

module adb
(
	input             clk,
	input             reset,

	// PS/2 inputs from hps_io
	input      [10:0] ps2_key,
	input      [24:0] ps2_mouse,

	// Link to the SWIM IOP / VIA1
	input             cmd_stb,
	input      [7:0]  cmd,
	output reg [7:0]  data,
	output            srq          // service request
);

	assign srq = 1'b0;

	always @(posedge clk) data <= 8'h00;

	// TODO:
	//  [ ] PS/2 set-2 scancode -> ADB keyboard register 0 mapping.
	//  [ ] PS/2 mouse -> ADB mouse register 0 (relative + button).
	//  [ ] ADB host command decode (Talk/Listen/Flush/reset) and SRQ.

endmodule
