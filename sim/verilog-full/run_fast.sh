#!/usr/bin/env bash
# Fast full-system boot sim (Verilator WITHOUT --timing; C++ clock driver).
# ~30x faster than run_full.sh (boot_top.v + --timing), so it can run the many
# millions of fetches the ROM boot needs (checksum, init scans). See BOOT_ANALYSIS.
#   Usage: ./run_fast.sh <Quadra_950.ROM> <boot_disk.img> [cycles]
#   The disk image is a raw HFS volume served on SCSI channel 0 (see boot_core.v).
set -e
cd "$(dirname "$0")"
ROM="${1:?usage: run_fast.sh <Quadra_950.ROM> <boot_disk.img> [cycles]}"
DISK="${2:?usage: run_fast.sh <Quadra_950.ROM> <boot_disk.img> [cycles]}"
CYCLES="${3:-120000000}"
python3 - "$ROM" rom64.hex <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read(); d += b'\x00' * ((-len(d)) % 8)
w = [struct.unpack('>Q', d[i:i+8])[0] for i in range(0, len(d), 8)]
open(sys.argv[2], 'w').write('\n'.join('%016x' % x for x in w))
PY
# disk.hex: big-endian 16-bit words (matches the core's sector-buffer byte order)
python3 - "$DISK" disk.hex <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read(); d += b'\x00' * ((-len(d)) % 2)
w = [struct.unpack('>H', d[i:i+2])[0] for i in range(0, len(d), 2)]
open(sys.argv[2], 'w').write('\n'.join('%04x' % x for x in w))
PY
./convert_cpu.sh
R=../../rtl
verilator --binary -j 0 --top-module boot_core -O3 \
  -Wno-lint -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-WIDTH -Wno-BLKANDNBLK -Wno-COMBDLY \
  --exe sim_main_full.cpp boot_core.v cpu_synth.v \
  $R/quadra950.sv $R/chipset/mcu.sv $R/chipset/iobus.sv $R/chipset/via.sv \
  $R/chipset/caboose.sv $R/io/adb.sv $R/io/scsi_ncr53c96.sv \
  $R/io/sonic.sv $R/io/swim.sv \
  $R/video/dafb.sv $R/audio/asc.sv -o boot_fast
./obj_dir/boot_fast "$CYCLES"
