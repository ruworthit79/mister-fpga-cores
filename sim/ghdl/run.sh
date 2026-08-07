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
ghdl -a $STD $RTL/cpu_wrapper.vhd
ghdl -a $STD tb_cpu.vhd
ghdl -e $STD tb_cpu
ghdl -r $STD tb_cpu --stop-time=2ms
