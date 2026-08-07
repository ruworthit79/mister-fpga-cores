//============================================================================
//  scsi_ncr53c96 - NCR/AMD 53C96 SCSI controller (Quadra 900/950)
//
//  The 900/950 have TWO 53C96 channels (internal + external, electrically
//  isolated), SCSI-2 class, ~5 MB/s internal. This module models one channel;
//  instantiate twice. Backing storage is a mounted disk image accessed via the
//  hps_io block interface (sd_lba / sd_rd / sd_wr / sd_buff_*).
//
//  STATUS: stub. Command/status/FIFO registers, the target state machine and
//  the DMA path to the disk-image block interface are TODO.
//============================================================================

module scsi_ncr53c96
(
	input             clk,
	input             reset,

	// CPU register access
	input             sel,
	input      [3:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,
	output reg        ack,
	output            irq,

	// hps_io block interface (one image)
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output     [31:0] sd_lba,
	output            sd_rd,
	output            sd_wr,
	input             sd_ack,
	input      [13:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	output     [15:0] sd_buff_din,
	input             sd_buff_wr,

	output            active        // drive activity LED
);

	assign irq         = 1'b0;
	assign sd_lba      = 32'd0;
	assign sd_rd       = 1'b0;
	assign sd_wr       = 1'b0;
	assign sd_buff_din = 16'd0;
	assign active      = 1'b0;

	always @(posedge clk) begin
		dout <= 8'h00;
		ack  <= sel & ~ack;
	end

	// TODO:
	//  [ ] 53C96 register set (TC, FIFO, command, status, config).
	//  [ ] Selection/command/data-in/data-out/status/message phases.
	//  [ ] DMA between the FIFO and the block interface buffer.
	//  [ ] Note: model the 53C96 FIFO-retention quirk the 700/900/950 rely on.

endmodule
