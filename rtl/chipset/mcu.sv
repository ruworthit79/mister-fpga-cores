//============================================================================
//  MCU - Memory Control Unit (Quadra 900/950)
//
//  Real part: controls RAM/ROM timing and 68040 burst transfers, holds the
//  per-bank base-address registers, and performs the reset ROM-overlay trick
//  (ROM mapped at $0000_0000 at reset, moved to $4000_0000 on first ROM
//  access). RAM is 16x 30-pin 80ns SIMMs in 4 banks; 64MB documented max
//  (256MB reachable with third-party 16MB SIMMs).
//
//  On MiSTer, emulated main RAM and the ROM image live in DDR3. This module is
//  the bridge between the CPU bus and the DDR3 controller.
//
//  STATUS: stub. Ports and DDR3 tie-off are in place; the read/write engine
//  and ROM load-to-DDR3 path are TODO. Currently returns 0 and acks cycles so
//  the bus does not hang.
//============================================================================

module mcu
(
	input             clk,
	input             reset,
	input             ram_128mb,

	// CPU side
	input      [31:0] cpu_addr,
	input      [31:0] cpu_din,   // write data (CPU -> RAM)
	output reg [31:0] cpu_dout,  // read data  (RAM -> CPU)
	input      [3:0]  cpu_be,
	input             cpu_rw,     // 1 = read
	input             cpu_req,
	output reg        cpu_ack,

	// ROM image load (ioctl index 0)
	input             ioctl_download,
	input      [7:0]  ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input      [15:0] ioctl_dout,

	// DDR3
	input             DDRAM_BUSY,
	output     [7:0]  DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output            DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output     [7:0]  DDRAM_BE,
	output            DDRAM_WE
);

	// --- DDR3 tie-off (no transactions issued yet) ---
	assign DDRAM_BURSTCNT = 8'd1;
	assign DDRAM_ADDR     = 29'd0;
	assign DDRAM_RD       = 1'b0;
	assign DDRAM_DIN      = 64'd0;
	assign DDRAM_BE       = 8'd0;
	assign DDRAM_WE       = 1'b0;

	// --- Placeholder CPU handshake ---
	always @(posedge clk) begin
		cpu_ack  <= 1'b0;
		cpu_dout <= 32'h0;
		if (cpu_req && !cpu_ack) cpu_ack <= 1'b1;
	end

	// TODO:
	//  [ ] Bank base-address registers + 4-bank decode (64MB/bank).
	//  [ ] DDR3 read/write engine with 32-bit <-> 64-bit packing.
	//  [ ] 68040 burst (line) transfers.
	//  [ ] Load ROM image (ioctl_index==0) into a reserved DDR3 region.
	//  [ ] Reset ROM overlay handshake with the address decoder in quadra950.

endmodule
