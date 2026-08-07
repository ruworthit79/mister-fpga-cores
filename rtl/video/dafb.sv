//============================================================================
//  DAFB - Direct Access Frame Buffer (Quadra 900/950 built-in video)
//
//  A working framebuffer: dual-port VRAM (four 8-bit lanes for a 32-bit CPU
//  port + per-pixel byte read on scanout), a 256-entry CLUT/RAMDAC, and 8-bit
//  indexed-colour readout with programmable frame base and line stride. The
//  CPU can access VRAM, the CLUT and the control registers; scanout runs off a
//  ~25 MHz pixel enable with a 2-stage (VRAM -> CLUT) pipeline, and blank/sync
//  are delayed to stay aligned with the pixel data.
//
//  Implemented: 8 bpp indexed (the classic Mac desktop depth). The real DAFB
//  also does 1/2/4/16/24 bpp and a fully programmable CRTC; timing here is
//  fixed 640x480@~60 and only 8 bpp is read out (documented TODO).
//
//  Local register/aperture map (within this slot's 24-bit space):
//    0x00_0000 : registers  (0x00 ctrl, 0x04 base, 0x08 stride)
//    0x10_0000 : CLUT       (entry n at +n*4, value 0x00RRGGBB)
//    0x80_0000 : VRAM aperture (byte offset = addr[22:0])
//
//  Verified in sim/iverilog/tb_dafb.v.
//============================================================================

module dafb #(
	parameter VRAM_WORDS = 4096,          // 32-bit words (test size)
	// When TESTTIMING=1 the parameter timing below is used (fast sim frame);
	// otherwise the CRTC timing comes from `vmode` (real Apple resolutions).
	parameter TESTTIMING = 0,
	parameter H_ACT = 640, H_FP = 16, H_SY = 96, H_BP = 48,
	parameter V_ACT = 480, V_FP = 10, V_SY = 2,  V_BP = 33
)
(
	input             clk,
	input             reset,

	input      [1:0]  vmode,        // 0=640x480 1=832x624 2=1024x768 3=1152x870

	// CPU access
	input             sel,
	input      [23:0] addr,
	input      [31:0] din,
	output reg [31:0] dout,
	input      [3:0]  be,
	input             rw,          // 1 = read
	output reg        ack,

	// Video output
	output reg        ce_pix,
	output reg        HBlank,
	output reg        HSync,
	output reg        VBlank,
	output reg        VSync,
	output reg [7:0]  r,
	output reg [7:0]  g,
	output reg [7:0]  b,

	output            vbl_irq      // vertical-blank interrupt (level)
);

	localparam AW = $clog2(VRAM_WORDS);

	// ---- control registers ----
	reg [23:0] reg_base;           // VRAM byte address of the visible frame
	reg [15:0] reg_stride;         // bytes per line
	reg [7:0]  reg_ctrl;           // [0]=video enable

	// ---- decode ----
	wire is_reg  = (addr[23:20] == 4'h0);
	wire is_clut = (addr[23:20] == 4'h1);
	wire is_vram = addr[23];
	wire [AW-1:0] cpu_word = addr[AW+1:2];
	wire [7:0]    clut_idx = addr[9:2];

	// ---- VRAM: four byte-lane block RAMs (dual port) ----
	reg [7:0] vram0 [0:VRAM_WORDS-1];
	reg [7:0] vram1 [0:VRAM_WORDS-1];
	reg [7:0] vram2 [0:VRAM_WORDS-1];
	reg [7:0] vram3 [0:VRAM_WORDS-1];   // lane0 = byte0 = bits[31:24] (big-endian)

	// ---- CLUT ----
	reg [23:0] clut [0:255];

	// ================= CPU port =================
	wire cpu_wr = sel & ~rw;
	always @(posedge clk) begin
		if (reset) begin
			ack        <= 1'b0;
			reg_base   <= 24'd0;
			reg_stride <= 16'd640;
			reg_ctrl   <= 8'h01;
		end else begin
			ack <= 1'b0;

			// writes
			if (cpu_wr) begin
				if (is_reg) begin
					case (addr[7:2])
						6'h00: reg_ctrl   <= din[7:0];
						6'h01: reg_base   <= din[23:0];
						6'h02: reg_stride <= din[15:0];
						default: ;
					endcase
				end else if (is_clut) begin
					clut[clut_idx] <= din[23:0];
				end else if (is_vram) begin
					if (be[3]) vram0[cpu_word] <= din[31:24];
					if (be[2]) vram1[cpu_word] <= din[23:16];
					if (be[1]) vram2[cpu_word] <= din[15:8];
					if (be[0]) vram3[cpu_word] <= din[7:0];
				end
			end

			// reads (registered, 1 cycle)
			if (is_reg)
				dout <= (addr[7:2] == 6'h01) ? {8'd0, reg_base} :
				        (addr[7:2] == 6'h02) ? {16'd0, reg_stride} :
				                               {24'd0, reg_ctrl};
			else if (is_clut)
				dout <= {8'd0, clut[clut_idx]};
			else
				dout <= {vram0[cpu_word], vram1[cpu_word], vram2[cpu_word], vram3[cpu_word]};

			if (sel && !ack) ack <= 1'b1;
		end
	end

	// ================= Pixel clock enable (~clk/2) =================
	reg pdiv;
	always @(posedge clk) begin
		if (reset) begin pdiv <= 1'b0; ce_pix <= 1'b0; end
		else       begin pdiv <= ~pdiv; ce_pix <= pdiv; end   // high every 2 clks
	end

	// ================= CRTC =================
	// Runtime timing (approximate standard Apple modes) selected by vmode, via
	// continuous assigns (evaluate at t=0, unambiguous sensitivity). TESTTIMING
	// pins the timing to the parameter values for a fast simulation frame.
	wire [11:0] h_act_m = (vmode==2'd0)?12'd640 :(vmode==2'd1)?12'd832 :(vmode==2'd2)?12'd1024:12'd1152;
	wire [11:0] h_fp_m  = (vmode==2'd0)?12'd16  :(vmode==2'd1)?12'd32  :(vmode==2'd2)?12'd24  :12'd32;
	wire [11:0] h_sy_m  = (vmode==2'd0)?12'd96  :(vmode==2'd1)?12'd64  :(vmode==2'd2)?12'd136 :12'd128;
	wire [11:0] h_bp_m  = (vmode==2'd0)?12'd48  :(vmode==2'd1)?12'd224 :(vmode==2'd2)?12'd160 :12'd144;
	wire [11:0] v_act_m = (vmode==2'd0)?12'd480 :(vmode==2'd1)?12'd624 :(vmode==2'd2)?12'd768 :12'd870;
	wire [11:0] v_fp_m  = (vmode==2'd0)?12'd10  :(vmode==2'd1)?12'd1   :(vmode==2'd2)?12'd3   :12'd3;
	wire [11:0] v_sy_m  = (vmode==2'd0)?12'd2   :(vmode==2'd1)?12'd3   :(vmode==2'd2)?12'd6   :12'd3;
	wire [11:0] v_bp_m  = (vmode==2'd0)?12'd33  :(vmode==2'd1)?12'd39  :(vmode==2'd2)?12'd29  :12'd39;

	wire [11:0] h_act_v = TESTTIMING ? H_ACT[11:0] : h_act_m;
	wire [11:0] h_fp_v  = TESTTIMING ? H_FP[11:0]  : h_fp_m;
	wire [11:0] h_sy_v  = TESTTIMING ? H_SY[11:0]  : h_sy_m;
	wire [11:0] h_bp_v  = TESTTIMING ? H_BP[11:0]  : h_bp_m;
	wire [11:0] v_act_v = TESTTIMING ? V_ACT[11:0] : v_act_m;
	wire [11:0] v_fp_v  = TESTTIMING ? V_FP[11:0]  : v_fp_m;
	wire [11:0] v_sy_v  = TESTTIMING ? V_SY[11:0]  : v_sy_m;
	wire [11:0] v_bp_v  = TESTTIMING ? V_BP[11:0]  : v_bp_m;

	wire [11:0] H_ACTs = h_act_v;
	wire [11:0] V_ACTs = v_act_v;
	wire [11:0] H_TOT  = h_act_v + h_fp_v + h_sy_v + h_bp_v;
	wire [11:0] V_TOT  = v_act_v + v_fp_v + v_sy_v + v_bp_v;
	wire [11:0] H_SE   = h_act_v + h_fp_v;              // hsync start
	wire [11:0] H_SEND = h_act_v + h_fp_v + h_sy_v;     // hsync end
	wire [11:0] V_SE   = v_act_v + v_fp_v;
	wire [11:0] V_SEND = v_act_v + v_fp_v + v_sy_v;

	reg [11:0] hc, vc;
	always @(posedge clk) begin
		if (reset) begin hc <= 0; vc <= 0; end
		else if (ce_pix) begin
			if (hc == H_TOT-1) begin
				hc <= 0;
				vc <= (vc == V_TOT-1) ? 12'd0 : vc + 1'd1;
			end else hc <= hc + 1'd1;
		end
	end

	wire h_act = (hc < H_ACTs);
	wire v_act = (vc < V_ACTs);
	wire hbl   = ~h_act;
	wire vbl   = ~v_act;
	wire hsy   = (hc >= H_SE) && (hc < H_SEND);
	wire vsy   = (vc >= V_SE) && (vc < V_SEND);

	// Line base address accumulator (avoids a per-pixel multiply).
	reg [23:0] line_base;
	always @(posedge clk) begin
		if (reset) line_base <= 24'd0;
		else if (ce_pix) begin
			if (vc == V_TOT-1 && hc == H_TOT-1) line_base <= reg_base;  // frame start
			else if (hc == H_TOT-1 && v_act)    line_base <= line_base + reg_stride;
		end
	end

	wire [23:0] pix_byte = line_base + {12'd0, hc};   // 8 bpp: 1 byte/pixel
	wire [AW-1:0] pix_word = pix_byte[AW+1:2];
	wire [1:0]    pix_lane = pix_byte[1:0];

	// ---- Stage 1: VRAM read (registered) + pipeline blanks/sync ----
	reg [7:0] s1_b0, s1_b1, s1_b2, s1_b3;
	reg       s1_hbl, s1_vbl, s1_hsy, s1_vsy, s1_act;
	reg [1:0] s1_lane;
	reg [11:0] s1_x, s1_y, s2_x, s2_y;   // pixel coords pipelined with the data
	always @(posedge clk) if (ce_pix) begin
		s1_b0 <= vram0[pix_word]; s1_b1 <= vram1[pix_word];
		s1_b2 <= vram2[pix_word]; s1_b3 <= vram3[pix_word];
		s1_lane <= pix_lane;
		s1_hbl <= hbl; s1_vbl <= vbl; s1_hsy <= hsy; s1_vsy <= vsy;
		s1_act <= h_act & v_act & reg_ctrl[0];
		s1_x <= hc; s1_y <= vc;
	end

	wire [7:0] s1_index = (s1_lane == 2'd0) ? s1_b0 :
	                      (s1_lane == 2'd1) ? s1_b1 :
	                      (s1_lane == 2'd2) ? s1_b2 : s1_b3;

	// ---- Stage 2: CLUT read (registered) + final blanks/sync ----
	reg [23:0] s2_rgb;
	reg        s2_act;
	always @(posedge clk) if (ce_pix) begin
		s2_rgb <= clut[s1_index];
		s2_act <= s1_act;
		HBlank <= s1_hbl; VBlank <= s1_vbl; HSync <= s1_hsy; VSync <= s1_vsy;
		s2_x <= s1_x; s2_y <= s1_y;
		if (s1_act) {r, g, b} <= clut[s1_index];
		else        {r, g, b} <= 24'd0;
	end

	// ---- vertical-blank interrupt: pulse-ish level at start of VBlank ----
	reg vbl_d;
	reg vbl_flag;
	always @(posedge clk) begin
		if (reset) begin vbl_d <= 0; vbl_flag <= 0; end
		else if (ce_pix) begin
			vbl_d <= vbl;
			if (vbl & ~vbl_d) vbl_flag <= 1'b1;   // rising edge of VBlank
			// (a real design would clear on VIA read; kept simple here)
		end
	end
	assign vbl_irq = vbl_flag;

endmodule
