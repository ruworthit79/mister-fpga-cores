//============================================================================
//  tb_adb - Icarus testbench for ADB PS/2 translation + Talk R0
//    1. PS/2 'A' press -> Talk R0 keyboard returns ADB keycode 0x00, down.
//    2. PS/2 mouse move -> Talk R0 mouse returns button + dx/dy.
//    3. SRQ reflects pending data.
//============================================================================
`timescale 1ns/1ps

module tb_adb;
	reg         clk = 0, reset = 1;
	reg  [10:0] ps2_key = 0;
	reg  [24:0] ps2_mouse = 0;
	reg         cmd_stb = 0;
	reg  [7:0]  cmd = 0;
	wire [15:0] data;
	wire        valid, srq;

	integer errors = 0;

	adb dut (
		.clk(clk), .reset(reset), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
		.cmd_stb(cmd_stb), .cmd(cmd), .data(data), .valid(valid), .srq(srq)
	);

	always #10 clk = ~clk;

	task talk(input [7:0] c);
	begin
		@(posedge clk); #1 cmd = c; cmd_stb = 1;
		@(posedge clk); #1 cmd_stb = 0;
		@(posedge clk);   // response registered
	end
	endtask

	task chk(input [127:0] name, input [15:0] got, input [15:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %04h exp %04h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %04h", name, got);
	end
	endtask

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// 1. keyboard: press 'A' (PS/2 set-2 0x1C), pressed=1, new toggle
		#1 ps2_key = {1'b1, 1'b1, 1'b0, 8'h1C};
		@(posedge clk); @(posedge clk);
		if (!srq) begin $display("FAIL srq not set after key"); errors=errors+1; end
		else $display("ok   srq set");
		talk(8'h2C);                              // Talk R0 keyboard
		chk("kbd valid", {15'd0, valid}, 16'd1);
		chk("kbd r0", data, 16'h00FF);           // {down|keycode0x00, none 0xFF}
		if (srq) begin $display("FAIL srq still set"); errors=errors+1; end
		else $display("ok   srq cleared");

		// 2. mouse: button down, dx=5, dy=3, new toggle
		#1 ps2_mouse = {1'b1, 8'd3, 8'd5, 5'd0, 3'b001};   // {tgl,dy,dx,-,btnL}
		@(posedge clk); @(posedge clk);
		talk(8'h3C);                              // Talk R0 mouse
		chk("mse valid", {15'd0, valid}, 16'd1);
		chk("mse r0", data, 16'h0385);           // {0,dy=3,1,dx=5}

		if (errors == 0) $display("PASS: ADB all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #100000; $display("TIMEOUT"); $finish; end
endmodule
