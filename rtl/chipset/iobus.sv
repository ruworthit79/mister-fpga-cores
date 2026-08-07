//============================================================================
//  iobus - JDB + Relayer I/O bus adapter (Quadra 900/950)
//
//  Bridges the 68040 system bus to the IIfx-style I/O bus and aggregates the
//  I/O-space peripherals. I/O space is $5000_0000-$5FFF_FFFF; the two VIAs sit
//  at (Mac-standard) VIA1 = $50F0_0000 and VIA2 = $50F0_2000, registers spaced
//  512 bytes apart (register n at offset n*0x200).
//
//  This wires the two 6522 VIAs, generates their phase-2 clock enable, muxes
//  read data, and rolls the VIA interrupts up into the 68k IPL (active low).
//  VIA1 CA1 receives the DAFB vertical-blank so the OS gets a VBL interrupt.
//
//  STATUS: VIAs live; the other I/O devices (IOPs, SCC, SCSI, SONIC, sound)
//  are still stubbed and decoded as "no device" (read 0). NOTE: the VIA data
//  byte lane on a real Mac is not necessarily D0-D7; using the low byte here
//  and flagging it for revisit against a real ROM.
//============================================================================

module iobus
#(
	parameter CE_DIV   = 32,       // system-clock / CE_DIV ~= VIA phase-2 rate
	parameter TICK_DIV = 50000000  // system-clock / TICK_DIV ~= 1 Hz RTC tick
)
(
	input             clk,
	input             reset,
	input             sel,
	input      [23:0] addr,
	input      [31:0] din,
	output reg [31:0] dout,
	input             rw,
	output reg        ack,

	input             vbl,         // DAFB vertical blank (to VIA1 CA1)

	// input devices
	input      [10:0] ps2_key,
	input      [24:0] ps2_mouse,

	// external interrupt sources (e.g. SCSI) folded into level 2
	input             ext_irq2,

	// PRAM backup port (to hps_io persistence)
	input      [7:0]  bk_addr,
	input             bk_wr,
	input      [7:0]  bk_din,
	output     [7:0]  bk_dout,

	output     [2:0]  ipl          // 68k interrupt level, active low
);

	// ---- phase-2 clock enable for the VIAs ----
	reg [7:0] ce_cnt;
	reg       via_ce;
	always @(posedge clk) begin
		if (reset) begin ce_cnt <= 0; via_ce <= 0; end
		else if (ce_cnt == CE_DIV-1) begin ce_cnt <= 0; via_ce <= 1'b1; end
		else begin ce_cnt <= ce_cnt + 1'b1; via_ce <= 1'b0; end
	end

	// ---- decode (within $5x_xxxxxx I/O space; addr is cpu_addr[23:0]) ----
	// The Quadra decodes the VIA page incompletely: the VIAs occupy the low
	// $4000 of the $50F0_0000 "device page" (VIA1 = $F0_0000, VIA2 = $F0_2000,
	// register at bits [12:9]), but the upper address nibble ($F) is NOT fully
	// decoded, so the VIAs alias throughout the $5x_xxxxxx I/O space every
	// $10_0000. The ROM's hardware-detection probe depends on this: it verifies
	// VIA1 IER at $50F0_1C00 responds identically at $5100_1C00 (= +$100000).
	// So select the VIA on the register-page pattern (addr[19:14]==0) and treat
	// addr[23:20] as don't-care, rather than requiring addr[23:16]==$F0.
	// (SCC $F0_4000, SONIC $F0_A000 have addr[15:14]!=0, so they are excluded;
	//  SCSI/ASC are decoded and muxed out one level up in quadra950.sv.)
	wire in_via   = (addr[19:14] == 6'b0);       // VIA page, alias-tolerant
	wire via1_sel = sel & in_via & ~addr[13];    // ...0_0000..0_1FFF (+ aliases)
	wire via2_sel = sel & in_via &  addr[13];    // ...0_2000..0_3FFF (+ aliases)
	wire [3:0] via_reg = addr[12:9];             // 512-byte register spacing

	// ---- VIA1 ----
	wire [7:0] via1_dout, via2_dout;
	wire       via1_irq,  via2_irq;
	wire [7:0] via1_pa, via1_pb, via1_pa_dir, via1_pb_dir;
	wire [7:0] via2_pa, via2_pb, via2_pa_dir, via2_pb_dir;

	// ---- Caboose RTC/PRAM on VIA1 port B (bit0 data, bit1 clk, bit2 enb) ----
	wire rtc_dout, rtc_oe;
	wire [7:0] via1_pb_in = {7'b0, rtc_oe ? rtc_dout : 1'b0};

	// 1 Hz tick for the RTC seconds counter
	reg [31:0] tick_cnt; reg tick_1hz;
	always @(posedge clk) begin
		if (reset) begin tick_cnt <= 0; tick_1hz <= 0; end
		else if (tick_cnt == TICK_DIV-1) begin tick_cnt <= 0; tick_1hz <= 1'b1; end
		else begin tick_cnt <= tick_cnt + 1'b1; tick_1hz <= 1'b0; end
	end

	caboose caboose (
		.clk(clk), .reset(reset), .tick_1hz(tick_1hz),
		.rtc_enb(via1_pb[2]), .rtc_clk(via1_pb[1]), .rtc_data_in(via1_pb[0]),
		.rtc_data_out(rtc_dout), .rtc_data_oe(rtc_oe),
		.bk_addr(bk_addr), .bk_wr(bk_wr), .bk_din(bk_din), .bk_dout(bk_dout)
	);

	// ---- ADB: PS/2 keyboard/mouse translation (host command side awaits the
	//      SWIM IOP mailbox; verified standalone, cmd interface stubbed here) ----
	wire [15:0] adb_data; wire adb_valid, adb_srq;
	adb adb (
		.clk(clk), .reset(reset), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
		.cmd_stb(1'b0), .cmd(8'h00), .data(adb_data), .valid(adb_valid), .srq(adb_srq)
	);

	// Byte lane: the 68040 places a byte access to a 4-aligned register address
	// on D31-D24 (big-endian). VIA registers are at $50F0_0000 + reg*0x200, all
	// 4-aligned, so the CPU byte is din[31:24] (ROM-validated address map).
	via via1 (
		.clk(clk), .reset(reset), .ce(via_ce),
		.sel(via1_sel), .addr(via_reg), .din(din[31:24]), .dout(via1_dout), .rw(rw),
		.irq(via1_irq),
		.pa_in(8'h00), .pa_out(via1_pa), .pa_dir(via1_pa_dir),
		.pb_in(via1_pb_in), .pb_out(via1_pb), .pb_dir(via1_pb_dir),
		.ca1(vbl), .cb1(1'b0)
	);

	via via2 (
		.clk(clk), .reset(reset), .ce(via_ce),
		.sel(via2_sel), .addr(via_reg), .din(din[31:24]), .dout(via2_dout), .rw(rw),
		.irq(via2_irq),
		.pa_in(8'h00), .pa_out(via2_pa), .pa_dir(via2_pa_dir),
		.pb_in(8'h00), .pb_out(via2_pb), .pb_dir(via2_pb_dir),
		.ca1(1'b0), .cb1(1'b0)
	);

	// ---- interrupt priority (level 2 = VIA2/SCSI, level 1 = VIA1), active low --
	wire [2:0] level = (via2_irq | ext_irq2) ? 3'd2 : via1_irq ? 3'd1 : 3'd0;
	assign ipl = ~level;

	// ---- read mux + acknowledge ----
	// Read data returns on the high byte to match the CPU's byte-access lane.
	always @(posedge clk) begin
		ack <= 1'b0;
		if (via1_sel)      dout <= {via1_dout, 24'd0};
		else if (via2_sel) dout <= {via2_dout, 24'd0};
		else               dout <= 32'd0;          // unmapped I/O reads as 0
		if (sel && !ack) ack <= 1'b1;
	end

endmodule
