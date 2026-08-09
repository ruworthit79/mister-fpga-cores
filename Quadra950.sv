//============================================================================
//  Macintosh Quadra 950 (68040) for MiSTer - top level (emu) wrapper
//
//  This is the framework-facing wrapper. It instantiates hps_io, the PLL and
//  the actual system in rtl/quadra950.sv. The CPU (TG68, 68020-class with a
//  Level-A 68040 personality) and the custom chips (MCU, VIA, DAFB, ASC, SCSI,
//  Caboose RTC/PRAM, ADB) are implemented and simulation-verified. See
//  docs/HARDWARE.md for what a hardware build does and does NOT do yet, and
//  docs/ROADMAP.md / docs/BOOT_ANALYSIS.md for the boot state.
//
//  CLOCK PLAN (docs/HARDWARE.md): clk_sys = 50 MHz -> DAFB pixel enable
//  clk/2 = 25 MHz (640x480), ASC sample ~22.25 kHz, emulated CPU = clk/CPU_DIV.
//  The PLL frequency spec (rtl/pll/pll_0002.v) is set to 50 MHz and is
//  frequency-driven (Quartus computes the counters), but has NOT been compiled
//  in Quartus here -- verify PLL lock + timing closure on the first build.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK  = {1'b0, disk_led};
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////
// Aspect ratio: Quadra 950 built-in video drives a 4:3 display.
wire [1:0] ar = status[9:8];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

//////////////////////////////////////////////////////////////////
//  OSD / menu definition
//////////////////////////////////////////////////////////////////
`include "build_id.v"
localparam CONF_STR = {
	"Quadra950;;",
	"-;",
	"F0,ROM,Load Quadra 950 ROM;",   // 1 MB Quadra 950 ROM -> ioctl_index 0 (see mcu.sv)
	"-;",
	"S0,IMGHDVDSK,Mount SCSI HD;",
	"S1,ISOIMGHDVDSK,Mount CD-ROM;",
	"-;",
	"O[9:8],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[11:10],Screen size,640x480,832x624,1024x768,1152x870;",
	"-;",
	"O[13:12],RAM,64MB,128MB,256MB;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

//////////////////////////////////////////////////////////////////
//  HPS (ARM) I/O
//////////////////////////////////////////////////////////////////
wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire        direct_video;

wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;

// ROM / file download channel (Quadra ROM image, 1 MB) + NVRAM save/restore
wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_upload;
wire        ioctl_rd;
wire [15:0] ioctl_din;
wire  [7:0] ioctl_upload_index;

localparam [7:0] NVRAM_INDEX = 8'd2;   // PRAM save file (ioctl index)

// SCSI disk images (two targets)
wire  [1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

wire [31:0] sd_lba[2];
wire  [1:0] sd_rd;
wire  [1:0] sd_wr;
wire  [1:0] sd_ack;
wire [13:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[2];
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	.status_menumask(0),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_rd(ioctl_rd),
	.ioctl_din(ioctl_din),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

//////////////////////////////////////////////////////////////////
//  Clocks
//////////////////////////////////////////////////////////////////
// clk_sys = 50 MHz (rtl/pll, frequency-driven altera_pll). Drives the whole
// core (CPU via CPU_DIV, DAFB pixel enable clk/2, ASC, and DDRAM_CLK). See the
// clock-plan note in the header and docs/HARDWARE.md.
wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Hold the core in reset while the Quadra ROM is being downloaded (ioctl_index 0)
// so the CPU starts fresh from the newly loaded ROM once the transfer completes.
wire rom_download = ioctl_download & (ioctl_index == 8'd0);
wire reset = RESET | status[0] | buttons[1] | ~pll_locked | rom_download;

//////////////////////////////////////////////////////////////////
//  PRAM NVRAM save / restore via the ioctl save file (NVRAM_INDEX).
//  One PRAM byte per 16-bit ioctl word (low byte); ioctl_addr[8:1] -> 0..255.
//////////////////////////////////////////////////////////////////
wire [7:0] pram_bk_dout;
wire       nv_dl = ioctl_download & (ioctl_index == NVRAM_INDEX);
wire       nv_ul = ioctl_upload   & (ioctl_upload_index == NVRAM_INDEX);
wire [7:0] pram_bk_addr = ioctl_addr[8:1];
wire       pram_bk_wr   = nv_dl & ioctl_wr;
wire [7:0] pram_bk_din  = ioctl_dout[7:0];
assign ioctl_din = nv_ul ? {8'd0, pram_bk_dout} : 16'd0;

//////////////////////////////////////////////////////////////////
//  System
//////////////////////////////////////////////////////////////////
wire        ce_pix;
wire        HBlank, HSync, VBlank, VSync;
wire  [7:0] r, g, b;
wire [15:0] audio_l, audio_r;
wire        disk_led;

quadra950 quadra950
(
	.clk_sys      (clk_sys),
	.reset        (reset),

	.ram_cfg      (status[13:12]),
	.vmode        (status[11:10]),

	// ROM / file download
	.ioctl_download(ioctl_download),
	.ioctl_index  (ioctl_index),
	.ioctl_wr     (ioctl_wr),
	.ioctl_addr   (ioctl_addr),
	.ioctl_dout   (ioctl_dout),

	// SCSI storage (hps_io block interface)
	.img_mounted  (img_mounted),
	.img_readonly (img_readonly),
	.img_size     (img_size),
	.sd_lba       (sd_lba),
	.sd_rd        (sd_rd),
	.sd_wr        (sd_wr),
	.sd_ack       (sd_ack),
	.sd_buff_addr (sd_buff_addr),
	.sd_buff_dout (sd_buff_dout),
	.sd_buff_din  (sd_buff_din),
	.sd_buff_wr   (sd_buff_wr),

	// Input (ADB via PS/2 translation)
	.ps2_key      (ps2_key),
	.ps2_mouse    (ps2_mouse),

	// PRAM NVRAM backup
	.pram_bk_addr (pram_bk_addr),
	.pram_bk_wr   (pram_bk_wr),
	.pram_bk_din  (pram_bk_din),
	.pram_bk_dout (pram_bk_dout),

	// DDR3 (main system RAM lives in DDR3 on the DE10-Nano)
	.DDRAM_CLK    (DDRAM_CLK),
	.DDRAM_BUSY   (DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR   (DDRAM_ADDR),
	.DDRAM_DOUT   (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD     (DDRAM_RD),
	.DDRAM_DIN    (DDRAM_DIN),
	.DDRAM_BE     (DDRAM_BE),
	.DDRAM_WE     (DDRAM_WE),

	// Video
	.ce_pix       (ce_pix),
	.HBlank       (HBlank),
	.HSync        (HSync),
	.VBlank       (VBlank),
	.VSync        (VSync),
	.r            (r),
	.g            (g),
	.b            (b),

	// Audio
	.audio_l      (audio_l),
	.audio_r      (audio_r),

	.disk_led     (disk_led)
);

// SDRAM not used by this core (system RAM is in DDR3). Tri-state the pins.
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML,
        SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

// Secondary SD card unused.
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

//////////////////////////////////////////////////////////////////
//  Video output
//////////////////////////////////////////////////////////////////
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_SL    = 0;

assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;
assign VGA_R  = r;
assign VGA_G  = g;
assign VGA_B  = b;

//////////////////////////////////////////////////////////////////
//  Audio output (Apple Sound Chip -> 16-bit signed stereo)
//////////////////////////////////////////////////////////////////
assign AUDIO_S   = 1;          // signed
assign AUDIO_MIX = 0;
assign AUDIO_L   = audio_l;
assign AUDIO_R   = audio_r;

assign LED_USER  = ioctl_download | disk_led;

endmodule
