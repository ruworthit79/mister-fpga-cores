//============================================================================
//  boot_top - full-system Verilator boot harness.
//  Instantiates the WHOLE core (quadra950 + the GHDL-converted TG68 CPU + the
//  verified Verilog peripherals: MCU, VIA, RTC/Caboose, SCSI, DAFB, ASC) with
//  a behavioral DDR3 model preloaded with the real ROM. Everything the ROM's
//  hardware probe pokes now RESPONDS. Traces the CPU address bus to see how
//  far boot gets.  Build/run: run_full.sh <rom64.hex>
//============================================================================
`timescale 1ns/1ps

module boot_top;
	reg clk = 0, reset = 1;
	always #5 clk = ~clk;              // 100 MHz sim clock

	// ---- quadra950 I/O ----
	wire        DDRAM_CLK, DDRAM_RD, DDRAM_WE;
	wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
	wire [28:0] DDRAM_ADDR;
	wire [63:0] DDRAM_DIN;
	reg  [63:0] DDRAM_DOUT = 0;
	reg         DDRAM_DOUT_READY = 0;
	wire        ce_pix, HBlank, HSync, VBlank, VSync, disk_led;
	wire [7:0]  r, g, b;
	wire [15:0] audio_l, audio_r;
	wire [31:0] sd_lba [2];
	wire [1:0]  sd_rd, sd_wr;
	wire [15:0] sd_buff_din [2];
	wire [7:0]  pram_bk_dout;

	quadra950 dut (
		.clk_sys(clk), .reset(reset), .ram_128mb(1'b0), .vmode(2'd0),
		.ioctl_download(1'b0), .ioctl_index(8'd0), .ioctl_wr(1'b0),
		.ioctl_addr(27'd0), .ioctl_dout(16'd0),
		.img_mounted(2'd0), .img_readonly(1'b0), .img_size(64'd0),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(2'd0),
		.sd_buff_addr(14'd0), .sd_buff_dout(16'd0), .sd_buff_din(sd_buff_din), .sd_buff_wr(1'b0),
		.ps2_key(11'd0), .ps2_mouse(25'd0),
		.pram_bk_addr(8'd0), .pram_bk_wr(1'b0), .pram_bk_din(8'd0), .pram_bk_dout(pram_bk_dout),
		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
		.r(r), .g(g), .b(b), .audio_l(audio_l), .audio_r(audio_r), .disk_led(disk_led)
	);

	// ---- behavioral DDR3 (single beat) ----
	// ROM at MCU ROM_BASE $1000_0000 (128K x 64b); RAM at $0 (1M x 64b = 8MB).
	localparam [28:0] ROM_BASE = 29'h1000_0000;
	reg [63:0] rom_ddr [0:131071];
	reg [63:0] ram_ddr [0:1048575];
	integer i;

	wire        in_rom  = (DDRAM_ADDR >= ROM_BASE) && (DDRAM_ADDR < (ROM_BASE + 29'h10_0000));
	wire [16:0] rom_idx = (DDRAM_ADDR - ROM_BASE) >> 3;
	wire [19:0] ram_idx = DDRAM_ADDR[22:3];

	reg rd_d; reg in_rom_d; reg [16:0] rom_idx_d; reg [19:0] ram_idx_d;
	always @(posedge clk) begin
		DDRAM_DOUT_READY <= 1'b0;
		rd_d <= DDRAM_RD; in_rom_d <= in_rom; rom_idx_d <= rom_idx; ram_idx_d <= ram_idx;
		if (DDRAM_WE) begin
			for (i = 0; i < 8; i = i + 1)
				if (DDRAM_BE[i] && !in_rom) ram_ddr[ram_idx][8*i +: 8] <= DDRAM_DIN[8*i +: 8];
		end
		if (rd_d) begin
			DDRAM_DOUT <= in_rom_d ? rom_ddr[rom_idx_d] : ram_ddr[ram_idx_d];
			DDRAM_DOUT_READY <= 1'b1;
		end
	end

	// ---- progress trace via the CPU address bus (hierarchical) ----
	// dut.cpu_addr / cpu_ts / cpu_rw / cpu_fc are wires inside quadra950.
	integer nfetch = 0, nvbl = 0; reg [31:0] last_pc = 0; reg drew = 0;
	reg ts_d = 0;
	always @(posedge clk) begin
		ts_d <= dut.cpu_ts;
		if (dut.cpu_ts && !ts_d) begin           // new bus cycle
			if (dut.cpu_fc == 3'd6 || dut.cpu_fc == 3'd2) begin
				nfetch = nfetch + 1;
				if (nfetch % 200000 == 0)
					$display("[%0t] fetch#%0d PC=%08x  disk_led=%b vbl=%0d", $time, nfetch, dut.cpu_addr, disk_led, nvbl);
			end
			last_pc <= dut.cpu_addr;
		end
		// video: did it ever draw a non-black pixel during active area?
		if (ce_pix && !HBlank && !VBlank && (r|g|b) != 0 && !drew) begin
			drew <= 1'b1; $display("[%0t] >>> DAFB drew a non-black pixel (r=%02x g=%02x b=%02x) - video active!", $time, r, g, b);
		end
	end
	reg vbl_d = 0;
	always @(posedge clk) begin vbl_d <= VBlank; if (VBlank && !vbl_d) nvbl <= nvbl + 1; end

	initial begin
		$readmemh("rom64.hex", rom_ddr);
		for (i = 0; i < 1048576; i = i + 1) ram_ddr[i] = 0;
		repeat (20) @(posedge clk); #1 reset = 0;
		repeat (40000000) @(posedge clk);
		$display("=== stopped: %0d fetches, last PC=%08x, frames=%0d, drew=%b ===", nfetch, last_pc, nvbl, drew);
		$finish;
	end
endmodule
