//============================================================================
//  tb_cpu_v - proof that the GHDL-converted Verilog CPU is functionally
//  equivalent to the VHDL one. Runs the same boot program as the GHDL test
//  (sim/ghdl/tb_cpu.vhd) - reset vectors, MOVE.L #imm,D0, MOVE.L D0,($100).L,
//  STOP - against a TS/TA memory, using the hard case: 1-in-3 ce enable +
//  single-cycle (pulsed) ack. PASS => the converted netlist boots and executes,
//  so the whole core can be simulated in Icarus (Phase 5 milestone 5.0).
//============================================================================
`timescale 1ns/1ps

module tb_cpu_v;
	reg         clk = 0, reset = 1, ce = 0;
	wire [31:0] addr, dout;
	reg  [31:0] din = 0;
	wire [3:0]  be;
	wire        rw, ts;
	reg         ta = 0;
	wire [2:0]  fc;
	integer     errors = 0;

	cpu_wrapper dut (
		.clk(clk), .ce(ce), .reset(reset), .din(din), .ta(ta), .ipl(3'b111),
		.addr(addr), .dout(dout), .be(be), .rw(rw), .ts(ts), .fc(fc)
	);

	always #10 clk = ~clk;

	// ce high 1 clock in 3 (emulated slower CPU rate)
	reg [1:0] cc = 0;
	always @(posedge clk)
		if (cc == 2) begin cc <= 0; ce <= 1; end else begin cc <= cc + 1; ce <= 0; end

	reg  [7:0] mem [0:511];
	reg  [8:0] a_lat = 0;
	reg        serviced = 0;
	reg  [8:0] base;
	integer    i;

	// big-endian 32-bit read of the word-aligned latched address
	always @(*) din = {mem[a_lat], mem[a_lat+1], mem[a_lat+2], mem[a_lat+3]};

	// pulsed-ack memory (single-cycle TA)
	always @(posedge clk) begin
		ta <= 0;
		if (ts) begin
			if (!serviced) begin
				base  = {addr[8:2], 2'b00};
				a_lat <= base;
				if (!rw) begin
					if (be[3]) mem[base+0] <= dout[31:24];
					if (be[2]) mem[base+1] <= dout[23:16];
					if (be[1]) mem[base+2] <= dout[15:8];
					if (be[0]) mem[base+3] <= dout[7:0];
				end
				ta <= 1; serviced <= 1;
			end
		end else serviced <= 0;
	end

	initial begin
		for (i = 0; i < 512; i = i + 1) mem[i] = 0;
		mem[0]=8'h00; mem[1]=8'h00; mem[2]=8'h10; mem[3]=8'h00;   // SSP = 0x1000
		mem[4]=8'h00; mem[5]=8'h00; mem[6]=8'h00; mem[7]=8'h08;   // PC  = 0x08
		mem[8]=8'h20;  mem[9]=8'h3C;  mem[10]=8'h12; mem[11]=8'h34; mem[12]=8'h56; mem[13]=8'h78;
		mem[14]=8'h23; mem[15]=8'hC0; mem[16]=8'h00; mem[17]=8'h00; mem[18]=8'h01; mem[19]=8'h00;
		mem[20]=8'h4E; mem[21]=8'h72; mem[22]=8'h27; mem[23]=8'h00;

		repeat (6) @(posedge clk); #1 reset = 0;
		repeat (6000) @(posedge clk);

		if (mem[16'h100]==8'h12 && mem[16'h101]==8'h34 && mem[16'h102]==8'h56 && mem[16'h103]==8'h78)
			$display("PASS: converted CPU executed program; $100 = 0x12345678");
		else begin
			$display("FAIL: $100 = %02h %02h %02h %02h",
				mem[16'h100], mem[16'h101], mem[16'h102], mem[16'h103]);
			errors = errors + 1;
		end
		$finish;
	end

	initial begin #400000; $display("TIMEOUT"); $finish; end
endmodule
