//============================================================================
//  adb - Apple Desktop Bus host (Quadra 900/950)
//
//  On this machine ADB is managed by an IOP + an ADB transceiver. This models
//  the ADB at the register/transaction level (what the transceiver presents to
//  the host): PS/2 keyboard and mouse from hps_io appear as ADB devices, and
//  the host issues ADB command bytes to Talk their register 0.
//
//  ADB command byte:  {addr[3:0], cmd[1:0], reg[1:0]}
//    cmd 2'b11 = Talk, 2'b10 = Listen, 2'b00 = reset/flush (reg field).
//  Default addresses: keyboard $2, mouse $3.
//    Talk R0 keyboard = 0x2C, Talk R0 mouse = 0x3C.
//
//  Keyboard register 0 (16 bits): {key0, key1}, each = {up(1)/down(0), key[6:0]}
//  (key1 = 0xFF when only one event). Mouse register 0: {btn(0=down), dy[6:0],
//  1'b1, dx[6:0]}.
//
//  Verified in sim/iverilog/tb_adb.v. The bit-cell ADB line timing (attention/
//  sync/stop) is handled by the IOP/transceiver and is out of scope here; the
//  PS/2 set-2 -> ADB keycode table is partial (documented TODO).
//============================================================================

module adb
(
	input             clk,
	input             reset,

	// PS/2 inputs from hps_io
	input      [10:0] ps2_key,     // {toggle, pressed, extended, code[7:0]}
	input      [24:0] ps2_mouse,   // {toggle, dy[7:0], dx[7:0], ..., btns[2:0]}

	// Host command interface (from the IOP)
	input             cmd_stb,     // pulse: execute adb_cmd
	input      [7:0]  cmd,
	output reg [15:0] data,        // register-0 response
	output reg        valid,       // device responded
	output            srq          // service request (data pending)
);

	// ---- PS/2 set-2 -> ADB keycode (partial table) ----
	function [6:0] adb_code(input [7:0] p);
		case (p)
			8'h1C: adb_code = 7'h00;  // A
			8'h1B: adb_code = 7'h01;  // S
			8'h23: adb_code = 7'h02;  // D
			8'h2B: adb_code = 7'h03;  // F
			8'h5A: adb_code = 7'h24;  // Return
			8'h29: adb_code = 7'h31;  // Space
			8'h66: adb_code = 7'h33;  // Backspace
			8'h76: adb_code = 7'h35;  // Escape
			default: adb_code = 7'h7F;
		endcase
	endfunction

	// ---- keyboard ----
	reg        kbd_toggle_d;
	reg [7:0]  kbd_r0;             // {up/down, keycode}
	reg        kbd_pending;
	wire       k_toggle  = ps2_key[10];
	wire       k_pressed = ps2_key[9];
	wire [7:0] k_code    = ps2_key[7:0];

	// ---- mouse ----
	reg        mse_toggle_d;
	reg [15:0] mse_r0;
	reg        mse_pending;
	wire       m_toggle = ps2_mouse[24];
	wire       m_btn    = ps2_mouse[0];       // left button
	wire [7:0] m_dx     = ps2_mouse[15:8];
	wire [7:0] m_dy     = ps2_mouse[23:16];

	assign srq = kbd_pending | mse_pending;

	always @(posedge clk) begin
		if (reset) begin
			kbd_toggle_d <= 0; kbd_pending <= 0; kbd_r0 <= 8'hFF;
			mse_toggle_d <= 0; mse_pending <= 0; mse_r0 <= 16'hFFFF;
			data <= 0; valid <= 0;
		end else begin
			valid <= 1'b0;

			// latch a new keyboard event
			kbd_toggle_d <= k_toggle;
			if (k_toggle != kbd_toggle_d) begin
				kbd_r0      <= {~k_pressed, adb_code(k_code)};  // down -> bit7=0
				kbd_pending <= 1'b1;
			end

			// latch a new mouse event
			mse_toggle_d <= m_toggle;
			if (m_toggle != mse_toggle_d) begin
				mse_r0      <= {~m_btn, m_dy[6:0], 1'b1, m_dx[6:0]};
				mse_pending <= 1'b1;
			end

			// host command
			if (cmd_stb) begin
				if (cmd == 8'h2C && kbd_pending) begin           // Talk R0 keyboard
					data        <= {kbd_r0, 8'hFF};
					valid       <= 1'b1;
					kbd_pending <= 1'b0;
				end else if (cmd == 8'h3C && mse_pending) begin  // Talk R0 mouse
					data        <= mse_r0;
					valid       <= 1'b1;
					mse_pending <= 1'b0;
				end
			end
		end
	end

endmodule
