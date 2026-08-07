//============================================================================
//  MCU - Memory Control Unit (Quadra 900/950)
//
//  Bridges the CPU's 32-bit TS/TA bus to the DE10-Nano's 64-bit DDR3, which
//  holds both emulated main RAM and the loaded ROM image. Single-beat
//  (BURSTCNT=1) transactions; byte-enable writes avoid read-modify-write.
//
//  Address mapping (byte addresses):
//    RAM ($0xxxxxxx) -> DDR3 [cpu_addr]                (banked, up to 128MB)
//    ROM ($40xxxxxx) -> DDR3 [ROM_BASE + cpu_addr[19:0]]  (1MB image)
//  The ROM image is streamed in via ioctl (index 0) during download and
//  written to the ROM region of DDR3.
//
//  Endianness: the 64-bit DDR word is big-endian (byte 0 in bits [63:56]),
//  matching the 68k. A 32-bit CPU access selects the high or low half by
//  cpu_addr[2]; byte enables map straight through.
//
//  Verified in sim/iverilog/tb_mcu.v (ROM load + read-back, RAM write/read,
//  byte-enable writes).
//============================================================================

module mcu
#(
	parameter [28:0] ROM_BASE = 29'h1000_0000     // 256MB offset in DDR3
)
(
	input             clk,
	input             reset,
	input             ram_128mb,

	// CPU side (TS/TA: cpu_req pulses a transfer, cpu_ack completes it)
	input      [31:0] cpu_addr,
	input      [31:0] cpu_din,    // write data (CPU -> RAM)
	output reg [31:0] cpu_dout,   // read data  (RAM -> CPU)
	input      [3:0]  cpu_be,
	input             cpu_rw,      // 1 = read, 0 = write
	input             cpu_req,
	input             rom_sel,     // this access targets ROM (incl. reset overlay)
	output reg        cpu_ack,

	// ROM image load (ioctl index 0), 16-bit stream
	input             ioctl_download,
	input      [7:0]  ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input      [15:0] ioctl_dout,

	// DDR3
	input             DDRAM_BUSY,
	output reg [7:0]  DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output reg [63:0] DDRAM_DIN,
	output reg [7:0]  DDRAM_BE,
	output reg        DDRAM_WE
);

	// Address of the containing 64-bit (8-byte) DDR word.
	wire        is_rom  = rom_sel;                 // ROM access (decoded upstream)
	wire [28:0] ram_a   = {cpu_addr[28:3], 3'b000};
	wire [28:0] rom_a   = ROM_BASE + {8'd0, cpu_addr[20:3], 3'b000};
	wire [28:0] cpu_ddr = is_rom ? rom_a : ram_a;
	wire        hi      = ~cpu_addr[2];            // A2=0 -> high 32 bits

	// ioctl ROM word placement within the 64-bit DDR word.
	wire [28:0] io_ddr  = ROM_BASE + {8'd0, ioctl_addr[20:3], 3'b000};
	wire [1:0]  io_w    = ioctl_addr[2:1];         // which 16-bit lane (0..3)

	localparam S_IDLE = 3'd0, S_RD = 3'd1, S_WR = 3'd2, S_ACK = 3'd3, S_LOAD = 3'd4;
	reg [2:0] state;

	always @(posedge clk) begin
		if (reset) begin
			state          <= S_IDLE;
			cpu_ack        <= 1'b0;
			DDRAM_RD       <= 1'b0;
			DDRAM_WE       <= 1'b0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_BE       <= 8'd0;
		end else begin
			case (state)
				S_IDLE: begin
					cpu_ack <= 1'b0;
					if (ioctl_download && ioctl_wr && ioctl_index == 8'd0 && !DDRAM_BUSY) begin
						// Write one 16-bit ROM word (big-endian lane) via byte enables.
						DDRAM_ADDR     <= io_ddr;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN      <= {4{ioctl_dout}};   // same value on all lanes
						DDRAM_BE       <= (8'b1100_0000 >> (io_w * 2));
						DDRAM_WE       <= 1'b1;
						state          <= S_LOAD;
					end else if (cpu_req && !cpu_ack && !DDRAM_BUSY) begin
						DDRAM_ADDR     <= cpu_ddr;
						DDRAM_BURSTCNT <= 8'd1;
						if (cpu_rw) begin
							DDRAM_RD <= 1'b1;
							state    <= S_RD;
						end else begin
							// Place 32-bit write data + byte enables in the addressed half.
							DDRAM_DIN <= {cpu_din, cpu_din};
							DDRAM_BE  <= hi ? {cpu_be, 4'b0000} : {4'b0000, cpu_be};
							DDRAM_WE  <= 1'b1;
							state     <= S_WR;
						end
					end
				end

				S_RD: begin
					if (!DDRAM_BUSY) DDRAM_RD <= 1'b0;   // request accepted
					if (DDRAM_DOUT_READY) begin
						cpu_dout <= hi ? DDRAM_DOUT[63:32] : DDRAM_DOUT[31:0];
						cpu_ack  <= 1'b1;
						state    <= S_ACK;
					end
				end

				S_WR: begin
					if (!DDRAM_BUSY) begin               // write accepted
						DDRAM_WE <= 1'b0;
						cpu_ack  <= 1'b1;
						state    <= S_ACK;
					end
				end

				S_LOAD: begin
					if (!DDRAM_BUSY) begin
						DDRAM_WE <= 1'b0;
						state    <= S_IDLE;
					end
				end

				S_ACK: begin
					// Hold ack until the CPU finishes the cycle (req drops).
					if (!cpu_req) begin
						cpu_ack <= 1'b0;
						state   <= S_IDLE;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
