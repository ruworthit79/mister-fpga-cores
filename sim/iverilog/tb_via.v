//============================================================================
//  tb_via - Icarus testbench for the 6522 VIA
//    1. Port A output via DDRA/ORA read-back.
//    2. T1 one-shot underflow raises IRQ when enabled; read T1C-L clears it.
//    3. IER masking: a set flag with its enable cleared does not raise IRQ.
//============================================================================
`timescale 1ns/1ps

module tb_via;
	reg        clk = 0, reset = 1, ce = 1;
	reg        sel = 0, rw = 1;
	reg  [3:0] addr = 0;
	reg  [7:0] din = 0;
	wire [7:0] dout;
	wire       irq;
	reg  [7:0] pa_in = 8'h00, pb_in = 8'h00;
	wire [7:0] pa_out, pb_out, pa_dir, pb_dir;
	reg        ca1 = 0, cb1 = 0;

	integer errors = 0;
	reg [7:0] rd;

	via dut (
		.clk(clk), .reset(reset), .ce(ce),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .rw(rw), .irq(irq),
		.pa_in(pa_in), .pa_out(pa_out), .pa_dir(pa_dir),
		.pb_in(pb_in), .pb_out(pb_out), .pb_dir(pb_dir),
		.ca1(ca1), .cb1(cb1)
	);

	always #10 clk = ~clk;

	task vwr(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d;
		@(posedge clk); #1 sel=0; rw=1;
	end
	endtask

	task vrd(input [3:0] a, output [7:0] q);
	begin
		@(posedge clk); #1 sel=1; rw=1; addr=a;
		#1 q = dout;             // combinational read
		@(posedge clk); #1 sel=0;
	end
	endtask

	task chk(input [127:0] name, input [7:0] got, input [7:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %02h exp %02h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %02h", name, got);
	end
	endtask

	integer i;
	initial begin
		repeat (4) @(posedge clk); #1 reset = 0;

		// 1. Port A: all outputs, drive 0x5A
		vwr(4'h3, 8'hFF);        // DDRA = outputs
		vwr(4'h1, 8'h5A);        // ORA
		chk("portA", pa_out, 8'h5A);
		vrd(4'h1, rd); chk("ORA rd", rd, 8'h5A);

		// 2. T1 one-shot -> IRQ
		vwr(4'hE, 8'hC0);        // IER: set T1 (bit7=1, bit6=1)
		vwr(4'h4, 8'h05);        // T1L-L = 5
		vwr(4'h5, 8'h00);        // T1C-H = 0 -> load 0x0005, start
		// run until IRQ or timeout
		i = 0;
		while (irq !== 1'b1 && i < 50) begin @(posedge clk); i = i + 1; end
		chk("T1 irq", {7'd0, irq}, 8'h01);
		vrd(4'hD, rd); chk("IFR T1", rd & 8'h40, 8'h40);
		// read T1C-L clears the T1 flag
		vrd(4'h4, rd);
		@(posedge clk);
		chk("irq cleared", {7'd0, irq}, 8'h00);

		// 3. IER masking: re-trigger T1, but disable its enable first
		vwr(4'hE, 8'h40);        // IER: clear T1 (bit7=0, bit6=1 -> clear)
		vwr(4'h4, 8'h03);
		vwr(4'h5, 8'h00);        // start T1 again
		repeat (12) @(posedge clk);
		vrd(4'hD, rd); chk("IFR T1 set", rd & 8'h40, 8'h40);   // flag set
		chk("irq masked", {7'd0, irq}, 8'h00);                  // but no IRQ

		if (errors == 0) $display("PASS: VIA all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #100000; $display("TIMEOUT"); $finish; end
endmodule
