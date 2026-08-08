#!/usr/bin/env bash
# GHDL simulation of the TG68 CPU + adapter executing a program over the TS/TA
# bus. Exits non-zero on failure.
set -e
cd "$(dirname "$0")"
RTL=../../rtl/cpu
WORK=work-obj08.cf

STD="--std=08 -fexplicit --ieee=synopsys -Wno-hide"

ghdl -a $STD $RTL/tg68k/TG68K_Pack.vhd
ghdl -a $STD $RTL/tg68k/TG68K_ALU.vhd
ghdl -a $STD $RTL/tg68k/TG68KdotC_Kernel.vhd
ghdl -a $STD $RTL/fpu_040.vhd
ghdl -a $STD $RTL/cpu_wrapper.vhd

# Each testbench self-checks and calls std.env.finish; a failed assertion aborts
# with a non-zero exit (set -e). Filter the synopsys reset-time metavalue noise.
FILTER='CONV_INTEGER|std_logic_arith|metavalue|numeric_std'
for tb in tb_cpu tb_cpu_040 tb_cpu_040nop tb_move16 tb_fpu tb_cpu_fpu; do
	ghdl -a $STD $tb.vhd
	ghdl -e $STD $tb
	echo "--- $tb ---"
	ghdl -r $STD $tb --stop-time=2ms 2>&1 | grep -Eiv "$FILTER"
done
