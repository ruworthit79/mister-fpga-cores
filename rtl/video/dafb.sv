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
//  Implemented depths: 8 bpp indexed (through the CLUT), 16 bpp direct
//  (xRGB1555, "thousands") and 32 bpp direct (xRGB8888, "millions"), selected by
//  the depth register. CRTC timing is either one of the vmode presets (Apple
//  640x480/832x624/1024x768/1152x870) or a fully programmable set of CRTC
//  registers (reg_ctrl[1]). The pixel-clock enable is programmable; the true
//  output clock for high-res modes still needs a reconfigurable video PLL.
//
//  Local register/aperture map (within this slot's 24-bit space):
//    0x00_0000 : registers
//        0x00 ctrl  [0]=video enable [1]=use programmed CRTC
//        0x04 base  (VRAM byte address of the visible frame)
//        0x08 stride (bytes per line)
//        0x0C depth  (0=8bpp 1=16bpp 2=32bpp)
//        0x1C pixdiv (pixel-clock divider; 0 => clk/2)
//        0x20..0x3C programmable CRTC: htot,hss,hse,hact,vtot,vss,vse,vact
//    0x10_0000 : CLUT       (entry n at +n*4, value 0x00RRGGBB)
//    0x80_0000 : VRAM aperture (byte offset = addr[22:0])
//
//  Verified in sim/iverilog/tb_dafb.v (8bpp) and tb_dafb_modes.v (timing,
//  programmable CRTC, 16/32 bpp direct-colour scanout).
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
	reg [7:0]  reg_ctrl;           // [0]=video enable, [1]=use programmed CRTC
	reg [1:0]  reg_depth;          // pixel depth: 0=8bpp(indexed) 1=16bpp 2=32bpp
	reg [7:0]  reg_pixdiv;         // pixel-clock divider (0 => clk/2, else clk/(n+1))

	// Programmable CRTC timing (real DAFB has a fully programmable CRTC). These
	// override the vmode presets when reg_ctrl[1]=1. Values are in pixels.
	reg [11:0] cr_htot, cr_hss, cr_hse, cr_hact;   // h total, sync start, sync end, active
	reg [11:0] cr_vtot, cr_vss, cr_vse, cr_vact;   // v total, sync start, sync end, active

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
			reg_depth  <= 2'd0;        // 8 bpp indexed (classic Mac desktop)
			reg_pixdiv <= 8'd0;        // clk/2 default
			cr_htot<=12'd800; cr_hss<=12'd656; cr_hse<=12'd752; cr_hact<=12'd640;
			cr_vtot<=12'd525; cr_vss<=12'd490; cr_vse<=12'd492; cr_vact<=12'd480;
		end else begin
			ack <= 1'b0;

			// writes
			if (cpu_wr) begin
				if (is_reg) begin
					case (addr[7:2])
						6'h00: reg_ctrl   <= din[7:0];
						6'h01: reg_base   <= din[23:0];
						6'h02: reg_stride <= din[15:0];
						6'h03: reg_depth  <= din[1:0];
						6'h07: reg_pixdiv <= din[7:0];
						6'h08: cr_htot    <= din[11:0];
						6'h09: cr_hss     <= din[11:0];
						6'h0A: cr_hse     <= din[11:0];
						6'h0B: cr_hact    <= din[11:0];
						6'h0C: cr_vtot    <= din[11:0];
						6'h0D: cr_vss     <= din[11:0];
						6'h0E: cr_vse     <= din[11:0];
						6'h0F: cr_vact    <= din[11:0];
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
				case (addr[7:2])
					6'h01:   dout <= {8'd0, reg_base};
					6'h02:   dout <= {16'd0, reg_stride};
					6'h03:   dout <= {30'd0, reg_depth};
					6'h07:   dout <= {24'd0, reg_pixdiv};
					6'h08:   dout <= {20'd0, cr_htot};
					6'h09:   dout <= {20'd0, cr_hss};
					6'h0A:   dout <= {20'd0, cr_hse};
					6'h0B:   dout <= {20'd0, cr_hact};
					6'h0C:   dout <= {20'd0, cr_vtot};
					6'h0D:   dout <= {20'd0, cr_vss};
					6'h0E:   dout <= {20'd0, cr_vse};
					6'h0F:   dout <= {20'd0, cr_vact};
					default: dout <= {24'd0, reg_ctrl};
				endcase
			else if (is_clut)
				dout <= {8'd0, clut[clut_idx]};
			else
				dout <= {vram0[cpu_word], vram1[cpu_word], vram2[cpu_word], vram3[cpu_word]};

			if (sel && !ack) ack <= 1'b1;
		end
	end

	// ================= Pixel clock enable =================
	// Programmable divider: reg_pixdiv==0 reproduces the classic clk/2 rate
	// (ce_pix high every 2 clocks); otherwise ce_pix is high once every
	// (reg_pixdiv+1) clocks. NOTE: this is a clock ENABLE off clk_sys; the true
	// output pixel clock for the high-resolution modes (e.g. 1152x870@75 needs
	// ~100 MHz) must come from a reconfigurable video PLL - see item 7 in
	// docs/TARGET_SPEC.md. The CRTC/divider logic here is PLL-ready.
	reg pdiv;
	reg [7:0] pcnt;
	always @(posedge clk) begin
		if (reset) begin pdiv <= 1'b0; pcnt <= 8'd0; ce_pix <= 1'b0; end
		else if (reg_pixdiv == 8'd0) begin
			pdiv <= ~pdiv; ce_pix <= pdiv;                 // clk/2 (default)
		end else begin
			if (pcnt == reg_pixdiv) begin pcnt <= 8'd0; ce_pix <= 1'b1; end
			else                    begin pcnt <= pcnt + 8'd1; ce_pix <= 1'b0; end
		end
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

	// Programmed CRTC (reg_ctrl[1]) supplies absolute total/sync/active values and
	// overrides the vmode presets. TESTTIMING keeps the parameter timing so the
	// fast-sim testbench frames are unaffected.
	wire use_prog = reg_ctrl[1] & (TESTTIMING == 0);

	wire [11:0] H_ACTs = use_prog ? cr_hact : h_act_v;
	wire [11:0] V_ACTs = use_prog ? cr_vact : v_act_v;
	wire [11:0] H_TOT  = use_prog ? cr_htot : (h_act_v + h_fp_v + h_sy_v + h_bp_v);
	wire [11:0] V_TOT  = use_prog ? cr_vtot : (v_act_v + v_fp_v + v_sy_v + v_bp_v);
	wire [11:0] H_SE   = use_prog ? cr_hss  : (h_act_v + h_fp_v);            // hsync start
	wire [11:0] H_SEND = use_prog ? cr_hse  : (h_act_v + h_fp_v + h_sy_v);   // hsync end
	wire [11:0] V_SE   = use_prog ? cr_vss  : (v_act_v + v_fp_v);
	wire [11:0] V_SEND = use_prog ? cr_vse  : (v_act_v + v_fp_v + v_sy_v);

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
			else if (hc == H_TOT-1 && v_act)    line_base <= line_base + {8'd0, reg_stride};
		end
	end

	// Bytes per pixel from the depth register: 8bpp=1, 16bpp=2, 32bpp=4.
	wire [23:0] pix_off  = (reg_depth == 2'd2) ? {10'd0, hc, 2'b00} :  // *4 (32bpp)
	                       (reg_depth == 2'd1) ? {11'd0, hc, 1'b0}  :  // *2 (16bpp)
	                                             {12'd0, hc};          // *1 (8bpp)
	wire [23:0] pix_byte = line_base + pix_off;
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

	// 8 bpp: byte selected by the low address bits -> CLUT index.
	wire [7:0] s1_index = (s1_lane == 2'd0) ? s1_b0 :
	                      (s1_lane == 2'd1) ? s1_b1 :
	                      (s1_lane == 2'd2) ? s1_b2 : s1_b3;

	// 16 bpp direct (Apple "thousands", big-endian xRGB1555): even pixel = high
	// halfword {b0,b1}, odd = low {b2,b3}. Expand each 5-bit channel to 8 bits by
	// replicating the top bits.
	wire [15:0] s1_hw  = s1_lane[1] ? {s1_b2, s1_b3} : {s1_b0, s1_b1};
	wire [23:0] rgb16  = {{s1_hw[14:10], s1_hw[14:12]},
	                      {s1_hw[9:5],   s1_hw[9:7]},
	                      {s1_hw[4:0],   s1_hw[4:2]}};

	// 32 bpp direct (Apple "millions", big-endian $00RRGGBB): b0 unused.
	wire [23:0] rgb32  = {s1_b1, s1_b2, s1_b3};

	// Depth mux (8 bpp goes through the CLUT; 16/32 are direct-color).
	wire [23:0] pix_rgb = (reg_depth == 2'd2) ? rgb32 :
	                      (reg_depth == 2'd1) ? rgb16 : clut[s1_index];

	// ---- Stage 2: colour resolve (registered) + final blanks/sync ----
	reg [23:0] s2_rgb;
	reg        s2_act;
	always @(posedge clk) if (ce_pix) begin
		s2_rgb <= pix_rgb;
		s2_act <= s1_act;
		HBlank <= s1_hbl; VBlank <= s1_vbl; HSync <= s1_hsy; VSync <= s1_vsy;
		s2_x <= s1_x; s2_y <= s1_y;
		if (s1_act) {r, g, b} <= pix_rgb;
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
