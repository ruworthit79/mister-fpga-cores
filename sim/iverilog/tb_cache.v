//============================================================================
//  tb_cache - 68040 L1 cache (direct-mapped, write-through) checks:
//    1. read miss -> line fill (4 memory reads), returns the right word
//    2. read hit in the same line -> NO memory traffic
//    3. write-through hit -> memory updated AND cached word updated
//    4. tag change on the same index -> eviction (next read misses)
//    5. bypass when disabled -> every access passes through
//============================================================================
`timescale 1ns/1ps

module tb_cache;
	reg         clk = 0, reset = 1, enable = 1;
	reg         cpu_req = 0, cpu_rw = 1;
	reg  [31:0] cpu_addr = 0, cpu_wdata = 0;
	reg  [3:0]  cpu_be = 4'hF;
	wire [31:0] cpu_rdata;
	wire        cpu_ack;

	wire        mem_req, mem_rw;
	wire [31:0] mem_addr, mem_wdata;
	wire [3:0]  mem_be;
	reg  [31:0] mem_rdata;
	reg         mem_ack = 0;

	integer errors = 0;
	integer mem_reads = 0;      // count memory READ transactions

	cache_040 #(.LINES(4), .LINE_WORDS(4)) dut (
		.clk(clk), .reset(reset), .enable(enable),
		.cpu_req(cpu_req), .cpu_addr(cpu_addr), .cpu_rw(cpu_rw),
		.cpu_wdata(cpu_wdata), .cpu_be(cpu_be), .cpu_rdata(cpu_rdata), .cpu_ack(cpu_ack),
		.mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
		.mem_wdata(mem_wdata), .mem_be(mem_be), .mem_rdata(mem_rdata), .mem_ack(mem_ack)
	);

	always #10 clk = ~clk;

	// ---- backing memory: 1-cycle-latency, 1-cycle-ack model ----
	reg [31:0] mem [0:4095];
	always @(posedge clk) begin
		mem_ack <= 1'b0;
		if (mem_req && !mem_ack) begin
			mem_rdata <= mem[mem_addr[13:2]];
			if (!mem_rw) begin
				if (mem_be[3]) mem[mem_addr[13:2]][31:24] <= mem_wdata[31:24];
				if (mem_be[2]) mem[mem_addr[13:2]][23:16] <= mem_wdata[23:16];
				if (mem_be[1]) mem[mem_addr[13:2]][15:8]  <= mem_wdata[15:8];
				if (mem_be[0]) mem[mem_addr[13:2]][7:0]   <= mem_wdata[7:0];
			end else begin
				mem_reads <= mem_reads + 1;
			end
			mem_ack <= 1'b1;
		end
	end

	task cpu_read(input [31:0] a, output [31:0] q);
	begin
		@(posedge clk); #1 cpu_req=1; cpu_rw=1; cpu_addr=a;
		wait (cpu_ack); #1 q = cpu_rdata;
		@(posedge clk); #1 cpu_req=0;
		@(posedge clk);
	end
	endtask

	task cpu_write(input [31:0] a, input [31:0] d);
	begin
		@(posedge clk); #1 cpu_req=1; cpu_rw=0; cpu_addr=a; cpu_wdata=d; cpu_be=4'hF;
		wait (cpu_ack);
		@(posedge clk); #1 cpu_req=0;
		@(posedge clk);
	end
	endtask

	task chk(input [127:0] nm, input [31:0] got, input [31:0] exp);
	begin
		if (got !== exp) begin $display("FAIL %0s: got %08h exp %08h", nm, got, exp); errors=errors+1; end
		else $display("ok   %0s = %08h", nm, got);
	end
	endtask

	integer i;
	reg [31:0] q;
	integer base_reads;
	initial begin
		for (i = 0; i < 4096; i = i + 1) mem[i] = 32'hA000_0000 + i;

		repeat (4) @(posedge clk); #1 reset = 0; @(posedge clk);

		// 1. read miss at 0x40 -> fill line, mem[0x10]=0xA0000010
		mem_reads = 0;
		cpu_read(32'h0000_0040, q);
		chk("miss data", q, 32'hA000_0010);
		chk("fill reads", mem_reads[31:0], 32'd4);          // whole 16-byte line

		// 2. hit at 0x44 (same line) -> no memory traffic
		base_reads = mem_reads;
		cpu_read(32'h0000_0044, q);
		chk("hit data", q, 32'hA000_0011);
		chk("hit reads", (mem_reads-base_reads), 32'd0);

		// 3. write-through hit at 0x40, then read back (hit)
		cpu_write(32'h0000_0040, 32'h1234_5678);
		chk("wt mem", mem[32'h10], 32'h1234_5678);          // memory updated
		base_reads = mem_reads;
		cpu_read(32'h0000_0040, q);
		chk("wt hit rd", q, 32'h1234_5678);                 // cached word updated
		chk("wt no fill", (mem_reads-base_reads), 32'd0);

		// 4. tag change on same index (0x40 and 0x140 map to index 0) -> evict
		cpu_read(32'h0000_0140, q);                          // miss, fill
		chk("evict new", q, 32'hA000_0050);                 // mem[0x50]
		base_reads = mem_reads;
		cpu_read(32'h0000_0040, q);                          // was evicted -> miss again
		chk("evict old miss", (mem_reads-base_reads), 32'd4);

		// 5. bypass when disabled -> single pass-through read
		enable = 0; @(posedge clk);
		base_reads = mem_reads;
		cpu_read(32'h0000_0200, q);
		chk("byp data", q, 32'hA000_0080);
		chk("byp reads", (mem_reads-base_reads), 32'd1);    // no line fill

		if (errors == 0) $display("PASS: cache all checks passed");
		else             $display("FAILED: %0d error(s)", errors);
		$finish;
	end

	initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
