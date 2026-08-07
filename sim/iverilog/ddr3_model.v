//============================================================================
//  ddr3_model - behavioral DDR3 for MCU unit tests (not synthesizable)
//
//  Models the MiSTer DDRAM interface: 64-bit words, byte-enable writes,
//  single-beat, ~1 cycle read latency, never busy. Covers 2^AW 64-bit words.
//============================================================================
`timescale 1ns/1ps

module ddr3_model #(parameter AW = 15)
(
	input             clk,
	input      [7:0]  DDRAM_BURSTCNT,
	input      [28:0] DDRAM_ADDR,
	output reg [63:0] DDRAM_DOUT,
	output reg        DDRAM_DOUT_READY,
	input             DDRAM_RD,
	input      [63:0] DDRAM_DIN,
	input      [7:0]  DDRAM_BE,
	input             DDRAM_WE,
	output            DDRAM_BUSY
);
	reg [63:0] mem [0:(1<<AW)-1];

	assign DDRAM_BUSY = 1'b0;

	wire [AW-1:0] wi = DDRAM_ADDR[AW+2:3];

	integer i;
	reg           rd_d;
	reg [AW-1:0]  wi_d;

	always @(posedge clk) begin
		DDRAM_DOUT_READY <= 1'b0;

		if (DDRAM_WE) begin
			for (i = 0; i < 8; i = i + 1)
				if (DDRAM_BE[i]) mem[wi][8*i +: 8] <= DDRAM_DIN[8*i +: 8];
		end

		rd_d <= DDRAM_RD;
		wi_d <= wi;
		if (rd_d) begin
			DDRAM_DOUT       <= mem[wi_d];
			DDRAM_DOUT_READY <= 1'b1;
		end
	end
endmodule
