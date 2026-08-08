//============================================================================
//  sonic - National Semiconductor DP83932 "SONIC" Ethernet (Quadra 900/950)
//
//  Built-in Ethernet on the I/O bus (NOT bridged through NuBus), presented to
//  the outside world via an AAUI connector. The 950 uses the 25 MHz SONIC to
//  match its faster I/O bus. On real hardware the SONIC is a DMA-driven
//  controller with transmit/receive descriptor rings in main memory.
//
//  This is a register-level FUNCTIONAL MODEL: a clean 16-bit register file
//  with the documented CR/ISR side-effects, so a driver can reset, configure
//  and probe the part. It deliberately models a "no link / no carrier" cable:
//    - the receiver never sees a packet, so RX (PKTRX) stays idle;
//    - a transmit request (CR.TXP) is completed-and-discarded immediately -
//      the part posts TXDN in the ISR (and raises irq if unmasked) and marks
//      the transmit "OK" in TCR, then self-clears TXP.
//
//  The CPU register interface follows the same convention as the other I/O
//  device models (sel/addr/din/dout/rw/ack/irq). SONIC registers are 16-bit
//  and word-addressed; addr is the register index (0x00..0x3F).
//
//  Verified in sim/iverilog/tb_sonic.v.
//
//  FIDELITY / TODO: no descriptor DMA engine is modelled. On TXP the model
//  does NOT walk the Transmit Descriptor Area (CTDA/UTDA), does not compute a
//  CRC and does not move packet data - it just posts completion. Likewise the
//  Receive Resource / Descriptor areas (URRA/RSA/REA/RRP/RWP, CRDA/URDA) are
//  plain readable/writable storage with no active RX pipeline. The CAM
//  (address filter) registers are storage only; LCAM just posts Load-CAM-Done.
//  Silicon Revision is a plausible constant. A full DMA/PHY implementation is
//  out of scope for this core.
//============================================================================

module sonic
(
	input             clk,
	input             reset,

	// CPU register interface (same convention as scsi_ncr53c96)
	input             sel,
	input      [5:0]  addr,        // register index 0x00..0x3F (word-addressed)
	input      [15:0] din,
	output reg [15:0] dout,
	input             rw,          // 1 = read
	output reg        ack,
	output reg        irq
);

	//------------------------------------------------------------------------
	//  DP83932 register map (word index)
	//------------------------------------------------------------------------
	localparam [5:0]
		R_CR   = 6'h00,   // Command Register
		R_DCR  = 6'h01,   // Data Configuration Register
		R_RCR  = 6'h02,   // Receive Control Register
		R_TCR  = 6'h03,   // Transmit Control Register
		R_IMR  = 6'h04,   // Interrupt Mask Register
		R_ISR  = 6'h05,   // Interrupt Status Register (write-1-to-clear)
		R_UTDA = 6'h06,   // Upper Transmit Descriptor Address
		R_CTDA = 6'h07,   // Current Transmit Descriptor Address
		R_URDA = 6'h0D,   // Upper Receive Descriptor Address
		R_CRDA = 6'h0E,   // Current Receive Descriptor Address
		R_EOBC = 6'h13,   // End Of Buffer Word Count
		R_URRA = 6'h14,   // Upper Receive Resource Address
		R_RSA  = 6'h15,   // Resource Start Address
		R_REA  = 6'h16,   // Resource End Address
		R_RRP  = 6'h17,   // Resource Read Pointer
		R_RWP  = 6'h18,   // Resource Write Pointer
		R_CEP  = 6'h21,   // CAM Entry Pointer
		R_CAP2 = 6'h22,   // CAM Address Port 2
		R_CAP1 = 6'h23,   // CAM Address Port 1
		R_CAP0 = 6'h24,   // CAM Address Port 0
		R_CE   = 6'h25,   // CAM Enable
		R_CDP  = 6'h26,   // CAM Descriptor Pointer
		R_CDC  = 6'h27,   // CAM Descriptor Count
		R_SR   = 6'h28,   // Silicon Revision (read-only)
		R_WT0  = 6'h29,   // Watchdog Timer 0
		R_WT1  = 6'h2A,   // Watchdog Timer 1
		R_RSC  = 6'h2B,   // Receive Sequence Counter
		R_CRCT = 6'h2C,   // CRC Error Tally
		R_FAET = 6'h2D,   // FAE Tally
		R_MPT  = 6'h2E,   // Missed Packet Tally
		R_MDT  = 6'h2F,   // Maximum Deferral Timer
		R_DCR2 = 6'h3F;   // Data Configuration Register 2

	// Plausible DP83932 silicon revision reported in SR.
	localparam [15:0] SILICON_REV = 16'h0006;

	//------------------------------------------------------------------------
	//  Command Register (CR) bit positions
	//------------------------------------------------------------------------
	localparam CR_HTX  = 0;   // Halt Transmission            (command, momentary)
	localparam CR_TXP  = 1;   // Transmit Packet              (self-clears on done)
	localparam CR_RXDIS= 2;   // Receiver Disable             (command, momentary)
	localparam CR_RXEN = 3;   // Receiver Enable  -> CR[3] is the enable status
	localparam CR_STP  = 4;   // Stop Timer                   (command, momentary)
	localparam CR_ST   = 5;   // Start Timer                  (command, momentary)
	localparam CR_RST  = 6;   // Software Reset               (level, host clears)
	localparam CR_RRRA = 7;   // Read RRA                     (command, momentary)
	localparam CR_LCAM = 8;   // Load CAM                     (command, momentary)

	//------------------------------------------------------------------------
	//  Interrupt Status / Mask (ISR / IMR) bit positions
	//------------------------------------------------------------------------
	//    bit 0  PINT  Programmable Interrupt
	//    bit 1  BR    Bus Retry Occurred
	//    bit 2  HBL   Heartbeat Lost
	//    bit 3  LCD   Load CAM Done
	//    bit 4  PKTRX Packet Received      (never set: no-carrier model)
	//    bit 5  TXDN  Transmit Done
	//    bit 6  TXER  Transmit Error
	//    bit 7  TC    Timer Complete
	//    bits 8..13   RDE/RBE/RBAE/CRC/FAE/MP resource & tally warnings (storage)
	localparam ISR_LCD   = 3;   // Load CAM Done
	localparam ISR_TXDN  = 5;   // Transmit Done

	//------------------------------------------------------------------------
	//  Register file
	//------------------------------------------------------------------------
	reg [15:0] cr, dcr, rcr, tcr, imr, isr;
	reg [15:0] utda, ctda, urda, crda, eobc;
	reg [15:0] urra, rsa, rea, rrp, rwp;
	reg [15:0] cep, cap2, cap1, cap0, ce, cdp, cdc;
	reg [15:0] wt0, wt1, rsc, crct, faet, mpt, mdt, dcr2;

	// One transfer per bus cycle (act only on the first cycle sel is high).
	wire cpu_rd = sel &  rw & ~ack;
	wire cpu_wr = sel & ~rw & ~ack;

	always @(posedge clk) begin
		if (reset) begin
			ack  <= 1'b0;
			irq  <= 1'b0;
			dout <= 16'h0000;
			cr   <= 16'h0000; dcr  <= 16'h0000; rcr  <= 16'h0000;
			tcr  <= 16'h0000; imr  <= 16'h0000; isr  <= 16'h0000;
			utda <= 16'h0000; ctda <= 16'h0000; urda <= 16'h0000;
			crda <= 16'h0000; eobc <= 16'h0000; urra <= 16'h0000;
			rsa  <= 16'h0000; rea  <= 16'h0000; rrp  <= 16'h0000;
			rwp  <= 16'h0000; cep  <= 16'h0000; cap2 <= 16'h0000;
			cap1 <= 16'h0000; cap0 <= 16'h0000; ce   <= 16'h0000;
			cdp  <= 16'h0000; cdc  <= 16'h0000; wt0  <= 16'h0000;
			wt1  <= 16'h0000; rsc  <= 16'h0000; crct <= 16'h0000;
			faet <= 16'h0000; mpt  <= 16'h0000; mdt  <= 16'h0000;
			dcr2 <= 16'h0000;
		end else begin
			ack   <= 1'b0;

			//---------------- CPU register write ----------------
			if (cpu_wr) begin
				ack <= 1'b1;
				case (addr)
					R_CR: begin
						// Start from the written value, then override the momentary
						// command bits so they never persist in the CR readback
						// (later non-blocking assignments to the same reg win).
						// TXP self-clears on completion; RXEN status lives in CR[3].
						cr           <= din;
						cr[CR_HTX]   <= 1'b0;
						cr[CR_TXP]   <= 1'b0;
						cr[CR_RXDIS] <= 1'b0;
						cr[CR_STP]   <= 1'b0;
						cr[CR_ST]    <= 1'b0;
						cr[CR_RRRA]  <= 1'b0;
						cr[CR_LCAM]  <= 1'b0;
						if (din[CR_RST]) begin
							// Software reset: drop interrupts and receiver enable,
							// hold RST set until the host clears it. Config regs
							// (DCR/RCR/TCR/IMR/pointers) are left intact so they can
							// be programmed while in reset, matching the real part.
							isr         <= 16'h0000;
							cr[CR_RXEN] <= 1'b0;
						end else begin
							if (din[CR_TXP]) begin
								// No-DMA model: complete-and-discard the transmit.
								isr[ISR_TXDN] <= 1'b1;   // Transmit Done
								tcr[0]        <= 1'b1;   // PTX: transmitted OK
							end
							if (din[CR_RXDIS]) cr[CR_RXEN]  <= 1'b0; // RXDIS clears en
							if (din[CR_LCAM])  isr[ISR_LCD] <= 1'b1; // Load CAM Done
						end
					end
					R_DCR : dcr  <= din;
					R_RCR : rcr  <= din;
					R_TCR : tcr  <= din;
					R_IMR : imr  <= din;
					R_ISR : isr  <= isr & ~din;   // write-1-to-clear
					R_UTDA: utda <= din;
					R_CTDA: ctda <= din;
					R_URDA: urda <= din;
					R_CRDA: crda <= din;
					R_EOBC: eobc <= din;
					R_URRA: urra <= din;
					R_RSA : rsa  <= din;
					R_REA : rea  <= din;
					R_RRP : rrp  <= din;
					R_RWP : rwp  <= din;
					R_CEP : cep  <= din;
					R_CAP2: cap2 <= din;
					R_CAP1: cap1 <= din;
					R_CAP0: cap0 <= din;
					R_CE  : ce   <= din;
					R_CDP : cdp  <= din;
					R_CDC : cdc  <= din;
					R_WT0 : wt0  <= din;
					R_WT1 : wt1  <= din;
					R_RSC : rsc  <= din;
					R_CRCT: crct <= din;
					R_FAET: faet <= din;
					R_MPT : mpt  <= din;
					R_MDT : mdt  <= din;
					R_DCR2: dcr2 <= din;
					R_SR  : ;                     // Silicon Revision is read-only
					default: ;
				endcase
			end

			//---------------- CPU register read ----------------
			else if (cpu_rd) begin
				ack <= 1'b1;
				case (addr)
					R_CR  : dout <= cr;
					R_DCR : dout <= dcr;
					R_RCR : dout <= rcr;
					R_TCR : dout <= tcr;
					R_IMR : dout <= imr;
					R_ISR : dout <= isr;
					R_UTDA: dout <= utda;
					R_CTDA: dout <= ctda;
					R_URDA: dout <= urda;
					R_CRDA: dout <= crda;
					R_EOBC: dout <= eobc;
					R_URRA: dout <= urra;
					R_RSA : dout <= rsa;
					R_REA : dout <= rea;
					R_RRP : dout <= rrp;
					R_RWP : dout <= rwp;
					R_CEP : dout <= cep;
					R_CAP2: dout <= cap2;
					R_CAP1: dout <= cap1;
					R_CAP0: dout <= cap0;
					R_CE  : dout <= ce;
					R_CDP : dout <= cdp;
					R_CDC : dout <= cdc;
					R_SR  : dout <= SILICON_REV;
					R_WT0 : dout <= wt0;
					R_WT1 : dout <= wt1;
					R_RSC : dout <= rsc;
					R_CRCT: dout <= crct;
					R_FAET: dout <= faet;
					R_MPT : dout <= mpt;
					R_MDT : dout <= mdt;
					R_DCR2: dout <= dcr2;
					default: dout <= 16'h0000;
				endcase
			end

			// Refresh the (level) interrupt output: irq is the OR of any
			// unmasked interrupt-status bit. Registered from the committed ISR,
			// so it tracks ISR one cycle after a set/clear.
			irq <= |(isr & imr);
		end
	end

endmodule
