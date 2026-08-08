#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  build.sh - compile the Quadra 950 MiSTer core with Intel Quartus.
#
#  Produces a MiSTer-loadable bitstream at output_files/Quadra950.rbf
#  (GENERATE_RBF_FILE is ON in Quadra950.qsf).
#
#  Target board: Superstation One (MiSTer / DE10-Nano compatible,
#  Cyclone V 5CSEBA6U23I7 - set in sys/sys.tcl).
#
#  Requires: Quartus Prime 17.0.x (Standard or Lite). The .qsf pins
#  LAST_QUARTUS_VERSION to "17.0.2 Standard Edition"; newer Quartus will
#  offer to migrate the project - that is fine, but 17.0.x matches the
#  MiSTer sys framework and is recommended.
#
#  Usage:
#     ./build.sh              # full compile
#     ./build.sh clean        # remove build artifacts
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=Quadra950

if [[ "${1:-}" == "clean" ]]; then
	echo "Cleaning build artifacts..."
	rm -rf output_files db incremental_db qdb \
	       "${PROJECT}.qws" c5_pin_model_dump.txt build_id.v
	echo "Clean."
	exit 0
fi

# Locate quartus_sh (allow QUARTUS_ROOTDIR override).
if command -v quartus_sh >/dev/null 2>&1; then
	QSH=quartus_sh
elif [[ -n "${QUARTUS_ROOTDIR:-}" && -x "$QUARTUS_ROOTDIR/bin/quartus_sh" ]]; then
	QSH="$QUARTUS_ROOTDIR/bin/quartus_sh"
else
	echo "ERROR: quartus_sh not found. Install Quartus Prime 17.0.x and either"
	echo "       put its bin/ on PATH or set QUARTUS_ROOTDIR." >&2
	exit 1
fi

echo "Using: $("$QSH" --version 2>/dev/null | head -1 || echo "$QSH")"
echo "Compiling ${PROJECT} (this takes ~15-40 min depending on the machine)..."

# Full compile flow: map -> fit -> assemble (-> .sof/.rbf) -> timing.
"$QSH" --flow compile "${PROJECT}"

RBF="output_files/${PROJECT}.rbf"
if [[ -f "$RBF" ]]; then
	echo
	echo "SUCCESS: $RBF"
	ls -la "$RBF"
	echo
	echo "Deploy: copy '$RBF' to /media/fat/_Computer/ on the MiSTer SD card"
	echo "        (rename to e.g. 'Quadra950_$(date +%Y%m%d).rbf' if you like)."
else
	echo "Build finished but $RBF was not produced - check output_files/*.rpt" >&2
	exit 1
fi
