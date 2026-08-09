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
//
//  ---- External VRAM path (parameter EXT_VRAM, OFF BY DEFAULT) --------------
//  EXT_VRAM=0 (default): VRAM is the four internal byte-lane block RAMs above
//  and scanout reads them combinationally. Behaviour is exactly as described
//  above; the vram_* ports are driven to 0 and unused.
//
//  EXT_VRAM=1: VRAM lives in large off-chip memory (the board's SDRAM, up to
//  2 MB - item 5 of docs/TARGET_SPEC.md) reached through the vram_* port. Two
//  things change while the 2-stage pixel pipeline and all 8/16/32 bpp colour
//  logic stay identical:
//    * CPU VRAM-aperture (0x80_0000) reads/writes are forwarded to the external
//      port (vram_rd/vram_wr/vram_addr/vram_wdata/vram_wbe -> vram_rdata/
//      vram_rvalid, gated by vram_ready); register and CLUT accesses stay
//      internal. `ack` is held until the external transaction completes.
//    * Scanout is decoupled from memory latency by a PING-PONG LINE BUFFER
//      (two 2048x32-bit buffers). While the CRTC scans the active buffer, the
//      next visible line is prefetched from VRAM into the inactive buffer with
//      sequential vram_rd bursts; the buffers swap at end of line. Line 0 is
//      prefetched during vblank. The per-pixel pipeline sources its four lane
//      bytes (vram_q0..q3) from the active line buffer instead of the block
//      RAMs - the only change to the scanout datapath.
//  Verified in sim/iverilog/tb_dafb_vram.v (behavioural external VRAM model).
//============================================================================

module dafb #(
	parameter VRAM_WORDS = 4096,          // 32-bit words (test size)
	// When TESTTIMING=1 the parameter timing below is used (fast sim frame);
	// otherwise the CRTC timing comes from `vmode` (real Apple resolutions).
	parameter TESTTIMING = 0,
	parameter H_ACT = 640, H_FP = 16, H_SY = 96, H_BP = 48,
	parameter V_ACT = 480, V_FP = 10, V_SY = 2,  V_BP = 33,
	// EXT_VRAM=0: internal block-RAM VRAM (default, unchanged behaviour).
	// EXT_VRAM=1: VRAM in external memory via the vram_* port + line buffer.
	parameter EXT_VRAM = 0
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

	output            vbl_irq,     // vertical-blank interrupt (level)

	// External VRAM port (only driven/used when EXT_VRAM=1; safe 0s otherwise).
	output reg        vram_rd,     // read request (1-cycle strobe)
	output reg        vram_wr,     // write request (1-cycle strobe)
	output reg [22:0] vram_addr,   // byte address into VRAM (2 MB)
	output reg [31:0] vram_wdata,
	output reg [3:0]  vram_wbe,
	input      [31:0] vram_rdata,
	input             vram_rvalid, // read data valid (1-cycle)
	input             vram_ready   // request accepted / can issue
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

	// ---- External VRAM path (EXT_VRAM=1): ping-pong line buffers + handshake --
	// Two line buffers sized for the widest mode (2048 x 32-bit each, ~8 KB).
	// One is read by scanout (active) while the next visible line is prefetched
	// into the other (inactive); they swap at end of line.
	localparam LBW = 2048;
	reg [31:0] linebuf0 [0:LBW-1];
	reg [31:0] linebuf1 [0:LBW-1];
	reg        lb_active;                  // buffer scanout currently reads
	reg [23:0] lb_base0, lb_base1;         // VRAM line base held in each buffer
	reg        lb_valid0, lb_valid1;

	// CPU <-> external-port handshake (CPU VRAM aperture goes off-chip).
	reg        cpu_vreq;                   // a CPU VRAM access awaits completion
	reg        cpu_vwr;                    // latched: 1=write 0=read
	reg [22:0] cpu_vaddr;
	reg [31:0] cpu_vwdata;
	reg [3:0]  cpu_vwbe;
	reg        cpu_vdone;                  // ext port -> CPU: complete (pulse)
	reg [31:0] cpu_vrdata;                 // ext port -> CPU: read data
	reg        cfg_wr;                     // pulse: a control register was written
	reg        sel_d;                      // for CPU-access rising-edge detect

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
			cpu_vreq <= 1'b0; sel_d <= 1'b0; cfg_wr <= 1'b0;
		end else begin
			ack    <= 1'b0;
			cfg_wr <= 1'b0;
			sel_d  <= sel;

			// writes
			if (cpu_wr) begin
				if (is_reg) begin
					cfg_wr <= 1'b1;    // any register write invalidates the line buffers
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
				end else if (is_vram && (EXT_VRAM == 0)) begin
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
			else if (EXT_VRAM == 0)
				dout <= {vram0[cpu_word], vram1[cpu_word], vram2[cpu_word], vram3[cpu_word]};
			// (EXT_VRAM: VRAM read data is captured on cpu_vdone below)

			// ---- acknowledge / external-VRAM handshake ----
			if ((EXT_VRAM != 0) && is_vram) begin
				// Kick off one external transaction on the rising edge of sel;
				// hold ack off until the external port signals completion.
				if (sel && !sel_d) begin
					cpu_vreq   <= 1'b1;
					cpu_vwr    <= cpu_wr;
					cpu_vaddr  <= addr[22:0];
					cpu_vwdata <= din;
					cpu_vwbe   <= be;
				end
				if (cpu_vdone) begin
					cpu_vreq <= 1'b0;
					if (!cpu_vwr) dout <= cpu_vrdata;
					ack <= 1'b1;
				end
			end else begin
				if (sel && !ack) ack <= 1'b1;
			end
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

	// ================= External VRAM: line-buffer prefetch =================
	// End-of-line pulse (drives the ping-pong swap).
	wire line_end = ce_pix && (hc == H_TOT-1);

	// Base address of the NEXT line to display: the following visible line while
	// active, else line 0 (reg_base) on the last visible line and through vblank
	// so line 0 is prefetched during vblank and ready when the frame starts.
	wire [23:0] need_base = (v_act && (vc != V_ACTs-1)) ? (line_base + {8'd0, reg_stride})
	                                                    : reg_base;

	// 32-bit words needed to cover one line at the current depth.
	wire [11:0] pf_words_w = (reg_depth == 2'd2) ? H_ACTs :                 // 32bpp: 1 px/word
	                         (reg_depth == 2'd1) ? ((H_ACTs + 12'd1) >> 1) : // 16bpp: 2 px/word
	                                               ((H_ACTs + 12'd3) >> 2);  // 8bpp:  4 px/word

	// Base/valid of the inactive (prefetch-target) buffer.
	wire [23:0] inact_base  = lb_active ? lb_base0  : lb_base1;
	wire        inact_valid = lb_active ? lb_valid0 : lb_valid1;
	wire        pf_needed   = (EXT_VRAM != 0) && reg_ctrl[0] &&
	                          (!inact_valid || (inact_base != need_base));

	localparam FB_IDLE = 2'd0, FB_CWR = 2'd1, FB_CRD = 2'd2, FB_PFRD = 2'd3;
	reg [1:0]  fbst;
	reg        pf_wait;       // a prefetch read is outstanding
	reg        pf_bank;       // destination buffer for the current prefetch
	reg [23:0] pf_base;       // line base being prefetched
	reg [22:0] pf_addr;       // current read address
	reg [11:0] pf_words, pf_cnt;
	reg [10:0] pf_widx;       // write index into the line buffer

	always @(posedge clk) begin
		if (reset) begin
			vram_rd <= 1'b0; vram_wr <= 1'b0; vram_addr <= 23'd0;
			vram_wdata <= 32'd0; vram_wbe <= 4'd0;
			cpu_vdone <= 1'b0; cpu_vrdata <= 32'd0;
			fbst <= FB_IDLE; pf_wait <= 1'b0; pf_bank <= 1'b0;
			pf_base <= 24'd0; pf_addr <= 23'd0;
			pf_words <= 12'd0; pf_cnt <= 12'd0; pf_widx <= 11'd0;
			lb_active <= 1'b0;
			lb_base0 <= 24'hFFFFFF; lb_base1 <= 24'hFFFFFF;
			lb_valid0 <= 1'b0; lb_valid1 <= 1'b0;
		end else begin
			vram_rd <= 1'b0; vram_wr <= 1'b0; cpu_vdone <= 1'b0;  // 1-cycle strobes

			if (EXT_VRAM != 0) begin
				// Ping-pong swap at end of each scanline.
				if (line_end) lb_active <= ~lb_active;

				case (fbst)
				FB_IDLE: begin
					if (cpu_vreq) begin                     // CPU access has priority
						if (cpu_vwr) begin
							if (vram_ready) begin
								vram_wr    <= 1'b1;
								vram_addr  <= cpu_vaddr;
								vram_wdata <= cpu_vwdata;
								vram_wbe   <= cpu_vwbe;
								fbst       <= FB_CWR;
							end
						end else if (vram_ready) begin
							vram_rd   <= 1'b1;
							vram_addr <= cpu_vaddr;
							fbst      <= FB_CRD;
						end
					end else if (pf_needed) begin           // prefetch next line
						pf_bank  <= ~lb_active;
						pf_base  <= need_base;
						pf_addr  <= need_base[22:0];
						pf_words <= pf_words_w;
						pf_cnt   <= 12'd0;
						pf_widx  <= 11'd0;
						pf_wait  <= 1'b0;
						fbst     <= FB_PFRD;
					end
				end

				FB_CWR: begin                               // write accepted last cycle
					cpu_vdone <= 1'b1;
					fbst      <= FB_IDLE;
				end

				FB_CRD: begin
					if (vram_rvalid) begin
						cpu_vrdata <= vram_rdata;
						cpu_vdone  <= 1'b1;
						fbst       <= FB_IDLE;
					end
				end

				FB_PFRD: begin
					if (!pf_wait) begin
						if (pf_cnt == pf_words) begin       // whole line fetched
							if (pf_bank) begin lb_base1 <= pf_base; lb_valid1 <= 1'b1; end
							else         begin lb_base0 <= pf_base; lb_valid0 <= 1'b1; end
							fbst <= FB_IDLE;
						end else if (cpu_vreq) begin        // let a CPU access preempt
							fbst <= FB_IDLE;                //  (prefetch restarts after)
						end else if (vram_ready) begin
							vram_rd   <= 1'b1;
							vram_addr <= pf_addr;
							pf_wait   <= 1'b1;
						end
					end else if (vram_rvalid) begin
						if (pf_bank) linebuf1[pf_widx] <= vram_rdata;
						else         linebuf0[pf_widx] <= vram_rdata;
						pf_widx <= pf_widx + 11'd1;
						pf_addr <= pf_addr + 23'd4;
						pf_cnt  <= pf_cnt  + 12'd1;
						pf_wait <= 1'b0;
					end
				end
				endcase

				// A control-register write invalidates both buffers so the new
				// base/stride/depth is re-fetched (overrides a same-cycle load).
				if (cfg_wr) begin lb_valid0 <= 1'b0; lb_valid1 <= 1'b0; end
			end
		end
	end

	// Bytes per pixel from the depth register: 8bpp=1, 16bpp=2, 32bpp=4.
	wire [23:0] pix_off  = (reg_depth == 2'd2) ? {10'd0, hc, 2'b00} :  // *4 (32bpp)
	                       (reg_depth == 2'd1) ? {11'd0, hc, 1'b0}  :  // *2 (16bpp)
	                                             {12'd0, hc};          // *1 (8bpp)
	wire [23:0] pix_byte = line_base + pix_off;
	wire [AW-1:0] pix_word = pix_byte[AW+1:2];
	wire [1:0]    pix_lane = pix_byte[1:0];

	// Line-buffer read index for EXT_VRAM scanout: word offset within the line
	// (pix_off is the depth-scaled byte offset from the line base).
	wire [10:0] lb_rword = pix_off[12:2];

	// Scanout byte source: internal block RAM (EXT_VRAM=0) or the active line
	// buffer (EXT_VRAM=1). These feed the existing Stage-1 registers unchanged.
	//
	// CRITICAL for the Cyclone V fit: the line-buffer read lives ONLY inside the
	// EXT_VRAM!=0 branch. In the default (EXT_VRAM=0) hardware build the two
	// 2048x32-bit line buffers (linebuf0/linebuf1) then have no reader (this
	// branch) and no writer (the prefetch FSM body is under `if (EXT_VRAM != 0)`),
	// so synthesis removes them entirely instead of building a ~2048:1 register
	// mux (~65k ALUTs). Do NOT read the line buffers combinationally outside this
	// generate branch, or the arrays are pulled back into logic and the design no
	// longer fits.
	wire [7:0] vram_q0, vram_q1, vram_q2, vram_q3;
	generate
		if (EXT_VRAM != 0) begin : g_scan_ext
			reg [31:0] lb_scan_word;
			always @(*) lb_scan_word = lb_active ? linebuf1[lb_rword]
			                                     : linebuf0[lb_rword];
			assign vram_q0 = lb_scan_word[31:24];
			assign vram_q1 = lb_scan_word[23:16];
			assign vram_q2 = lb_scan_word[15: 8];
			assign vram_q3 = lb_scan_word[ 7: 0];
		end else begin : g_scan_int
			assign vram_q0 = vram0[pix_word];
			assign vram_q1 = vram1[pix_word];
			assign vram_q2 = vram2[pix_word];
			assign vram_q3 = vram3[pix_word];
		end
	endgenerate

	// ---- Stage 1: VRAM read (registered) + pipeline blanks/sync ----
	reg [7:0] s1_b0, s1_b1, s1_b2, s1_b3;
	reg       s1_hbl, s1_vbl, s1_hsy, s1_vsy, s1_act;
	reg [1:0] s1_lane;
	reg [11:0] s1_x, s1_y, s2_x, s2_y;   // pixel coords pipelined with the data
	always @(posedge clk) if (ce_pix) begin
		s1_b0 <= vram_q0; s1_b1 <= vram_q1;
		s1_b2 <= vram_q2; s1_b3 <= vram_q3;
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
