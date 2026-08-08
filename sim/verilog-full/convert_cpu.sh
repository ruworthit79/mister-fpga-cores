#!/usr/bin/env bash
# Convert the VHDL CPU (TG68 kernel + ALU + Pack + cpu_wrapper) to a Verilog
# netlist using GHDL's synthesis backend, so the WHOLE core (CPU + the Verilog
# peripherals) can be simulated together in Icarus - no mixed-language
# simulator (ModelSim/Questa) required. This is the enabler for Phase 5
# milestone 5.0 (full-system sim / booting the real ROM). See PHASE5_SCOPE.md.
set -e
cd "$(dirname "$0")"
RTL=../../rtl/cpu
OUT=cpu_synth.v      # generated build artifact (git-ignored)

ghdl synth --std=08 -fsynopsys --out=verilog \
	$RTL/tg68k/TG68K_Pack.vhd \
	$RTL/tg68k/TG68K_ALU.vhd \
	$RTL/tg68k/TG68KdotC_Kernel.vhd \
	$RTL/fpu_040.vhd \
	$RTL/cpu_wrapper.vhd \
	-e cpu_wrapper > "$OUT" 2> convert.log

# ghdl synth emits the scalar output `fpu_present` as BOTH a port and an internal
# `wire fpu_present;` - GHDL tolerates it but Verilator rejects the duplicate.
# Strip the redundant internal wire (harmless; Quartus uses the VHDL directly).
sed -i '/^  wire fpu_present;$/d' "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines); top module: cpu_wrapper"
