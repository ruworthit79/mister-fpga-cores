//============================================================================
//  caboose - RTC / PRAM / power / keyswitch microcontroller (Quadra 900/950)
//
//  Real part: an Egret-family (68HC05) custom IC that manages the real-time
//  clock, parameter RAM (PRAM), system power and the front-panel keyswitch.
//  It talks to the CPU through VIA1 (a serial protocol). It is NOT the ADB
//  manager on this machine - ADB is handled by an IOP. (MAME substitutes its
//  `egret` device for Caboose as a compatibility convenience.)
//
//  STATUS: stub. Provides a place for the RTC/PRAM state machine and a
//  battery-backed PRAM array (persisted to the MiSTer save file eventually).
//============================================================================

module caboose
(
	input             clk,
	input             reset,

	// VIA1-side serial link
	input             via_clk,
	input             via_data_in,
	output            via_data_out,

	// Wall-clock seconds tick (1 Hz) generated in the framework/testbench
	input             tick_1hz
);

	assign via_data_out = 1'b0;

	// TODO:
	//  [ ] 32-bit seconds counter (Mac epoch = 1 Jan 1904).
	//  [ ] 256 bytes PRAM (extended) with the RTC command protocol.
	//  [ ] Serialise/deserialise over the VIA1 link.

endmodule
