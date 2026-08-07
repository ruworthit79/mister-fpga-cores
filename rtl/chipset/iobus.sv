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
	parameter CE_DIV = 32          // system-clock / CE_DIV ~= VIA phase-2 rate
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

	// ---- decode (within $50xx_xxxx; addr is cpu_addr[23:0]) ----
	wire in_via   = (addr[23:16] == 8'hF0);      // $50F0_xxxx
	wire via1_sel = sel & in_via & ~addr[13];    // $F0_0000..$F0_1FFF
	wire via2_sel = sel & in_via &  addr[13];    // $F0_2000..$F0_3FFF
	wire [3:0] via_reg = addr[12:9];             // 512-byte register spacing

	// ---- VIA1 ----
	wire [7:0] via1_dout, via2_dout;
	wire       via1_irq,  via2_irq;
	wire [7:0] via1_pa, via1_pb, via1_pa_dir, via1_pb_dir;
	wire [7:0] via2_pa, via2_pb, via2_pa_dir, via2_pb_dir;

	via via1 (
		.clk(clk), .reset(reset), .ce(via_ce),
		.sel(via1_sel), .addr(via_reg), .din(din[7:0]), .dout(via1_dout), .rw(rw),
		.irq(via1_irq),
		.pa_in(8'h00), .pa_out(via1_pa), .pa_dir(via1_pa_dir),
		.pb_in(8'h00), .pb_out(via1_pb), .pb_dir(via1_pb_dir),
		.ca1(vbl), .cb1(1'b0)
	);

	via via2 (
		.clk(clk), .reset(reset), .ce(via_ce),
		.sel(via2_sel), .addr(via_reg), .din(din[7:0]), .dout(via2_dout), .rw(rw),
		.irq(via2_irq),
		.pa_in(8'h00), .pa_out(via2_pa), .pa_dir(via2_pa_dir),
		.pb_in(8'h00), .pb_out(via2_pb), .pb_dir(via2_pb_dir),
		.ca1(1'b0), .cb1(1'b0)
	);

	// ---- interrupt priority (VIA2 = level 2, VIA1 = level 1), active low ----
	wire [2:0] level = via2_irq ? 3'd2 : via1_irq ? 3'd1 : 3'd0;
	assign ipl = ~level;

	// ---- read mux + acknowledge ----
	always @(posedge clk) begin
		ack <= 1'b0;
		if (via1_sel)      dout <= {24'd0, via1_dout};
		else if (via2_sel) dout <= {24'd0, via2_dout};
		else               dout <= 32'd0;          // unmapped I/O reads as 0
		if (sel && !ack) ack <= 1'b1;
	end

endmodule
