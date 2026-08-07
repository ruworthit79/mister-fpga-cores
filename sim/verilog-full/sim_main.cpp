//============================================================================
//  sim_main.cpp - Verilator boot harness for the GHDL-converted TG68 CPU.
//
//  Executes the real Quadra 950 ROM through the converted core, presenting a
//  simplified Mac memory map (ROM + reset overlay + a RAM window; I/O reads 0)
//  in C++ - so there is no HDL large-array limit and boot runs at compiled
//  speed. Traces bus activity and, importantly, flags exception-vector fetches
//  so we can see where a 68020-class core diverges on 68040 firmware.
//
//  Build (see run_verilator.sh):
//     verilator --cc --exe --build --top-module cpu_wrapper \
//       -Wno-lint -Wno-UNOPTFLAT cpu_synth.v sim_main.cpp -o boot_sim
//  Run:
//     ./obj_dir/boot_sim <path-to-Quadra_950.ROM> [max_cycles]
//
//  The ROM (copyrighted) is read from the path given; it is never committed.
//============================================================================
#include "Vcpu_wrapper.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint8_t  rom[0x100000];              // 1 MB
static std::vector<uint8_t> ram;            // RAM window
static const uint32_t RAM_SIZE = 0x1000000; // 16 MB
static bool overlay = true;

static inline uint32_t be32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

static const char* vec_name(uint32_t v) {
    switch (v) {
        case 2:  return "BUS ERROR";
        case 3:  return "ADDRESS ERROR";
        case 4:  return "ILLEGAL INSTRUCTION";
        case 5:  return "ZERO DIVIDE";
        case 6:  return "CHK";
        case 7:  return "TRAPV";
        case 8:  return "PRIVILEGE VIOLATION";
        case 9:  return "TRACE";
        case 10: return "LINE-A (Axxx)";
        case 11: return "LINE-F (Fxxx: FPU/MMU/MOVE16/cache - 040 instr!)";
        default: return "";
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* rompath = (argc > 1) ? argv[1] : "rom.bin";
    long maxcyc = (argc > 2) ? atol(argv[2]) : 20000000L;

    FILE* f = fopen(rompath, "rb");
    if (!f) { fprintf(stderr, "cannot open ROM %s\n", rompath); return 1; }
    size_t n = fread(rom, 1, sizeof(rom), f); fclose(f);
    fprintf(stderr, "loaded ROM %s (%zu bytes)\n", rompath, n);
    ram.assign(RAM_SIZE, 0);

    Vcpu_wrapper* dut = new Vcpu_wrapper;
    dut->clk = 0; dut->ce = 1; dut->reset = 1; dut->ipl = 7; dut->ta = 0; dut->din = 0;

    bool serviced = false;
    long nacc = 0, nio = 0, nexc = 0;
    bool seen_via = false;
    uint32_t last_vec = 0xFFFFFFFF; long same_vec = 0;

    auto memread = [&](uint32_t a) -> uint32_t {
        bool is_rom = ((a >> 24) == 0x40);
        bool is_low = ((a >> 28) == 0x0);
        uint32_t al = a & ~3u;
        if (is_rom || (overlay && is_low)) return be32(&rom[al & 0xFFFFF]);
        if (is_low)                        return be32(&ram[al & (RAM_SIZE - 1)]);
        return 0;   // I/O and everything else
    };

    for (long c = 0; c < maxcyc; c++) {
        if (c == 8) dut->reset = 0;

        // rising edge: CPU advances
        dut->clk = 1; dut->eval();

        // synchronous memory reacts to the CPU's TS (mirrors the HDL testbench)
        uint32_t a = dut->addr;
        bool is_rom = ((a >> 24) == 0x40);
        bool is_low = ((a >> 28) == 0x0);
        dut->ta = 0;
        if (dut->ts) {
            if (!serviced) {
                if (is_rom) overlay = false;                 // overlay clears on $40 access
                if (is_low && !overlay && !dut->rw) {         // RAM write, byte enables
                    uint32_t al = a & ~3u & (RAM_SIZE - 1);
                    uint8_t be = dut->be, d0=dut->dout>>24, d1=dut->dout>>16, d2=dut->dout>>8, d3=dut->dout;
                    if (be & 8) ram[al+0] = d0;
                    if (be & 4) ram[al+1] = d1;
                    if (be & 2) ram[al+2] = d2;
                    if (be & 1) ram[al+3] = d3;
                }
                // real exception-vector read: DATA cycle (fc=5 supervisor data),
                // NOT an instruction fetch (fc=6). VBR=0 early -> vectors at $8..$3FF.
                if (dut->rw && dut->fc == 5 && a >= 0x08 && a < 0x400) {
                    uint32_t v = a >> 2;
                    if (v >= 2 && v <= 63) {
                        const char* nm = vec_name(v);
                        nexc++;
                        fprintf(stderr, "[c=%ld] EXCEPTION vector %u (%s) read @%08x\n",
                                c, v, nm[0]?nm:"(user/irq)", a);
                        if (v == last_vec) { if (++same_vec == 30) { fprintf(stderr, ">>> looping on vector %u; stopping\n", v); break; } }
                        else { last_vec = v; same_vec = 0; }
                    }
                }
                // progress: report the current fetch PC periodically
                if (dut->fc == 6 && (nacc % 100000 == 0))
                    fprintf(stderr, "[c=%ld acc=%ld] fetch PC~%08x  (I/O so far=%ld)\n", c, nacc, a, nio);
                if (a >= 0x50000000 && a < 0x51000000) {
                    nio++;
                    if (((a >> 16) & 0xFF) == 0xF0 && !seen_via) {
                        seen_via = true;
                        fprintf(stderr, "[c=%ld] >>> VIA access @%08x - hardware init reached\n", c, a);
                    }
                }
                if (nacc < 40) fprintf(stderr, "[c=%ld] acc#%ld addr=%08x rw=%d fc=%d %s\n",
                    c, nacc, a, dut->rw, dut->fc, (is_rom||(overlay&&is_low))?"ROM":(is_low?"RAM":"IO"));
                nacc++;
                dut->ta = 1; serviced = true;
            }
        } else serviced = false;

        // combinational read data from the addressed source
        dut->din = memread(dut->addr);
        dut->eval();

        // falling edge
        dut->clk = 0; dut->eval();
    }

    fprintf(stderr, "=== done: %ld accesses, %ld I/O, %ld exception fetches, VIA=%d, overlay=%d ===\n",
            nacc, nio, nexc, seen_via, !overlay);
    delete dut;
    return 0;
}
