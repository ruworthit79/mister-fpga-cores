//============================================================================
//  tb_boot - full-system boot attempt: the real Quadra 950 ROM executed by the
//  GHDL-converted TG68 CPU in Icarus (Phase 5 milestone 5.0).
//
//  This is a bring-up harness, not a passing test: it presents a simplified
//  Mac memory map (ROM + reset overlay + a RAM window; I/O reads as 0) to the
//  converted CPU and traces how far the firmware executes. It does NOT boot to
//  the desktop - that needs the real peripherals (VIA/RTC/SCSI/DAFB) modelled
//  in the loop and a faithful memory map. It is the scaffold that milestone 5.0
//  and Level-A bring-up build on.
//
//  Supply the ROM (copyrighted; not in this repo) as a hex byte-per-line file:
//     python3 -c "import sys;d=open(sys.argv[1],'rb').read();
//       open('rom.hex','w').write('\n'.join('%02x'%b for b in d))" Quadra_950.ROM
//     iverilog -g2012 -o boot.vvp cpu_synth.v tb_boot.v && vvp boot.vvp +ROM=rom.hex
//
//  TOOLING NOTE: Icarus handles the CONVERTED CPU fine for short tests
//  (sim/verilog-full/tb_cpu_v passes), but it does NOT scale to a full ROM
//  boot: it chokes compiling/elaborating the ~35k-line netlist together with a
//  1 MB memory (iverilog is slow with large arrays; even 32-bit-word packing
//  didn't help). Run this boot harness under **Verilator** (compiled C++ sim,
//  which handles big memories and millions of cycles) instead of Icarus. The
//  module is written to be simulator-agnostic; only the runner differs.
//============================================================================
`timescale 1ns/1ps

module tb_boot;
	reg         clk = 0, reset = 1, ce = 1;
	wire [31:0] addr, dout;
	reg  [31:0] din = 0;
	wire [3:0]  be;
	wire        rw, ts;
	reg         ta = 0;
	wire [2:0]  fc;

	cpu_wrapper dut (
		.clk(clk), .ce(ce), .reset(reset), .din(din), .ta(ta), .ipl(3'b111),
		.addr(addr), .dout(dout), .be(be), .rw(rw), .ts(ts), .fc(fc)
	);
	always #10 clk = ~clk;

	reg [7:0] rom [0:1048575];       // 1 MB ROM
	reg [7:0] ram [0:8388607];       // 8 MB RAM window
	reg       overlay = 1;
	integer   i;

	wire        is_rom  = (addr[31:24] == 8'h40);
	wire        is_low  = (addr[31:28] == 4'h0);
	wire        use_rom = is_rom || (overlay && is_low);
	wire [19:0] ro = addr[19:0];
	wire [22:0] ra = addr[22:0];

	always @(*) begin
		if      (use_rom) din = {rom[ro],  rom[ro+1],  rom[ro+2],  rom[ro+3]};
		else if (is_low)  din = {ram[ra],  ram[ra+1],  ram[ra+2],  ram[ra+3]};
		else              din = 32'h0000_0000;      // I/O etc. read as 0
	end

	reg        serviced = 0;
	integer    nacc = 0, nio = 0;
	reg        seen_via = 0;
	reg [8:0]  s;
	reg [255:0] romfile;

	always @(posedge clk) begin
		ta <= 0;
		if (ts) begin
			if (!serviced) begin
				if (is_rom) overlay <= 0;            // MCU clears overlay on $40 access
				if (is_low && !overlay && !rw) begin // RAM write, byte enables
					if (be[3]) ram[{ra[22:2],2'b00}+0] <= dout[31:24];
					if (be[2]) ram[{ra[22:2],2'b00}+1] <= dout[23:16];
					if (be[1]) ram[{ra[22:2],2'b00}+2] <= dout[15:8];
					if (be[0]) ram[{ra[22:2],2'b00}+3] <= dout[7:0];
				end
				if (nacc < 60 || (nacc % 20000 == 0))
					$display("[%8t] acc#%0d addr=%08h rw=%b fc=%b %s",
						$time, nacc, addr, rw, fc, use_rom?"ROM":(is_low?"RAM":"IO"));
				if (addr[31:24] == 8'h50) begin
					nio <= nio + 1;
					if (addr[23:16] == 8'hF0 && !seen_via) begin
						seen_via <= 1;
						$display(">>> VIA access at %08h (t=%0t) - hardware init reached", addr, $time);
					end
				end
				nacc <= nacc + 1;
				ta <= 1; serviced <= 1;
			end
		end else serviced <= 0;
	end

	initial begin
		if (!$value$plusargs("ROM=%s", romfile)) begin
			$display("ERROR: pass +ROM=<rom.hex>"); $finish;
		end
		$readmemh(romfile, rom);
		for (i = 0; i < 8388608; i = i + 1) ram[i] = 0;
		repeat (8) @(posedge clk); #1 reset = 0;
		repeat (300000) @(posedge clk);
		$display("=== stopped: %0d bus accesses, %0d I/O, VIA reached=%b, overlay=%b ===",
			nacc, nio, seen_via, overlay);
		$finish;
	end
	initial begin #60000000; $display("TIMEOUT"); $finish; end
endmodule
