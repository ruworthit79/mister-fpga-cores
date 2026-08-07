#!/usr/bin/env bash
# Convert the VHDL CPU to Verilog and run the equivalence/boot proof in Icarus.
set -e
cd "$(dirname "$0")"
./convert_cpu.sh
iverilog -g2012 -o tb_cpu_v.vvp cpu_synth.v tb_cpu_v.v
vvp tb_cpu_v.vvp
rm -f tb_cpu_v.vvp
