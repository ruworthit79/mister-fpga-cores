#!/usr/bin/env bash
# Full-system boot: the real ROM through the WHOLE core (quadra950 + converted
# CPU + all verified peripherals) in Verilator. Unlike the CPU-only harness
# (sim_main.cpp), the VIA/RTC/SCSI/DAFB are live, so the ROM's hardware probe
# gets real responses. See docs/PHASE5_SCOPE.md.
#
# Usage: ./run_full.sh <path-to-Quadra_950.ROM>
# (produces rom64.hex - 64-bit big-endian words - next to the harness)
set -e
cd "$(dirname "$0")"
ROM="${1:?usage: run_full.sh <Quadra_950.ROM>}"

python3 - "$ROM" rom64.hex <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
d += b'\x00' * ((-len(d)) % 8)
w = [struct.unpack('>Q', d[i:i+8])[0] for i in range(0, len(d), 8)]
open(sys.argv[2], 'w').write('\n'.join('%016x' % x for x in w))
PY

./convert_cpu.sh
R=../../rtl
verilator --binary --timing -j 0 --top-module boot_top \
	-Wno-lint -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-WIDTH -Wno-BLKANDNBLK -Wno-COMBDLY \
	boot_top.v cpu_synth.v \
	$R/quadra950.sv $R/chipset/mcu.sv $R/chipset/iobus.sv $R/chipset/via.sv \
	$R/chipset/caboose.sv $R/io/adb.sv $R/io/scsi_ncr53c96.sv \
	$R/io/sonic.sv $R/io/swim.sv \
	$R/video/dafb.sv $R/audio/asc.sv -o boot_full
./obj_dir/boot_full
