//============================================================================
//  cache_040 - 68040 L1 cache (direct-mapped, 16-byte lines, write-through)
//
//  A functional model of one of the 68040's on-die 4 KB caches (instantiate
//  twice for the split 4 KB I + 4 KB D configuration). Direct-mapped, 16-byte
//  (4-longword) lines matching the 040's line size, write-through with
//  no-write-allocate. It sits transparently between the CPU and the memory
//  controller: a hit returns in one cycle; a miss does a 4-word line fill from
//  memory (the emulated stand-in for the 040 burst read); writes go through to
//  memory and update the line on a hit.
//
//  `enable` mirrors CACR: when 0 the cache is bypassed (every access is passed
//  straight through). This is a PERFORMANCE/authenticity feature - correctness
//  (and OS 8.1 boot) does not depend on it - so it is provided as a verified
//  standalone block (sim/iverilog/tb_cache.v), ready to insert once the CPU bus
//  grows real burst-fill support. It is not yet wired into the interconnect
//  (documented in docs/TARGET_SPEC.md item 3).
//
//  Memory-side outputs are combinational per state so the line-fill address
//  tracks the fill counter with no pipeline lag. After reset the cache walks the
//  tag array invalidating every line before serving accesses.
//
//  Verified in sim/iverilog/tb_cache.v: read miss->fill, read hit (no memory
//  traffic), write-through, hit-update, line eviction on tag change, and
//  transparent bypass when disabled.
//============================================================================

module cache_040 #(
	parameter LINES      = 256,    // 256 lines x 16 bytes = 4 KB
	parameter LINE_WORDS = 4       // 4 x 32-bit longwords per line (16 bytes)
)(
	input             clk,
	input             reset,
	input             enable,      // CACR cache-enable; 0 = bypass

	// CPU side (single 32-bit access, req/ack)
	input             cpu_req,
	input      [31:0] cpu_addr,
	input             cpu_rw,      // 1 = read, 0 = write
	input      [31:0] cpu_wdata,
	input      [3:0]  cpu_be,
	output reg [31:0] cpu_rdata,
	output reg        cpu_ack,

	// Memory side (to the MCU / backing store)
	output reg        mem_req,
	output reg [31:0] mem_addr,
	output reg        mem_rw,
	output reg [31:0] mem_wdata,
	output reg [3:0]  mem_be,
	input      [31:0] mem_rdata,
	input             mem_ack
);

	localparam IDXW  = $clog2(LINES);
	localparam WORDW = $clog2(LINE_WORDS);
	localparam TAGW  = 32 - (WORDW+2+IDXW);

	// Address breakdown: [1:0] byte, [WORDW+1:2] word-in-line, index, tag.
	wire [WORDW-1:0] a_word = cpu_addr[WORDW+1:2];
	wire [IDXW-1:0]  a_idx  = cpu_addr[WORDW+2 +: IDXW];
	wire [TAGW-1:0]  a_tag  = cpu_addr[31 -: TAGW];

	reg [31:0]     data [0:LINES*LINE_WORDS-1];
	reg [TAGW-1:0] tag  [0:LINES-1];
	reg            valid[0:LINES-1];

	wire hit = valid[a_idx] && (tag[a_idx] == a_tag);

	localparam S_INIT=3'd0, S_IDLE=3'd1, S_FILL=3'd2, S_DONE=3'd3, S_WT=3'd4, S_BYP=3'd5;
	reg [2:0] state;
	reg [WORDW-1:0] fill_cnt;
	reg [IDXW-1:0]  r_idx;
	reg [TAGW-1:0]  r_tag;
	reg [WORDW-1:0] r_word;
	reg [31:0]      r_lbase;
	reg [31:0]      r_addr, r_wdata;
	reg [3:0]       r_be;
	reg             r_rw;
	reg [IDXW:0]    initc;

	// ---- combinational memory-side outputs ----
	always @(*) begin
		mem_req   = 1'b0;
		mem_rw    = 1'b1;
		mem_addr  = r_addr;
		mem_wdata = r_wdata;
		mem_be    = r_be;
		case (state)
			S_FILL: begin mem_req = 1'b1; mem_rw = 1'b1;
			              mem_addr = r_lbase + ({{(30-WORDW){1'b0}}, fill_cnt} << 2); end
			S_WT:   begin mem_req = 1'b1; mem_rw = 1'b0; end
			S_BYP:  begin mem_req = 1'b1; mem_rw = r_rw; end
			default: ;
		endcase
	end

	// byte-enable merge for write-through hit update
	function [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] be);
		merge = { be[3] ? nw[31:24] : old[31:24],
		          be[2] ? nw[23:16] : old[23:16],
		          be[1] ? nw[15:8]  : old[15:8],
		          be[0] ? nw[7:0]   : old[7:0] };
	endfunction

	always @(posedge clk) begin
		if (reset) begin
			cpu_ack <= 1'b0; state <= S_INIT; initc <= 0;
		end else begin
			cpu_ack <= 1'b0;
			case (state)
			S_INIT: begin
				valid[initc[IDXW-1:0]] <= 1'b0;
				if (initc == LINES-1) state <= S_IDLE;
				initc <= initc + 1'b1;
			end

			S_IDLE: if (cpu_req && !cpu_ack) begin
				r_idx   <= a_idx;   r_tag  <= a_tag;   r_word <= a_word;
				r_addr  <= cpu_addr; r_wdata <= cpu_wdata; r_be <= cpu_be; r_rw <= cpu_rw;
				r_lbase <= {cpu_addr[31:WORDW+2], {(WORDW+2){1'b0}}};
				if (!enable) begin
					state <= S_BYP;
				end else if (cpu_rw) begin
					if (hit) begin
						cpu_rdata <= data[{a_idx, a_word}];
						cpu_ack   <= 1'b1;                 // 1-cycle hit
					end else begin
						fill_cnt <= {WORDW{1'b0}};
						state    <= S_FILL;
					end
				end else begin
					// write-through (no-write-allocate); update line only on hit
					if (hit) data[{a_idx, a_word}] <= merge(data[{a_idx, a_word}], cpu_wdata, cpu_be);
					state <= S_WT;
				end
			end

			S_FILL: if (mem_ack) begin
				data[{r_idx, fill_cnt}] <= mem_rdata;
				if (fill_cnt == LINE_WORDS-1) begin
					valid[r_idx] <= 1'b1;
					tag[r_idx]   <= r_tag;
					state        <= S_DONE;
				end else begin
					fill_cnt <= fill_cnt + 1'b1;
				end
			end

			S_DONE: begin                                  // line array settled
				cpu_rdata <= data[{r_idx, r_word}];
				cpu_ack   <= 1'b1;
				state     <= S_IDLE;
			end

			S_WT: if (mem_ack) begin cpu_ack <= 1'b1; state <= S_IDLE; end

			S_BYP: if (mem_ack) begin
				cpu_rdata <= mem_rdata;
				cpu_ack   <= 1'b1;
				state     <= S_IDLE;
			end
			endcase
		end
	end

endmodule
