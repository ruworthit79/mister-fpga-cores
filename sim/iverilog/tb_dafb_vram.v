//============================================================================
//  tb_dafb_vram - DAFB external-VRAM path (EXT_VRAM=1): CPU writes go to an
//  off-chip VRAM model through the vram_* port, and scanout is fed from the
//  ping-pong line buffer prefetched from that same memory.
//    1. CPU VRAM-aperture writes land in the external memory model.
//    2. 8 bpp scanout via the line buffer -> CLUT-mapped r/g/b.
//    3. 32 bpp direct-colour pixel via the line buffer.
//============================================================================
`timescale 1ns/1ps

module tb_dafb_vram;
	reg         clk = 0, reset = 1;
	reg         sel = 0, rw = 1;
	reg  [23:0] addr = 0;
	reg  [31:0] din = 0;
	reg  [3:0]  be = 4'hF;
	wire [31:0] dout;
	wire        ack;
	wire        ce_pix, HBlank, HSync, VBlank, VSync, vbl_irq;
	wire [7:0]  r, g, b;

	wire        vram_rd, vram_wr;
	wire [22:0] vram_addr;
	wire [31:0] vram_wdata;
	wire [3:0]  vram_wbe;
	reg  [31:0] vram_rdata;
	reg         vram_rvalid = 0;
	reg         vram_ready = 1;

	integer errors = 0;

	localparam VRAM_BASE = 24'h80_0000;
	localparam CLUT_BASE = 24'h10_0000;
	localparam REG_BASE  = 24'h00_0000;
	reg [1:0] vmode = 0;

	dafb #(.VRAM_WORDS(256), .TESTTIMING(1), .EXT_VRAM(1),
	       .H_ACT(8), .H_FP(8), .H_SY(2), .H_BP(8),
	       .V_ACT(4), .V_FP(2), .V_SY(2), .V_BP(4)) dut (
		.clk(clk), .reset(reset), .vmode(vmode),
		.sel(sel), .addr(addr), .din(din), .dout(dout), .be(be), .rw(rw), .ack(ack),
		.ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
		.r(r), .g(g), .b(b), .vbl_irq(vbl_irq),
		.vram_rd(vram_rd), .vram_wr(vram_wr), .vram_addr(vram_addr),
		.vram_wdata(vram_wdata), .vram_wbe(vram_wbe),
		.vram_rdata(vram_rdata), .vram_rvalid(vram_rvalid), .vram_ready(vram_ready)
	);

	always #10 clk = ~clk;

	// ---- behavioural external VRAM: 1-cycle read latency, byte-enabled write ----
	reg [31:0] vmem [0:16383];
	always @(posedge clk) begin
		vram_rvalid <= 1'b0;
		if (vram_rd) begin
			vram_rdata  <= vmem[vram_addr[15:2]];
			vram_rvalid <= 1'b1;                 // valid the following cycle
		end
		if (vram_wr) begin
			if (vram_wbe[3]) vmem[vram_addr[15:2]][31:24] <= vram_wdata[31:24];
			if (vram_wbe[2]) vmem[vram_addr[15:2]][23:16] <= vram_wdata[23:16];
			if (vram_wbe[1]) vmem[vram_addr[15:2]][15:8]  <= vram_wdata[15:8];
			if (vram_wbe[0]) vmem[vram_addr[15:2]][7:0]   <= vram_wdata[7:0];
		end
	end

	task cwr(input [23:0] a, input [31:0] d);
	begin
		@(posedge clk); #1 sel=1; rw=0; addr=a; din=d; be=4'hF;
		wait (ack); @(posedge clk); #1 sel=0; rw=1;
		@(posedge clk);
	end
	endtask

	task chk(input [127:0] name, input [31:0] got, input [31:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %08h exp %08h", name, got, exp); errors=errors+1; end
		else $display("ok   %0s = %08h", name, got);
	end
	endtask

	task step_pix; begin @(posedge clk); while (!ce_pix) @(posedge clk); end endtask

	reg [23:0] pix [0:3];
	integer n2;
	task capture;
	begin : collect
		reg seen_nonzero, started;
		pix[0]=~0; pix[1]=~0; pix[2]=~0; pix[3]=~0;
		seen_nonzero = 0; started = 0;
		for (n2 = 0; n2 < 20000; n2 = n2 + 1) begin
			step_pix;
			if (dut.s2_y != 0) begin
				if (started) disable collect;
				seen_nonzero = 1;
			end else if (seen_nonzero) begin
				started = 1;
				if (!HBlank && !VBlank && dut.s2_x < 4)
					pix[dut.s2_x] = {r, g, b};
			end
		end
	end
	endtask

	initial begin
		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// disable video during setup so prefetch doesn't race the CPU writes
		cwr(REG_BASE + 24'h00, 32'h0);

		// ---- 1. CPU VRAM writes -> external memory ----
		cwr(VRAM_BASE + 24'd0, 32'h01020304);
		cwr(VRAM_BASE + 24'd4, 32'h05060708);
		chk("vmem w0", vmem[0], 32'h01020304);
		chk("vmem w1", vmem[1], 32'h05060708);

		// ---- 2. 8bpp scanout through the line buffer ----
		cwr(CLUT_BASE + 1*4, 32'h00_FF0000);
		cwr(CLUT_BASE + 2*4, 32'h00_00FF00);
		cwr(CLUT_BASE + 3*4, 32'h00_0000FF);
		cwr(CLUT_BASE + 4*4, 32'h00_112233);
		cwr(REG_BASE + 24'h08, 32'd8);      // stride
		cwr(REG_BASE + 24'h04, 32'd0);      // base
		cwr(REG_BASE + 24'h0C, 32'd0);      // depth 8bpp
		cwr(REG_BASE + 24'h00, 32'h1);      // enable
		capture;
		chk("8 pix0", {8'd0, pix[0]}, 32'h00FF0000);
		chk("8 pix1", {8'd0, pix[1]}, 32'h0000FF00);
		chk("8 pix2", {8'd0, pix[2]}, 32'h000000FF);
		chk("8 pix3", {8'd0, pix[3]}, 32'h00112233);

		// ---- 3. 32bpp direct-colour pixel ----
		cwr(REG_BASE + 24'h00, 32'h0);      // disable during reconfigure
		cwr(VRAM_BASE + 24'd0, 32'h0011_2233);
		cwr(VRAM_BASE + 24'd4, 32'h0044_5566);
		cwr(REG_BASE + 24'h08, 32'd32);     // stride
		cwr(REG_BASE + 24'h0C, 32'd2);      // depth 32bpp
		cwr(REG_BASE + 24'h00, 32'h1);      // enable
		capture;
		chk("32 pix0", {8'd0, pix[0]}, 32'h00112233);
		chk("32 pix1", {8'd0, pix[1]}, 32'h00445566);

		if (errors == 0) $display("PASS: DAFB vram all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #2000000; $display("TIMEOUT"); $finish; end
endmodule
