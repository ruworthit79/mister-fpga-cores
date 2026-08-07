//============================================================================
//  via - MOS 6522 Versatile Interface Adapter (VIA1 / VIA2 on the Quadra)
//
//  The Mac uses two VIAs. VIA1 carries the ROM overlay bit, sound enable, the
//  RTC/PRAM serial link (to Caboose) and the 1-second / vertical-blank
//  interrupts (on CA1/CA2/CB1); VIA2 carries NuBus/SCSI/slot interrupts.
//
//  This is a functional 6522: register file, timers T1 (one-shot + free-run)
//  and T2 (one-shot), the interrupt flag/enable registers (IFR/IER) with the
//  standard write-1-clear / set-or-clear semantics, 8-bit ports A/B with data
//  direction registers, and CA1/CB1 edge-triggered interrupts (edge selected
//  by PCR). Timers and edge sampling advance on `ce` (the VIA phase-2 enable).
//
//  Simplified vs. a real 6522: no shift-register (SR) engine, no CA2/CB2
//  handshake output modes, no T2 pulse-counting mode, no PB7 timer output.
//  These are not needed to bring the Mac ROM up; documented as TODO.
//
//  Verified in sim/iverilog/tb_via.v.
//============================================================================

module via
(
	input             clk,
	input             reset,
	input             ce,          // phase-2 (timer/edge) clock enable

	// CPU register interface
	input             sel,         // chip select (this VIA is addressed)
	input      [3:0]  addr,        // register 0..15
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,          // 1 = read, 0 = write

	output            irq,         // active high (invert for 68k IPL)

	// Ports (bidirectional split into in/out + direction)
	input      [7:0]  pa_in,
	output     [7:0]  pa_out,
	output     [7:0]  pa_dir,      // 1 = output
	input      [7:0]  pb_in,
	output     [7:0]  pb_out,
	output     [7:0]  pb_dir,

	// Control lines (interrupt inputs)
	input             ca1,
	input             cb1
);

	// Registers
	reg  [7:0] ora, orb, ddra, ddrb;
	reg [15:0] t1c, t1l;
	reg  [7:0] t2l_l;
	reg [15:0] t2c;
	reg  [7:0] acr, pcr;
	reg  [6:0] ifr;                 // bit6=T1 bit5=T2 bit4=CB1 bit1=CA1 ...
	reg  [6:0] ier;
	reg        t1_active, t2_active;

	// IFR bit positions
	localparam IB_CA1 = 1, IB_CB1 = 4, IB_T2 = 5, IB_T1 = 6;

	assign pa_out = ora;
	assign pb_out = orb;
	assign pa_dir = ddra;
	assign pb_dir = ddrb;

	wire irq_any = |(ifr & ier);
	assign irq = irq_any;

	// Port read-back: output bits read the OR register, input bits the pin.
	wire [7:0] pa_read = (ora & ddra) | (pa_in & ~ddra);
	wire [7:0] pb_read = (orb & ddrb) | (pb_in & ~ddrb);

	// ---- CPU read (combinational) ----
	always @(*) begin
		case (addr)
			4'h0: dout = pb_read;
			4'h1: dout = pa_read;
			4'h2: dout = ddrb;
			4'h3: dout = ddra;
			4'h4: dout = t1c[7:0];
			4'h5: dout = t1c[15:8];
			4'h6: dout = t1l[7:0];
			4'h7: dout = t1l[15:8];
			4'h8: dout = t2c[7:0];
			4'h9: dout = t2c[15:8];
			4'hA: dout = 8'h00;              // SR (not implemented)
			4'hB: dout = acr;
			4'hC: dout = pcr;
			4'hD: dout = {irq_any, ifr};
			4'hE: dout = {1'b1, ier};
			4'hF: dout = pa_read;
			default: dout = 8'h00;
		endcase
	end

	// Edge detection on CA1/CB1 (PCR bit0 / bit4 select active edge: 1=rising)
	reg ca1_d, cb1_d;
	wire ca1_edge = (pcr[0] ? (ca1 & ~ca1_d) : (~ca1 & ca1_d));
	wire cb1_edge = (pcr[4] ? (cb1 & ~cb1_d) : (~cb1 & cb1_d));

	wire wr = sel & ~rw;
	wire rd = sel &  rw;

	always @(posedge clk) begin
		if (reset) begin
			ora <= 0; orb <= 0; ddra <= 0; ddrb <= 0;
			t1c <= 0; t1l <= 0; t2c <= 0; t2l_l <= 0;
			acr <= 0; pcr <= 0; ifr <= 0; ier <= 0;
			t1_active <= 0; t2_active <= 0;
			ca1_d <= 0; cb1_d <= 0;
		end else begin
			// ---- timers / edges advance on the phase-2 enable ----
			if (ce) begin
				// T1
				if (t1_active) begin
					if (t1c == 16'd0) begin
						ifr[IB_T1] <= 1'b1;
						if (acr[6]) t1c <= t1l;      // free-run: reload
						else        t1_active <= 1'b0;
					end else t1c <= t1c - 16'd1;
				end
				// T2 (one-shot)
				if (t2_active) begin
					if (t2c == 16'd0) begin
						ifr[IB_T2] <= 1'b1;
						t2_active  <= 1'b0;
					end else t2c <= t2c - 16'd1;
				end
				// CA1/CB1 edges
				ca1_d <= ca1; cb1_d <= cb1;
				if (ca1_edge) ifr[IB_CA1] <= 1'b1;
				if (cb1_edge) ifr[IB_CB1] <= 1'b1;
			end

			// ---- CPU writes ----
			if (wr) begin
				case (addr)
					4'h0: begin orb <= din; ifr[IB_CB1] <= 1'b0; end
					4'h1: begin ora <= din; ifr[IB_CA1] <= 1'b0; end
					4'h2: ddrb <= din;
					4'h3: ddra <= din;
					4'h4: t1l[7:0]  <= din;                          // T1C-L -> latch low
					4'h5: begin t1l[15:8] <= din; t1c <= {din, t1l[7:0]};
					            ifr[IB_T1] <= 1'b0; t1_active <= 1'b1; end
					4'h6: t1l[7:0]  <= din;
					4'h7: begin t1l[15:8] <= din; ifr[IB_T1] <= 1'b0; end
					4'h8: t2l_l <= din;                              // T2C-L latch
					4'h9: begin t2c <= {din, t2l_l}; ifr[IB_T2] <= 1'b0;
					            t2_active <= 1'b1; end
					4'hB: acr <= din;
					4'hC: pcr <= din;
					4'hD: ifr <= ifr & ~din[6:0];                    // write-1-clear
					4'hE: if (din[7]) ier <= ier |  din[6:0];        // set
					      else        ier <= ier & ~din[6:0];        // clear
					4'hF: ora <= din;
					default: ;
				endcase
			end

			// ---- read side effects (flag clears) ----
			if (rd) begin
				case (addr)
					4'h0: ifr[IB_CB1] <= 1'b0;
					4'h1: ifr[IB_CA1] <= 1'b0;
					4'h4: ifr[IB_T1]  <= 1'b0;   // read T1C-L clears T1 flag
					4'h8: ifr[IB_T2]  <= 1'b0;   // read T2C-L clears T2 flag
					default: ;
				endcase
			end
		end
	end

endmodule
