//============================================================================
//  Macintosh Quadra 950 - system interconnect
//
//  This module is the heart of the core: it wires the CPU to the memory
//  controller, the custom chips and the peripherals, and implements the
//  address decode for the Quadra 950 memory map (see docs/MEMORY_MAP.md).
//
//  STATUS: scaffold. The address decode and module instantiations reflect the
//  real machine, but the CPU and chip implementations behind them are stubs.
//  The video path generates real sync timing plus a placeholder pattern so the
//  core produces a stable display before the CPU/DAFB are functional.
//============================================================================

module quadra950
(
	input             clk_sys,
	input             reset,

	input             ram_128mb,     // 0 = 64MB, 1 = 128MB of emulated RAM

	// ROM / file download (index 0 = Quadra ROM, 1 MB)
	input             ioctl_download,
	input      [7:0]  ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input      [15:0] ioctl_dout,

	// SCSI disk images via hps_io block interface
	input      [1:0]  img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output     [31:0] sd_lba[2],
	output     [1:0]  sd_rd,
	output     [1:0]  sd_wr,
	input      [1:0]  sd_ack,
	input      [13:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	output     [15:0] sd_buff_din[2],
	input             sd_buff_wr,

	// Input
	input      [10:0] ps2_key,
	input      [24:0] ps2_mouse,

	// DDR3 (emulated main RAM)
	output            DDRAM_CLK,
	input             DDRAM_BUSY,
	output     [7:0]  DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output            DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output     [7:0]  DDRAM_BE,
	output            DDRAM_WE,

	// Video
	output            ce_pix,
	output            HBlank,
	output            HSync,
	output            VBlank,
	output            VSync,
	output     [7:0]  r,
	output     [7:0]  g,
	output     [7:0]  b,

	// Audio
	output     [15:0] audio_l,
	output     [15:0] audio_r,

	output            disk_led
);

	assign DDRAM_CLK = clk_sys;

	//========================================================================
	//  CPU bus
	//========================================================================
	// The 68040 uses a 32-bit non-multiplexed bus with a burst-capable
	// synchronous protocol (TS/TA/TEA handshake), quite different from the
	// 68000/020 asynchronous bus. cpu_wrapper adapts whatever core we drop in
	// (initially a 68020-class core) toward these semantics.
	wire [31:0] cpu_addr;
	wire [31:0] cpu_dout;
	wire [31:0] cpu_din;
	wire  [3:0] cpu_be;      // byte enables (from SIZ/A0-A1 decode)
	wire        cpu_rw;      // 1 = read, 0 = write
	wire        cpu_ts;      // transfer start
	wire        cpu_ta;      // transfer acknowledge (to CPU)
	wire  [2:0] cpu_fc;      // function code (user/supervisor, data/program)
	wire  [2:0] ipl;         // interrupt priority level (from iobus), active low
	// 33 MHz clock enable. Tied high for now: the CPU runs at the system clock
	// (the bus adapter requires ce high until a real 33 MHz divider is added).
	// TODO: drive from a divider off the PLL to emulate the true 33 MHz rate.
	wire        cpu_ce = 1'b1;

	cpu_wrapper cpu
	(
		.clk    (clk_sys),
		.ce     (cpu_ce),
		.reset  (reset),

		.addr   (cpu_addr),
		.dout   (cpu_dout),
		.din    (cpu_din),
		.be     (cpu_be),
		.rw     (cpu_rw),
		.ts     (cpu_ts),
		.ta     (cpu_ta),
		.fc     (cpu_fc),

		.ipl    (ipl)         // interrupt priority level from VIA/IOSB
	);

	//========================================================================
	//  Address decode (Quadra 950 map - see docs/MEMORY_MAP.md)
	//========================================================================
	// $0000_0000 - RAM (up to 256MB on real HW; 64/128MB emulated)
	// $4000_0000 - ROM (1 MB, also shadowed at $0000_0000 at reset)
	// $5000_0000 - I/O space (VIA, SCC, SCSI, ASC, SWIM, IOSB regs)
	// $F900_0000 - DAFB frame buffer / video registers
	// $F000_0000 - NuBus super slot space ($Fs00_0000, s = 9..E)
	// $6000_0000 - NuBus standard slot space
	wire sel_ram   = (cpu_addr[31:28] == 4'h0);
	wire sel_rom   = (cpu_addr[31:24] == 8'h40) || (rom_overlay && sel_ram);
	wire sel_io    = (cpu_addr[31:24] == 8'h50);
	wire sel_dafb  = (cpu_addr[31:24] == 8'hF9);
	wire sel_nubus = (cpu_addr[31:28] == 4'h6) || (cpu_addr[31:28] == 4'hF);

	// The MCU serves both ROM (incl. overlay) and normal RAM out of DDR3.
	wire to_rom = sel_rom;                       // $40xxxxxx or overlaid low mem
	wire to_ram = sel_ram & ~rom_overlay;        // normal RAM (overlay cleared)
	wire sel_mem = to_rom | to_ram;

	// SCSI: two 53C96 channels in I/O space ($50F1_xxxx internal, $50F2_xxxx ext)
	wire sel_scsi0 = sel_io & (cpu_addr[23:16] == 8'hF1);
	wire sel_scsi1 = sel_io & (cpu_addr[23:16] == 8'hF2);
	wire [3:0] scsi_reg = cpu_addr[7:4];         // 16-byte register spacing

	// Apple Sound Chip in I/O space ($50F3_xxxx)
	wire sel_asc = sel_io & (cpu_addr[23:16] == 8'hF3);
	wire [7:0] asc_dout;
	wire       asc_ack, asc_irq;

	// ROM overlay: at reset the MCU maps ROM over low memory ($0). Per Apple's
	// developer note, the overlay is cleared on the first access to ROM's real
	// location ($40000000), after which RAM appears at $0.
	reg rom_overlay;
	always @(posedge clk_sys) begin
		if (reset) rom_overlay <= 1'b1;
		else if (cpu_ts && cpu_addr[31:24] == 8'h40) rom_overlay <= 1'b0;
	end

	//========================================================================
	//  Memory Control Unit (MCU) -> DDR3
	//
	//  NOTE: the Quadra 900/950 memory controller is the "MCU". The djMEMC
	//  part often cited online belongs to the later Centris/Quadra 610/650/800.
	//========================================================================
	wire [31:0] ram_dout;
	wire        ram_ack;

	mcu mcu
	(
		.clk        (clk_sys),
		.reset      (reset),
		.ram_128mb  (ram_128mb),

		.cpu_addr   (cpu_addr),
		.cpu_din    (cpu_dout),
		.cpu_dout   (ram_dout),
		.cpu_be     (cpu_be),
		.cpu_rw     (cpu_rw),
		.cpu_req    (cpu_ts & sel_mem),
		.rom_sel    (to_rom),
		.cpu_ack    (ram_ack),

		// ROM image load path
		.ioctl_download(ioctl_download),
		.ioctl_index(ioctl_index),
		.ioctl_wr   (ioctl_wr),
		.ioctl_addr (ioctl_addr),
		.ioctl_dout (ioctl_dout),

		.DDRAM_BUSY (DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR (DDRAM_ADDR),
		.DDRAM_DOUT (DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD   (DDRAM_RD),
		.DDRAM_DIN  (DDRAM_DIN),
		.DDRAM_BE   (DDRAM_BE),
		.DDRAM_WE   (DDRAM_WE)
	);

	//========================================================================
	//  I/O bus (JDB + Relayer bridge) - aggregates VIA1/VIA2, IOPs, SCC,
	//  SCSI, SONIC, sound and drives the interrupt priority level.
	//========================================================================
	wire [31:0] io_dout;
	wire        io_ack;

	iobus iobus
	(
		.clk      (clk_sys),
		.reset    (reset),
		.sel      (sel_io & cpu_ts & ~sel_scsi0 & ~sel_scsi1 & ~sel_asc),
		.addr     (cpu_addr[23:0]),
		.din      (cpu_dout),
		.dout     (io_dout),
		.rw       (cpu_rw),
		.ack      (io_ack),
		.vbl      (VBlank),        // DAFB vertical blank -> VIA1 CA1
		.ps2_key  (ps2_key),
		.ps2_mouse(ps2_mouse),
		.ext_irq2 (scsi0_irq | scsi1_irq | asc_irq),
		.ipl      (ipl)
	);

	//========================================================================
	//  Video (DAFB) - owns pixel clock, sync timing and the frame buffer
	//========================================================================
	wire [31:0] dafb_dout;
	wire        dafb_ack;

	dafb dafb
	(
		.clk      (clk_sys),
		.reset    (reset),

		// CPU register/VRAM access
		.sel      (sel_dafb & cpu_ts),
		.addr     (cpu_addr[23:0]),
		.din      (cpu_dout),
		.dout     (dafb_dout),
		.be       (cpu_be),
		.rw       (cpu_rw),
		.ack      (dafb_ack),

		// Video out
		.ce_pix   (ce_pix),
		.HBlank   (HBlank),
		.HSync    (HSync),
		.VBlank   (VBlank),
		.VSync    (VSync),
		.r        (r),
		.g        (g),
		.b        (b)
	);

	//========================================================================
	//  Read data mux + transfer acknowledge back to the CPU
	//========================================================================
	assign cpu_din = sel_scsi0 ? {24'd0, scsi0_dout} :
	                 sel_scsi1 ? {24'd0, scsi1_dout} :
	                 sel_asc   ? {24'd0, asc_dout}   :
	                 sel_io    ? io_dout   :
	                 sel_dafb  ? dafb_dout :
	                             ram_dout;

	assign cpu_ta  = ram_ack | io_ack | dafb_ack | scsi0_ack | scsi1_ack | asc_ack;

	//========================================================================
	//  Audio (Apple Sound Chip)
	//========================================================================
	// Sample-rate enable (~22.257 kHz). Divisor assumes the PLL system clock;
	// adjust SND_DIV once the PLL is regenerated for real clocks.
	localparam SND_DIV = 2247;                   // ~50 MHz / 22257
	reg [11:0] snd_cnt; reg snd_ce;
	always @(posedge clk_sys) begin
		if (reset) begin snd_cnt <= 0; snd_ce <= 0; end
		else if (snd_cnt == SND_DIV-1) begin snd_cnt <= 0; snd_ce <= 1'b1; end
		else begin snd_cnt <= snd_cnt + 1'b1; snd_ce <= 1'b0; end
	end

	asc asc
	(
		.clk      (clk_sys),
		.reset    (reset),
		.snd_ce   (snd_ce),
		.sel      (sel_asc & cpu_ts),
		.addr     (cpu_addr[11:0]),
		.din      (cpu_dout[7:0]),
		.dout     (asc_dout),
		.rw       (cpu_rw),
		.ack      (asc_ack),
		.irq      (asc_irq),
		.audio_l  (audio_l),
		.audio_r  (audio_r)
	);

	//========================================================================
	//  SCSI (dual NCR 53C96): channel 0 = internal, channel 1 = external.
	//  Each drives one hps_io block channel (disk image index 0/1).
	//========================================================================
	wire [7:0] scsi0_dout, scsi1_dout;
	wire       scsi0_ack,  scsi1_ack;
	wire       scsi0_irq,  scsi1_irq;
	wire       scsi0_act,  scsi1_act;

	scsi_ncr53c96 scsi0 (
		.clk(clk_sys), .reset(reset),
		.sel(sel_scsi0 & cpu_ts), .addr(scsi_reg), .din(cpu_dout[7:0]),
		.dout(scsi0_dout), .rw(cpu_rw), .ack(scsi0_ack), .irq(scsi0_irq),
		.img_mounted(img_mounted[0]), .img_readonly(img_readonly), .img_size(img_size),
		.sd_lba(sd_lba[0]), .sd_rd(sd_rd[0]), .sd_wr(sd_wr[0]), .sd_ack(sd_ack[0]),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din[0]), .sd_buff_wr(sd_buff_wr), .active(scsi0_act)
	);

	scsi_ncr53c96 scsi1 (
		.clk(clk_sys), .reset(reset),
		.sel(sel_scsi1 & cpu_ts), .addr(scsi_reg), .din(cpu_dout[7:0]),
		.dout(scsi1_dout), .rw(cpu_rw), .ack(scsi1_ack), .irq(scsi1_irq),
		.img_mounted(img_mounted[1]), .img_readonly(img_readonly), .img_size(img_size),
		.sd_lba(sd_lba[1]), .sd_rd(sd_rd[1]), .sd_wr(sd_wr[1]), .sd_ack(sd_ack[1]),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din[1]), .sd_buff_wr(sd_buff_wr), .active(scsi1_act)
	);

	assign disk_led = scsi0_act | scsi1_act;

endmodule
