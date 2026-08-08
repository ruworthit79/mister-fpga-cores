//============================================================================
//  tb_sonic - Icarus testbench for the DP83932 "SONIC" register-level model
//    1. Silicon Revision reads back a plausible constant.
//    2. CR.RST software reset clears interrupt state.
//    3. DCR/RCR/TCR/IMR write/readback.
//    4. ISR write-1-to-clear.
//    5. TXP -> TXDN posted in ISR -> irq raised (unmasked) -> ISR clear -> irq
//       drops, and TXP self-clears in the CR readback.
//============================================================================
`timescale 1ns/1ps

module tb_sonic;
	reg         clk = 0, reset = 1;
	reg         sel = 0, rw = 1;
	reg  [5:0]  addr = 0;
	reg  [15:0] din = 0;
	wire [15:0] dout;
	wire        ack, irq;

	integer errors = 0;
	reg [15:0] q;

	sonic dut (
		.clk(clk), .reset(reset),
		.sel(sel), .addr(addr), .din(din), .dout(dout),
		.rw(rw), .ack(ack), .irq(irq)
	);

	always #10 clk = ~clk;

	// ---- register indices ----
	localparam CR=6'h00, DCR=6'h01, RCR=6'h02, TCR=6'h03,
	           IMR=6'h04, ISR=6'h05, SR=6'h28;

	// ---- CPU register access ----
	task swr(input [5:0] a, input [15:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d;
		wait (ack); @(posedge clk); #1 sel=0;
	end
	endtask

	task srd(input [5:0] a, output [15:0] qq);
	begin
		@(posedge clk); #1 sel=1; rw=1; addr=a;
		wait (ack); #1 qq = dout; @(posedge clk); #1 sel=0;
	end
	endtask

	task chk(input [127:0] name, input [15:0] got, input [15:0] exp);
	begin
		if (got !== exp) begin
			$display("FAIL %0s: got %04h exp %04h", name, got, exp);
			errors = errors + 1;
		end else $display("ok   %0s = %04h", name, got);
	end
	endtask

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// ---- 1. Silicon Revision (read-only constant) ----
		srd(SR, q); chk("SR", q, 16'h0006);

		// ---- 2. config register write/readback ----
		swr(DCR, 16'hABCD); srd(DCR, q); chk("DCR", q, 16'hABCD);
		swr(RCR, 16'h1234); srd(RCR, q); chk("RCR", q, 16'h1234);
		swr(TCR, 16'h5A5A); srd(TCR, q); chk("TCR", q, 16'h5A5A);
		swr(IMR, 16'h0000); srd(IMR, q); chk("IMR", q, 16'h0000);

		// ---- 3. ISR write-1-to-clear ----
		// Post a couple of status bits via a masked-off transmit, then clear one.
		swr(CR, 16'h0002);                 // TXP -> sets ISR.TXDN (bit5)
		srd(ISR, q); chk("ISR after TXP", q, 16'h0020);
		if (irq !== 1'b0) begin
			$display("FAIL irq should be masked off"); errors=errors+1;
		end else $display("ok   irq masked = 0");
		swr(ISR, 16'h0020);                // W1C: clear TXDN
		srd(ISR, q); chk("ISR after W1C", q, 16'h0000);

		// ---- 4. software reset via CR.RST clears interrupt state ----
		swr(CR, 16'h0002);                 // TXP -> ISR.TXDN again
		srd(ISR, q); chk("ISR pre-RST", q, 16'h0020);
		swr(CR, 16'h0040);                 // CR.RST (bit6)
		srd(ISR, q); chk("ISR post-RST", q, 16'h0000);
		swr(CR, 16'h0000);                 // clear RST (host releases reset)

		// ---- 5. TXP -> TXDN -> irq (unmasked) -> ISR clear -> irq drops ----
		swr(IMR, 16'h0020);                // unmask TXDN
		swr(TCR, 16'h0000);                // clear TCR so we can see PTX get set
		swr(CR, 16'h0002);                 // TXP
		// irq should be asserted now that TXDN is unmasked
		@(posedge clk);
		if (irq !== 1'b1) begin
			$display("FAIL irq should be asserted after unmasked TXDN");
			errors=errors+1;
		end else $display("ok   irq asserted = 1");
		srd(ISR, q); chk("ISR TXDN", q, 16'h0020);
		srd(TCR, q); chk("TCR PTX", q, 16'h0001);   // packet transmitted OK
		srd(CR, q);  chk("CR TXP self-clear", q[1:1], 1'b0);
		swr(ISR, 16'h0020);                // clear TXDN
		@(posedge clk);
		if (irq !== 1'b0) begin
			$display("FAIL irq should drop after ISR clear"); errors=errors+1;
		end else $display("ok   irq cleared = 0");

		if (errors == 0) $display("PASS: SONIC all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
