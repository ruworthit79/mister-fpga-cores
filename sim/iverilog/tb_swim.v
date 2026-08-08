//============================================================================
//  tb_swim - Icarus testbench for the SWIM/IWM floppy controller model.
//    1. IWM Status SENSE reads report an installed, EMPTY drive:
//         !CSTIN (no disk in place) and !DRVIN (drive present).
//    2. IWM -> ISM mode switch via the Q6/Q7 mode-register write (bit 0x40).
//    3. ISM Status reads back the Mode register (ISM + MOTOR bits).
//    4. ISM Handshake reports FIFO empty (no data bytes available).
//    5. ISM Data read returns no data and does not hang.
//    6. ISM Mode0 clearing the ISM bit returns the chip to IWM mode.
//============================================================================
`timescale 1ns/1ps

module tb_swim;
	reg        clk = 0, reset = 1;
	reg        sel = 0, rw = 1;
	reg [3:0]  addr = 0;
	reg [7:0]  din = 0;
	wire [7:0] dout;
	wire       ack, irq;

	integer errors = 0;
	reg [7:0] q;

	swim dut (
		.clk(clk), .reset(reset),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .rw(rw), .ack(ack),
		.irq(irq)
	);

	always #10 clk = ~clk;

	// ---- CPU register access ----
	task swr(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d;
		wait (ack); @(posedge clk); #1 sel=0;
	end
	endtask
	task srd(input [3:0] a, output [7:0] qq);
	begin
		@(posedge clk); #1 sel=1; rw=1; addr=a;
		wait (ack); #1 qq = dout; @(posedge clk); #1 sel=0;
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

		// ------------------------------------------------------------------
		// 1a. IWM: address the !CSTIN status line {CA2,CA1,CA0,SEL}=0001,
		//     read Status. Bit 7 (SENSE) must be 1 => NO disk in place.
		// ------------------------------------------------------------------
		srd(4'h4, q);  // CA2 = 0
		srd(4'h2, q);  // CA1 = 0
		srd(4'h0, q);  // CA0 = 0
		srd(4'hB, q);  // SEL = 1
		srd(4'hE, q);  // Q7  = 0
		srd(4'hD, q);  // Q6  = 1 -> Status
		chk("iwm nodisk sense", {8'd0, q[7]}, 16'd1);   // !CSTIN: no disk

		// ------------------------------------------------------------------
		// 1b. Address the !DRVIN line {CA2,CA1,CA0,SEL}=1110, read Status.
		//     Bit 7 must be 0 => a drive IS installed (empty, but present).
		// ------------------------------------------------------------------
		srd(4'h5, q);  // CA2 = 1
		srd(4'h3, q);  // CA1 = 1
		srd(4'h1, q);  // CA0 = 1
		srd(4'hA, q);  // SEL = 0
		srd(4'hD, q);  // Q6 = 1 -> Status (Q7 already 0)
		chk("iwm drive present", {8'd0, q[7]}, 16'd0);  // !DRVIN: installed

		// ------------------------------------------------------------------
		// 2. IWM -> ISM: Q6 already 1; write Q7-on address with the ISM
		//    enable bit (0x40) set -> the Q6/Q7 mode-register write path.
		// ------------------------------------------------------------------
		swr(4'hF, 8'h40);

		// 3. ISM Status (read reg index 6 -> addr 12) returns the Mode reg.
		srd(4'hC, q);
		chk("ism enabled bit", {8'd0, q[6]}, 16'd1);    // ISM/SWIM bit set
		chk("ism mode reg", {8'd0, q}, 16'h0040);

		// Select drive 1 + motor on: write Mode1 (reg index 7 -> addr 14).
		swr(4'hE, 8'h82);                               // MOTORON | DRIVE1
		srd(4'hC, q);
		chk("ism motor set", {8'd0, q[7]}, 16'd1);      // MOTORON
		chk("ism mode c2", {8'd0, q}, 16'h00C2);        // ISM|MOTOR|DRIVE1

		// ------------------------------------------------------------------
		// 4. ISM Handshake (read reg index 7 -> addr 14): FIFO empty.
		//    Byte-available bits [2:1] must be 0.
		// ------------------------------------------------------------------
		srd(4'hE, q);
		chk("ism fifo empty", {8'd0, q[2:1]}, 16'd0);
		chk("ism handshake", {8'd0, q}, 16'h0070);      // sense|nodisk|motor

		// 5. ISM Data read (reg index 0 -> addr 0): no data, must not hang.
		srd(4'h0, q);
		chk("ism data empty", {8'd0, q}, 16'h0000);

		// ------------------------------------------------------------------
		// 6. ISM Mode0 (write reg index 6 -> addr 12) clearing 0x40 returns
		//    the chip to IWM mode. Re-read the no-disk sense to confirm.
		// ------------------------------------------------------------------
		swr(4'hC, 8'h40);                               // clear ISM bit
		// back in IWM: set !CSTIN address and read Status
		srd(4'h4, q); srd(4'h2, q); srd(4'h0, q); srd(4'hB, q);
		srd(4'hE, q);  // Q7 = 0
		srd(4'hD, q);  // Q6 = 1 -> Status
		chk("back in iwm nodisk", {8'd0, q[7]}, 16'd1);

		if (errors == 0) $display("PASS: SWIM all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
