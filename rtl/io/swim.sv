//============================================================================
//  swim - Super Woz Integrated Machine floppy controller (Quadra 900/950)
//
//  Drives the Apple SuperDrive (1.44 MB HD, GCR for Mac disks, MFM for PC).
//  On the Quadra it is driven through the SWIM IOP. SWIM has two modes: an
//  IWM-compatible mode and its own ISM (Integrated Sander Machine) mode.
//
//  STATUS: stub. Register file, the GCR/MFM encode/decode and the disk-image
//  data source are TODO. Floppy is low priority vs. SCSI booting.
//============================================================================

module swim
(
	input             clk,
	input             reset,
	input             sel,
	input      [3:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,
	output reg        ack,
	output            irq
);

	assign irq = 1'b0;

	always @(posedge clk) begin
		dout <= 8'h00;
		ack  <= sel & ~ack;
	end

endmodule
