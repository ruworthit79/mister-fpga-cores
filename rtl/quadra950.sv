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
	wire        cpu_ce;      // 33 MHz clock enable

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

	// ROM overlay: at reset the ROM is mapped over low memory until the OS
	// clears the overlay bit (via VIA). Cleared on first write to high RAM.
	reg rom_overlay;
	always @(posedge clk_sys) begin
		if (reset) rom_overlay <= 1'b1;
		// TODO: clear on VIA overlay bit write (IOSB/VIA glue).
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
		.cpu_req    (cpu_ts & (sel_ram & ~rom_overlay)),
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
	wire  [2:0] ipl;

	iobus iobus
	(
		.clk      (clk_sys),
		.reset    (reset),
		.sel      (sel_io & cpu_ts),
		.addr     (cpu_addr[23:0]),
		.din      (cpu_dout),
		.dout     (io_dout),
		.rw       (cpu_rw),
		.ack      (io_ack),
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
	assign cpu_din = sel_io   ? io_dout   :
	                 sel_dafb ? dafb_dout :
	                            ram_dout;

	assign cpu_ta  = ram_ack | io_ack | dafb_ack;

	//========================================================================
	//  Audio (Apple Sound Chip)
	//========================================================================
	asc asc
	(
		.clk      (clk_sys),
		.reset    (reset),
		.audio_l  (audio_l),
		.audio_r  (audio_r)
	);

	//========================================================================
	//  SCSI (dual NCR 53C96) - not yet instantiated; tie off storage outputs.
	//  When integrating, instantiate scsi_ncr53c96 twice (internal/external)
	//  and connect each to one hps_io block channel (index 0/1).
	//========================================================================
	assign sd_lba[0]      = 32'd0;
	assign sd_lba[1]      = 32'd0;
	assign sd_rd          = 2'b00;
	assign sd_wr          = 2'b00;
	assign sd_buff_din[0] = 16'd0;
	assign sd_buff_din[1] = 16'd0;

	assign disk_led = 1'b0;

endmodule
