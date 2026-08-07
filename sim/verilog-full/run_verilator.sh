#!/usr/bin/env bash
# Build and run the Verilator boot harness: the real Quadra 950 ROM executed
# by the GHDL-converted TG68 CPU. Verilator (compiled C++) handles the 1 MB
# ROM + RAM and millions of cycles that Icarus cannot. See PHASE5_SCOPE.md 5.0.
#
# Usage: ./run_verilator.sh <path-to-Quadra_950.ROM> [max_cycles]
set -e
cd "$(dirname "$0")"
ROM="${1:?usage: run_verilator.sh <Quadra_950.ROM> [max_cycles]}"
CYC="${2:-8000000}"

./convert_cpu.sh                      # (re)generate cpu_synth.v from the VHDL CPU
verilator --cc --exe --build -j 0 --top-module cpu_wrapper \
	-Wno-lint -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
	cpu_synth.v sim_main.cpp -o boot_sim
./obj_dir/boot_sim "$ROM" "$CYC"
