//============================================================================
//  caboose - RTC / PRAM microcontroller (Quadra 900/950)
//
//  Real part: an Egret-family (68HC05) custom IC that manages the real-time
//  clock, parameter RAM (PRAM), power and the keyswitch, talking to the CPU
//  through VIA1 via a bit-banged serial link. (It is NOT the ADB manager on
//  this machine - that is an IOP.)
//
//  This models the Apple RTC serial protocol (see "Guide to the Macintosh
//  Family Hardware"): the host asserts enable (active low) then clocks a
//  command byte MSB-first; bit 7 selects read(1)/write(0). Implemented:
//    - 32-bit seconds counter (Mac epoch 1 Jan 1904), incremented by tick_1hz
//      read  cmd 0x81/0x85/0x89/0x8D, write cmd 0x01/0x05/0x09/0x0D (byte 0..3)
//    - 256 bytes extended PRAM via the two-byte (command, address) sequence
//      write cmd 0x38, read cmd 0xB8, followed by an address byte then data.
//
//  Bits shift on the serial-clock rising edge; on a read the addressed byte is
//  presented MSB-first, one bit per rising edge. Verified in tb_caboose.v.
//
//  Simplified: no write-protect/test regs, no legacy 20-byte PRAM commands, no
//  power/keyswitch. Command encodings follow the Guide and may need refinement
//  against a real ROM.
//============================================================================

module caboose
(
	input             clk,
	input             reset,

	input             tick_1hz,     // 1 Hz enable (increment seconds)

	// Serial link (driven by VIA1 port bits)
	input             rtc_enb,      // chip enable, active LOW
	input             rtc_clk,      // serial clock
	input             rtc_data_in,  // host -> RTC
	output reg        rtc_data_out, // RTC -> host
	output reg        rtc_data_oe,  // 1 when RTC drives data_out (reads)

	// PRAM backup port (for hps_io persistence): the ARM streams the 256 PRAM
	// bytes in on restore (bk_wr) and reads them out for saving (bk_dout).
	input      [7:0]  bk_addr,
	input             bk_wr,
	input      [7:0]  bk_din,
	output     [7:0]  bk_dout
);

	reg [31:0] seconds;              // Mac epoch seconds
	reg [7:0]  pram [0:255];

	assign bk_dout = pram[bk_addr];  // backup read port

	localparam P_CMD = 2'd0, P_ADDR = 2'd1, P_WDATA = 2'd2, P_RDATA = 2'd3;
	reg [1:0] phase;
	reg [7:0] shft;                  // input shift register
	reg [7:0] outr;                  // output shift register
	reg [2:0] bcnt;                  // bit counter 0..7
	reg [7:0] cmd, paddr;
	reg       is_read, is_pram;

	reg  clk_d, enb_d;
	wire clk_rise = rtc_clk & ~clk_d;
	wire enb_rise = rtc_enb & ~enb_d;

	wire [7:0] byte_in = {shft[6:0], rtc_data_in};   // completed input byte

	function [7:0] sec_byte(input [1:0] idx);
		case (idx)
			2'd0: sec_byte = seconds[7:0];
			2'd1: sec_byte = seconds[15:8];
			2'd2: sec_byte = seconds[23:16];
			default: sec_byte = seconds[31:24];
		endcase
	endfunction

	always @(posedge clk) begin
		if (reset) begin
			phase <= P_CMD; bcnt <= 0; clk_d <= 0; enb_d <= 0;
			rtc_data_out <= 0; rtc_data_oe <= 0; is_read <= 0; is_pram <= 0;
			seconds <= 32'd0;
		end else begin
			clk_d <= rtc_clk;
			enb_d <= rtc_enb;

			// PRAM backup restore (ARM -> PRAM)
			if (bk_wr) pram[bk_addr] <= bk_din;

			// real-time tick (a write below may override the same cycle)
			if (tick_1hz) seconds <= seconds + 32'd1;

			if (enb_rise) begin
				phase <= P_CMD; bcnt <= 0; rtc_data_oe <= 0;   // transaction reset
			end else if (!rtc_enb && clk_rise) begin
				case (phase)
					P_CMD: begin
						shft <= byte_in;
						if (bcnt == 3'd7) begin
							bcnt    <= 0;
							cmd     <= byte_in;
							is_read <= byte_in[7];
							if (byte_in[6:0] == 7'h38) begin     // extended PRAM
								is_pram <= 1'b1;
								phase   <= P_ADDR;
							end else begin                        // seconds byte
								is_pram <= 1'b0;
								if (byte_in[7]) begin
									outr <= sec_byte(byte_in[3:2]);
									rtc_data_oe <= 1'b1;
									phase <= P_RDATA;
								end else phase <= P_WDATA;
							end
						end else bcnt <= bcnt + 1'b1;
					end

					P_ADDR: begin
						shft <= byte_in;
						if (bcnt == 3'd7) begin
							bcnt  <= 0;
							paddr <= byte_in;
							if (is_read) begin
								outr <= pram[byte_in];
								rtc_data_oe <= 1'b1;
								phase <= P_RDATA;
							end else phase <= P_WDATA;
						end else bcnt <= bcnt + 1'b1;
					end

					P_WDATA: begin
						shft <= byte_in;
						if (bcnt == 3'd7) begin
							bcnt <= 0;
							if (is_pram) pram[paddr] <= byte_in;
							else case (cmd[3:2])
								2'd0: seconds[7:0]   <= byte_in;
								2'd1: seconds[15:8]  <= byte_in;
								2'd2: seconds[23:16] <= byte_in;
								2'd3: seconds[31:24] <= byte_in;
							endcase
							phase <= P_CMD;
						end else bcnt <= bcnt + 1'b1;
					end

					P_RDATA: begin
						rtc_data_out <= outr[7];
						outr <= {outr[6:0], 1'b0};
						if (bcnt == 3'd7) begin bcnt <= 0; phase <= P_CMD; rtc_data_oe <= 0; end
						else bcnt <= bcnt + 1'b1;
					end
				endcase
			end
		end
	end

endmodule
