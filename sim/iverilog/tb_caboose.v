//============================================================================
//  tb_caboose - Icarus testbench for the RTC/PRAM serial protocol
//    1. Write then read a seconds byte (cmd 0x01 / 0x81).
//    2. Write then read an extended-PRAM byte (cmd 0x38 / 0xB8 + address).
//============================================================================
`timescale 1ns/1ps

module tb_caboose;
	reg  clk = 0, reset = 1, tick_1hz = 0;
	reg  rtc_enb = 1, rtc_clk = 0, rtc_data_in = 0;
	wire rtc_data_out, rtc_data_oe;

	integer errors = 0;
	reg [7:0] q;

	caboose dut (
		.clk(clk), .reset(reset), .tick_1hz(tick_1hz),
		.rtc_enb(rtc_enb), .rtc_clk(rtc_clk), .rtc_data_in(rtc_data_in),
		.rtc_data_out(rtc_data_out), .rtc_data_oe(rtc_data_oe)
	);

	always #10 clk = ~clk;

	// one serial bit: drive data_in, pulse the serial clock, sample data_out
	task sbit(input b, output q1);
	begin
		rtc_data_in = b;
		#1 rtc_clk = 1;
		@(posedge clk); #1 q1 = rtc_data_out;   // valid after the rising edge
		@(posedge clk);
		#1 rtc_clk = 0;
		@(posedge clk);
	end
	endtask

	task send_byte(input [7:0] d);
		integer i; reg t;
	begin
		for (i = 7; i >= 0; i = i - 1) sbit(d[i], t);
	end
	endtask

	task recv_byte(output [7:0] d);
		integer i; reg t;
	begin
		d = 0;
		for (i = 7; i >= 0; i = i - 1) begin sbit(1'b0, t); d[i] = t; end
	end
	endtask

	task start; begin #1 rtc_enb = 0; @(posedge clk); end endtask
	task stop;  begin #1 rtc_enb = 1; @(posedge clk); @(posedge clk); end endtask

	task chk(input [127:0] name, input [7:0] got, input [7:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %02h exp %02h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %02h", name, got);
	end
	endtask

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// 1. seconds byte 0: write 0x78, read back
		start; send_byte(8'h01); send_byte(8'h78); stop;
		start; send_byte(8'h81); recv_byte(q); stop;
		chk("sec0", q, 8'h78);

		// 2. extended PRAM @0x10: write 0xA5, read back
		start; send_byte(8'h38); send_byte(8'h10); send_byte(8'hA5); stop;
		start; send_byte(8'hB8); send_byte(8'h10); recv_byte(q); stop;
		chk("pram10", q, 8'hA5);

		// different address to be sure addressing works
		start; send_byte(8'h38); send_byte(8'h20); send_byte(8'h3C); stop;
		start; send_byte(8'hB8); send_byte(8'h20); recv_byte(q); stop;
		chk("pram20", q, 8'h3C);

		if (errors == 0) $display("PASS: Caboose all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
