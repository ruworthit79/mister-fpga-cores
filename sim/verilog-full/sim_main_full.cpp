// Fast full-system boot harness: drives boot_core's clk from C++ (no --timing).
#include "Vboot_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vboot_core* top = new Vboot_core;

    long cycles = (argc > 1) ? atol(argv[1]) : 200000000L;

    // reset for 20 clocks
    top->reset = 1;
    for (int i = 0; i < 40; i++) { top->clk = !top->clk; top->eval(); }
    top->reset = 0;

    for (long c = 0; c < cycles && !Verilated::gotFinish(); c++) {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }
    top->final();
    printf("=== C++ loop done after %ld cycles (gotFinish=%d) ===\n",
           cycles, Verilated::gotFinish());
    delete top;
    return 0;
}
