//============================================================================
//  swim - Super Woz Integrated Machine floppy controller (Quadra 900/950)
//
//  Drives the Apple SuperDrive (1.44 MB HD, GCR for Mac disks, MFM for PC).
//  On the Quadra it is normally reached through the SWIM IOP (an on-board 6502)
//  via a shared-RAM mailbox. Full 6502/IOP emulation is out of scope: this
//  model exposes the SWIM registers directly to the CPU register interface
//  ("bypass-IOP" mode; see iop.sv), which is sufficient for the OS floppy probe.
//
//  SWIM has two register-level personalities selected by an internal mode bit:
//    * IWM mode (power-up default): the classic Apple IWM. 16 soft-switch
//      addresses (addr[3:0]) toggle 8 state latches (CA0/CA1/CA2/LSTRB,
//      ENABLE/motor, SELECT, Q6, Q7). Q6/Q7 pick which register the data bus
//      returns; the Status register's SENSE bit (bit 7) reads a drive status
//      line addressed by {CA2,CA1,CA0,SELECT}.
//    * ISM mode (Integrated Sander Machine): SWIM's own register file, entered
//      from IWM by the documented Q6/Q7 mode-register write with the ISM/SWIM
//      enable bit (0x40) set. Registers are byte-wide at reg index addr[3:1]:
//        write: 0 Data,1 Mark,2 CRC,3 Parameter,4 Phase,5 Setup,6 Mode0,7 Mode1
//        read : 0 Data,1 Mark,2 Error,3 Parameter,4 Phase,5 Setup,6 Status,7 Handshake
//      Mode0 clears / Mode1 sets bits of the Mode register (Status reads it back).
//      Clearing the ISM bit (0x40) via Mode0 returns the chip to IWM mode.
//
//  FIDELITY: this is an *empty-drive* functional model, not a disk engine.
//  It reports "drive present, no disk inserted, not ready, no error" so the OS
//  floppy probe completes without hanging. The GCR/MFM codec, real Sony drive
//  timing (step/tach/index), the FIFO datapath and interrupts are NOT modelled
//  (FIFO always reads empty, irq tied low). The Sony sense-line polarities below
//  are functional approximations chosen for a self-consistent empty drive.
//
//  Verified in sim/iverilog/tb_swim.v (reset, IWM no-disk sense reads,
//  IWM->ISM mode switch, ISM Status/Handshake reads).
//============================================================================

module swim
(
	input             clk,
	input             reset,

	// CPU register interface (same convention as scsi_ncr53c96)
	input             sel,
	input      [3:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,          // 1 = read
	output reg        ack,
	output            irq
);

	// No interrupts in the empty-drive model.
	assign irq = 1'b0;

	// -----------------------------------------------------------------------
	// Drive status ("SENSE") lines addressed by {CA2,CA1,CA0,SELECT}.
	// Value = the raw level the drive drives onto the RD/SENSE line. Chosen to
	// describe a SuperDrive that is installed but empty and not ready.
	// -----------------------------------------------------------------------
	function drive_sense(input [3:0] s);
		case (s)
			4'h0: drive_sense = 1'b1; // !DIRTN   - step direction idle
			4'h1: drive_sense = 1'b1; // !CSTIN   - 1 = NO disk in place
			4'h2: drive_sense = 1'b1; // !STEP    - step complete/idle
			4'h3: drive_sense = 1'b1; // !WRPROT  - 1 = not write protected
			4'h4: drive_sense = 1'b1; // !MOTORON - 1 = motor off
			4'h5: drive_sense = 1'b1; // !TK0     - 1 = not at track 0
			4'h6: drive_sense = 1'b0; // SWITCHED / eject sense
			4'h7: drive_sense = 1'b0; // !TACH    - tachometer (no rotation)
			4'h8: drive_sense = 1'b0; // RDDATA0
			4'h9: drive_sense = 1'b0; // RDDATA1
			4'hA: drive_sense = 1'b1; // SUPERDRIVE present (HD capable)
			4'hB: drive_sense = 1'b1; // !READY   - 1 = drive NOT ready
			4'hC: drive_sense = 1'b0; // reserved
			4'hD: drive_sense = 1'b1; // TWOSIDED - double sided mechanism
			4'hE: drive_sense = 1'b0; // !DRVIN   - 0 = drive IS installed
			4'hF: drive_sense = 1'b1; // no second drive present
			default: drive_sense = 1'b1;
		endcase
	endfunction

	// -----------------------------------------------------------------------
	// IWM state
	// -----------------------------------------------------------------------
	reg        ism_mode;            // 0 = IWM, 1 = ISM
	reg        ca0, ca1, ca2;       // phase / status-address lines
	reg        lstrb;               // LSTRB (CA3)
	reg        motor;               // ENABLE (motor on)
	reg        drvsel;              // SELECT (head/drive select in IWM)
	reg        q6, q7;              // register-select lines
	reg [4:0]  iwm_mode;            // IWM mode register (low 5 bits)

	// -----------------------------------------------------------------------
	// ISM registers
	// -----------------------------------------------------------------------
	reg [7:0]  mode;                // ISM Mode register (Status reads it back)
	reg [7:0]  mark_r, param_r, phase_r, setup_r;

	// ISM Mode register bit map:
	//   [7] MOTORON  [6] ISM/SWIM enable  [5] ACTION  [4] RDDATA/write
	//   [3] CLRFIFO  [2] DRIVE2 sel        [1] DRIVE1 sel [0] HDSEL
	wire [3:0] ism_sel = {phase_r[2:0], mode[0]};   // status address in ISM
	wire       ism_sns = drive_sense(ism_sel);

	// ISM Handshake register: FIFO always empty, no error, sense reflects drive.
	//   [7] MARK  [6] RDDATA/sense  [5] SENSE(no-disk)  [4] MOTORON
	//   [3] ERROR [2] DAT2BYTE      [1] DAT1BYTE        [0] -
	wire [7:0] ism_handshake = {1'b0, ism_sns, 1'b1, mode[7], 4'b0000};

	// IWM Status register:
	//   [7] SENSE  [6] 0  [5] MOTOR  [4:0] IWM mode register
	wire [3:0] iwm_sel = {ca2, ca1, ca0, drvsel};
	wire [7:0] iwm_status = {drive_sense(iwm_sel), 1'b0, motor, iwm_mode};

	// Register-select lines *after* this access's soft-switch toggle.
	wire q6n = (addr == 4'hC) ? 1'b0 : (addr == 4'hD) ? 1'b1 : q6;
	wire q7n = (addr == 4'hE) ? 1'b0 : (addr == 4'hF) ? 1'b1 : q7;

	wire cpu_rd = sel &  rw & ~ack;
	wire cpu_wr = sel & ~rw & ~ack;
	wire [2:0] rism = addr[3:1];    // ISM register index (0..7)

	always @(posedge clk) begin
		if (reset) begin
			ack      <= 1'b0;
			dout     <= 8'h00;
			ism_mode <= 1'b0;                 // power up in IWM mode
			ca0 <= 0; ca1 <= 0; ca2 <= 0; lstrb <= 0;
			motor <= 0; drvsel <= 0; q6 <= 0; q7 <= 0;
			iwm_mode <= 5'h00;
			mode <= 8'h00;
			mark_r <= 0; param_r <= 0; phase_r <= 0; setup_r <= 0;
		end else begin
			ack <= 1'b0;

			// =============================================================
			//  IWM mode
			// =============================================================
			if (!ism_mode) begin
				if (cpu_rd | cpu_wr) begin
					ack <= 1'b1;

					// every access toggles exactly one soft switch
					case (addr)
						4'h0: ca0    <= 1'b0;  4'h1: ca0    <= 1'b1;
						4'h2: ca1    <= 1'b0;  4'h3: ca1    <= 1'b1;
						4'h4: ca2    <= 1'b0;  4'h5: ca2    <= 1'b1;
						4'h6: lstrb  <= 1'b0;  4'h7: lstrb  <= 1'b1;
						4'h8: motor  <= 1'b0;  4'h9: motor  <= 1'b1;
						4'hA: drvsel <= 1'b0;  4'hB: drvsel <= 1'b1;
						4'hC: q6     <= 1'b0;  4'hD: q6     <= 1'b1;
						4'hE: q7     <= 1'b0;  4'hF: q7     <= 1'b1;
						default: ;
					endcase
				end

				if (cpu_rd) begin
					// data bus contents selected by Q7,Q6
					casez ({q7n, q6n})
						2'b01:   dout <= iwm_status;   // Q6=1,Q7=0: Status (SENSE)
						2'b10:   dout <= {2'b10, iwm_mode, 1'b0}; // Q7=1,Q6=0: write-handshake/mode
						default: dout <= 8'h00;        // data register: no disk data
					endcase
				end else if (cpu_wr) begin
					// Q7=1,Q6=0 write -> IWM mode register.
					if (q7n & ~q6n) iwm_mode <= din[4:0];
					// Q7=1,Q6=1 write -> mode-register write path. With the ISM
					// enable bit set this switches SWIM into ISM mode.
					if (q7n & q6n & din[6]) begin
						ism_mode <= 1'b1;
						mode     <= din;
					end
				end

			// =============================================================
			//  ISM mode
			// =============================================================
			end else begin
				if (cpu_wr) begin
					ack <= 1'b1;
					case (rism)
						3'd0: ;                       // Data: no drive, discard
						3'd1: mark_r  <= din;         // Mark
						3'd2: ;                       // CRC: discard
						3'd3: param_r <= din;         // Parameter
						3'd4: phase_r <= din;         // Phase
						3'd5: setup_r <= din;         // Setup
						3'd6: begin                   // Mode0: clear set bits
							mode <= mode & ~din;
							if (din[6]) ism_mode <= 1'b0;   // clearing ISM -> IWM
						end
						3'd7: mode <= mode | din;     // Mode1: set bits
						default: ;
					endcase
				end else if (cpu_rd) begin
					ack <= 1'b1;
					case (rism)
						3'd0: dout <= 8'h00;          // Data: FIFO empty
						3'd1: dout <= mark_r;         // Mark
						3'd2: dout <= 8'h00;          // Error: none
						3'd3: dout <= param_r;        // Parameter
						3'd4: dout <= phase_r;        // Phase
						3'd5: dout <= setup_r;        // Setup
						3'd6: dout <= mode;           // Status = Mode register
						3'd7: dout <= ism_handshake;  // Handshake: FIFO empty
						default: dout <= 8'h00;
					endcase
				end
			end
		end
	end

endmodule
