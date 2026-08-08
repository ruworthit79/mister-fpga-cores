#!/usr/bin/env bash
# Icarus Verilog simulations for the Verilog RTL.
set -e
cd "$(dirname "$0")"

run() {   # <name> <sources...>
	local name="$1"; shift
	echo "=== $name ==="
	iverilog -g2012 -o "$name.vvp" "$@"
	vvp "$name.vvp"
	rm -f "$name.vvp"
}

run tb_mcu     ../../rtl/chipset/mcu.sv           ddr3_model.v tb_mcu.v
run tb_via     ../../rtl/chipset/via.sv           tb_via.v
run tb_dafb    ../../rtl/video/dafb.sv            tb_dafb.v
run tb_dafb_modes ../../rtl/video/dafb.sv         tb_dafb_modes.v
run tb_dafb_depth ../../rtl/video/dafb.sv         tb_dafb_depth.v
run tb_caboose ../../rtl/chipset/caboose.sv       tb_caboose.v
run tb_adb     ../../rtl/io/adb.sv                tb_adb.v
run tb_scsi    ../../rtl/io/scsi_ncr53c96.sv      tb_scsi.v
run tb_asc     ../../rtl/audio/asc.sv             tb_asc.v
run tb_sonic   ../../rtl/io/sonic.sv              tb_sonic.v
run tb_swim    ../../rtl/io/swim.sv               tb_swim.v
