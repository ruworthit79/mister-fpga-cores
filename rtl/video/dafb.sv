//============================================================================
//  DAFB - Direct Access Frame Buffer (Quadra 900/950 built-in video)
//
//  The real DAFB is a programmable CRTC + frame-buffer controller driving up
//  to 1152x870 with 1/2/4/8/16/24-bit pixels from 1-2 MB of dedicated VRAM,
//  fed through a RAMDAC (Bt473-class) with a 256-entry CLUT.
//
//  STATUS: scaffold. This produces standard 640x480@~60Hz VGA sync timing and
//  a placeholder test pattern so the core shows a stable image. CPU register
//  and VRAM accesses are acknowledged but not yet functional.
//
//  TODO:
//   - Programmable CRTC registers (h/v totals, sync, blank, base, stride).
//   - VRAM (block-RAM or DDR3-backed frame buffer) with the real pixel formats.
//   - 256-entry CLUT + RAMDAC model for indexed modes.
//   - Selectable Apple video timings (640x480, 832x624, 1024x768, 1152x870).
//============================================================================

module dafb
(
	input             clk,
	input             reset,

	// CPU access (registers + VRAM aperture)
	input             sel,
	input      [23:0] addr,
	input      [31:0] din,
	output reg [31:0] dout,
	input      [3:0]  be,
	input             rw,
	output reg        ack,

	// Video output
	output reg        ce_pix,
	output reg        HBlank,
	output reg        HSync,
	output reg        VBlank,
	output reg        VSync,
	output reg [7:0]  r,
	output reg [7:0]  g,
	output reg [7:0]  b
);

	// ---- 640x480@60 VGA timing (placeholder) ----
	localparam H_ACT = 640, H_FP = 16, H_SY = 96, H_BP = 48;
	localparam V_ACT = 480, V_FP = 10, V_SY = 2,  V_BP = 33;
	localparam H_TOT = H_ACT + H_FP + H_SY + H_BP; // 800
	localparam V_TOT = V_ACT + V_FP + V_SY + V_BP; // 525

	// Divide clk_sys down to ~25 MHz pixel enable. The exact divisor depends on
	// the (placeholder) PLL frequency; adjust once the PLL is regenerated.
	reg [1:0] pdiv;
	always @(posedge clk) begin
		pdiv   <= pdiv + 1'd1;
		ce_pix <= (pdiv == 0);
	end

	reg [9:0] hc, vc;
	always @(posedge clk) begin
		if (reset) begin
			hc <= 0; vc <= 0;
		end else if (ce_pix) begin
			if (hc == H_TOT-1) begin
				hc <= 0;
				vc <= (vc == V_TOT-1) ? 10'd0 : vc + 1'd1;
			end else begin
				hc <= hc + 1'd1;
			end
		end
	end

	wire h_active = (hc < H_ACT);
	wire v_active = (vc < V_ACT);

	always @(posedge clk) if (ce_pix) begin
		HBlank <= ~h_active;
		VBlank <= ~v_active;
		HSync  <= (hc >= H_ACT + H_FP) && (hc < H_ACT + H_FP + H_SY);
		VSync  <= (vc >= V_ACT + V_FP) && (vc < V_ACT + V_FP + V_SY);

		// Placeholder pattern: smooth gradient with a grid overlay.
		if (h_active && v_active) begin
			r <= hc[8:1];
			g <= vc[8:1];
			b <= (hc[4] ^ vc[4]) ? 8'h40 : 8'h80;
		end else begin
			r <= 0; g <= 0; b <= 0;
		end
	end

	// Acknowledge CPU cycles (single wait state), return 0 for now.
	always @(posedge clk) begin
		ack  <= 1'b0;
		dout <= 32'h0;
		if (sel && !ack) ack <= 1'b1;
	end

endmodule
