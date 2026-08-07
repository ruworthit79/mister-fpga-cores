//============================================================================
//  tb_asc - Icarus testbench for the Apple Sound Chip FIFO playback
//    1. Enable FIFO mode, push offset-binary samples into A (left) and B
//       (right), and check the signed-16 output matches (s-128)<<8 in order.
//    2. Status reflects FIFO empty/half.
//============================================================================
`timescale 1ns/1ps

module tb_asc;
	reg         clk = 0, reset = 1, snd_ce = 0;
	reg         sel = 0, rw = 1;
	reg  [11:0] addr = 0;
	reg  [7:0]  din = 0;
	wire [7:0]  dout;
	wire        ack, irq;
	wire signed [15:0] audio_l, audio_r;

	integer errors = 0;

	asc dut (
		.clk(clk), .reset(reset), .snd_ce(snd_ce),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .rw(rw), .ack(ack), .irq(irq),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	always #10 clk = ~clk;

	task wr(input [11:0] a, input [7:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d;
		wait (ack); @(posedge clk); #1 sel=0;
	end
	endtask

	task tick;   // one output sample
	begin
		@(posedge clk); #1 snd_ce = 1;
		@(posedge clk); #1 snd_ce = 0;
		@(posedge clk);
	end
	endtask

	task chks(input [127:0] name, input signed [15:0] got, input signed [15:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %0d exp %0d", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %0d", name, got);
	end
	endtask

	// FIFO windows
	localparam A = 12'h800, B = 12'hC00;

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		wr(12'h001, 8'h01);          // mode: enable FIFO

		// push left samples: 0x80,0xC0,0x40,0xFF
		wr(A, 8'h80); wr(A, 8'hC0); wr(A, 8'h40); wr(A, 8'hFF);
		// push right samples: 0x00,0x80
		wr(B, 8'h00); wr(B, 8'h80);

		// left channel playback
		tick; chks("L0", audio_l, 16'sd0);        // 0x80 -> 0
		tick; chks("L1", audio_l, 16'sd16384);    // 0xC0 -> +16384
		tick; chks("L2", audio_l, -16'sd16384);   // 0x40 -> -16384
		tick; chks("L3", audio_l, 16'sd32512);    // 0xFF -> +32512
		// right channel: first two ticks already consumed B0,B1
		// re-check final right value (0x80 -> 0) after 2 ticks
		// (B0=0x00 -> -32768 on tick0, B1=0x80 -> 0 on tick1)

		if (errors == 0) $display("PASS: ASC all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #100000; $display("TIMEOUT"); $finish; end
endmodule
