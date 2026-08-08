//============================================================================
//  boot_core - full-system boot harness as a clock-INPUT module (no # delays)
//  so Verilator can build it WITHOUT --timing (event-driven), which is ~10-100x
//  faster than the --timing boot_top. clk/reset are driven from sim_main_full.cpp.
//  Same DDR3+ROM model and CPU-address trace as boot_top.v.
//============================================================================
`timescale 1ns/1ps
module boot_core(input clk, input reset);

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

	localparam [28:0] ROM_BASE = 29'h1000_0000;
	reg [63:0] rom_ddr [0:131071];
	reg [63:0] ram_ddr [0:1048575];
	integer i;
	initial begin
		$readmemh("rom64.hex", rom_ddr);
		for (i = 0; i < 1048576; i = i + 1) ram_ddr[i] = 0;
	end

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

	// ---- progress trace ----
	integer nfetch = 0; reg [31:0] last_pc = 0; reg [31:0] max_pc = 0;
	reg ts_d = 0; integer stall = 0; integer nberr = 0; integer niolog = 0;
	reg drew = 0;
	// plateau detector: how many fetches since max_pc last advanced
	integer since_adv = 0; reg plateau_dumped = 0;
	// track the loop window (min/max PC seen since the last plateau reset)
	reg [31:0] win_lo = 32'hFFFF_FFFF, win_hi = 0;
	// VIA1 timer2 expiry counter (did the timer ever fire?)
	integer t2_fires = 0; reg t2act_d = 0;
	// PC ring buffer to capture the control flow INTO the serial monitor
	reg [31:0] ring [0:255]; integer rptr = 0; reg entered_mon = 0; integer k;
	integer npre = 0;
	always @(posedge clk) begin
		ts_d <= dut.cpu_ts;
		if (dut.cpu_ts && !dut.cpu_ta && !dut.cpu_berr) begin
			stall = stall + 1;
			if (stall == 4000) begin
				$display(">>> BUS STALL addr=%08x rw=%b fc=%b (no TA)", dut.cpu_addr, dut.cpu_rw, dut.cpu_fc);
				$finish;
			end
		end else stall = 0;

		// count VIA1 Timer2 expiries (t2_active 1->0 with ifr[5] set)
		t2act_d <= dut.iobus.via1.t2_active;
		if (t2act_d && !dut.iobus.via1.t2_active) begin
			t2_fires = t2_fires + 1;
			if (t2_fires <= 20)
				$display("VIA1 T2 EXPIRED #%0d (ifr=%02x ier=%02x) fetch#%0d",
					t2_fires, dut.iobus.via1.ifr, dut.iobus.via1.ier, nfetch);
		end

		if (dut.cpu_ts && !ts_d) begin
			if (dut.cpu_fc == 3'd6 || dut.cpu_fc == 3'd2) begin
				nfetch = nfetch + 1;
				if (nfetch % 500000 == 0)
					$display("fetch#%0d PC=%08x", nfetch, dut.cpu_addr);
				// push fetch PCs into the ring but EXCLUDE the STM region (0x4a700-0x4afff),
				// the VIA2-probe (0x47180-0x47280) and the high-ROM diagnostic sweep
				// (0x40880000-0x408fffff), so the 256-entry history holds the normal-boot
				// code that CALLS the STM entry routine ($4A7D4) rather than those loops.
				if (!((dut.cpu_addr >= 32'h4084_a700 && dut.cpu_addr <= 32'h4084_afff) ||
				      (dut.cpu_addr >= 32'h4084_7180 && dut.cpu_addr <= 32'h4084_7280) ||
				      (dut.cpu_addr >= 32'h4088_0000 && dut.cpu_addr <= 32'h408f_ffff))) begin
					ring[rptr] = dut.cpu_addr; rptr = (rptr + 1) & 255;
				end
				// first time PC reaches the STM ENTRY routine ($4A7D4), dump the caller path
				if (!entered_mon && dut.cpu_addr >= 32'h4084_a7d4 &&
				    dut.cpu_addr <= 32'h4084_a7ee) begin
					entered_mon <= 1'b1;
					$display(">>> ENTER STM at PC=%08x fetch#%0d; last 256 DISTINCT PCs:",
						dut.cpu_addr, nfetch);
					$display(">>> VIA2: ddra=%02x ora=%02x ddrb=%02x orb=%02x pb_in=%02x pb_read=%02x pa_read=%02x",
						dut.iobus.via2.ddra, dut.iobus.via2.ora, dut.iobus.via2.ddrb,
						dut.iobus.via2.orb, dut.iobus.via2_pb_in, dut.iobus.via2.pb_read,
						dut.iobus.via2.pa_read);
					for (k = 0; k < 256; k = k + 1)
						$display("   [%0d] %08x", k, ring[(rptr + k) & 255]);
				end
			end
			// report when the PC advances into a NEW higher region (boot moving on)
			if (dut.cpu_addr > max_pc && dut.cpu_addr < 32'h5000_0000) begin
				if (dut.cpu_addr[31:12] != max_pc[31:12])
					$display("NEWPC %08x (fetch#%0d)", dut.cpu_addr, nfetch);
				max_pc <= dut.cpu_addr;
				since_adv = 0; win_lo <= 32'hFFFF_FFFF; win_hi <= 0;
			end else if (dut.cpu_fc == 3'd6 || dut.cpu_fc == 3'd2) begin
				since_adv = since_adv + 1;
			end
			// track the confinement window of ROM-space fetches
			if (dut.cpu_addr < 32'h5000_0000) begin
				if (dut.cpu_addr < win_lo) win_lo <= dut.cpu_addr;
				if (dut.cpu_addr > win_hi) win_hi <= dut.cpu_addr;
			end
			// plateau: max_pc hasn't advanced in a long time -> we're stuck in a loop
			if (since_adv == 3000000 && !plateau_dumped) begin
				plateau_dumped <= 1'b1;
				$display(">>> PLATEAU: no new max PC for 3M fetches; loop window [%08x..%08x] max_pc=%08x",
					win_lo, win_hi, max_pc);
				$display(">>> VIA1: ifr=%02x ier=%02x t2c=%04x t2_active=%b t1c=%04x t1_active=%b acr=%02x  T2fires=%0d",
					dut.iobus.via1.ifr, dut.iobus.via1.ier, dut.iobus.via1.t2c,
					dut.iobus.via1.t2_active, dut.iobus.via1.t1c, dut.iobus.via1.t1_active,
					dut.iobus.via1.acr, t2_fires);
				niolog = 0;   // re-enable the I/O log to capture what the loop touches now
			end
			if (dut.cpu_berr) begin nberr = nberr + 1;
				if (nberr < 40) $display("BERR addr=%08x", dut.cpu_addr); end
			last_pc <= dut.cpu_addr;
		end
		// log I/O accesses AT COMPLETION (ta) to see the value the CPU latches
		if (dut.cpu_ts && dut.cpu_ta && plateau_dumped && niolog < 40 &&
		    dut.cpu_addr[31:28] == 4'h5 && (dut.cpu_fc == 3'd1 || dut.cpu_fc == 3'd5)) begin
			$display("IO %s addr=%08x din=%08x dout=%08x", dut.cpu_rw?"RD":"WR",
				dut.cpu_addr, dut.cpu_din, dut.cpu_dout);
			niolog <= niolog + 1;
		end
		// PRE-MONITOR probe window: log ALL data-space I/O (any address) right
		// before monitor entry, to find the probed device base (may be NuBus/slot
		// or DAFB space, not $5x). Entry was at ~f#2649433.
		if (dut.cpu_ts && dut.cpu_ta && !entered_mon && nfetch > 2646000 && npre < 250 &&
		    (dut.cpu_fc == 3'd1 || dut.cpu_fc == 3'd5)) begin
			$display("PRE %s addr=%08x din=%08x dout=%08x f#%0d", dut.cpu_rw?"RD":"WR",
				dut.cpu_addr, dut.cpu_din, dut.cpu_dout, nfetch);
			npre <= npre + 1;
		end
		if (ce_pix && !HBlank && !VBlank && (r|g|b) != 0 && !drew) begin
			drew <= 1'b1; $display(">>> DAFB drew a non-black pixel (r=%02x g=%02x b=%02x)!", r, g, b);
		end
	end

	// summary hook, called from C++ at the end
	task report_summary;
		$display("=== SUMMARY: %0d fetches, last PC=%08x, max PC=%08x, berr=%0d, drew=%b ===",
			nfetch, last_pc, max_pc, nberr, drew);
	endtask
endmodule
