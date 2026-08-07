# Building & running on hardware (Superstation One / MiSTer)

This core is a standard **MiSTer** core: it uses the `sys/` framework and the
DE10-Nano device (`5CSEBA6U23I7`, set in `sys/sys.tcl`). The **Retro Remake
Superstation One** is MiSTer-compatible and runs the same `.rbf`, so no device
retarget is needed.

> **Read the "Current state" section first.** This core builds and loads, but it
> does **not** yet boot to a Macintosh desktop. Flashing it will not give you a
> usable Mac. It is an engineering bring-up, not a finished emulator.

## Prerequisites

- **Quartus Prime 17.0.x Standard** (the MiSTer-standard toolchain; the project
  declares `LAST_QUARTUS_VERSION "17.0.2 Standard Edition"`). Newer Quartus will
  refuse or mis-handle the `sys/` IP.
- A **Quadra 950 ROM** image (1 MB, `$3DC27823`). Not distributed here — provide
  your own dump. The core loads it via the MiSTer file/ROM channel.

## Build

```
# Open the project and compile (GUI): Quadra950.qpf -> Processing -> Start Compilation
# Or headless:
quartus_sh --flow compile Quadra950
```

Output: `output_files/Quadra950.rbf`. Add RTL only via `files.qip` (never the
Quartus GUI, which rewrites the `.qsf`).

### Must verify on the first build

- **PLL lock + timing closure.** `rtl/pll` is set to **50 MHz** (frequency-
  driven `altera_pll`, Quartus computes the counters) but has never been
  compiled in Quartus in this repo. Confirm the PLL fits and that TimeQuest
  reports no failing paths at 50 MHz.
- **Clock plan:** `clk_sys = 50 MHz` feeds everything: emulated CPU =
  `clk_sys / CPU_DIV` (`CPU_DIV=2` → 25 MHz), DAFB pixel enable = `clk_sys/2` =
  25 MHz (sized for 640×480; higher OSD "Screen size" modes need a
  reconfigurable pixel clock that is not implemented yet), ASC ≈ 22.25 kHz, and
  `DDRAM_CLK = clk_sys`.
- **Fit/resource.** The core has never been placed & routed; there may be
  synthesis or fitting issues to resolve (it is Verilator- and GHDL-clean, which
  is a good proxy but not Quartus).

## Deploy to the Superstation One

1. Copy `Quadra950.rbf` to the SD card, e.g. `/media/fat/_Computer/`.
2. Place the ROM where the core loads it (the OSD SCSI slots mount disk images;
   the ROM is provided via the core's file channel — see the OSD once running).
3. Boot the core from the MiSTer/Superstation One menu.

## Current state — what actually happens today

Simulation (full-system Verilator harness, real ROM) is the source of truth:

- ✅ CPU resets, clears the ROM overlay, runs with **zero spurious exceptions**.
- ✅ The ROM's **universal machine-identification passes** — it recognizes the
  Quadra family (see `docs/BOOT_ANALYSIS.md`).
- ✅ Boot advances into **device configuration**.
- ⛔ It then **loops** in device configuration (probing device pages the core
  does not yet implement). It does **not** reach the "Welcome to Macintosh"
  screen or a desktop.
- ⛔ Video: the DAFB generates timing/frames, but no meaningful image yet (boot
  never gets to drawing the desktop).

So on hardware you can expect: the core loads, the PLL/video should produce a
signal, and it will execute ROM boot up to the device-config loop — **not** a
booting Mac.

## What stands between here and a bootable system

1. **ROM device-probe fidelity** (the current gate + several after it): RAM
   sizing, RTC/timers, ADB, then SCSI so a System file can load. Each is a
   reverse-engineering + peripheral-fidelity step (`docs/BOOT_ANALYSIS.md`).
2. **A real 68040 CPU.** The TG68 is a 68020-class core with a Level-A 040
   personality (MOVEC 040 regs, cache/MMU no-ops — see `docs/CPU_NOTES.md`).
   MOVE16, the FPU, and a real MMU table walk are still open (Level B/C).
3. **Hardware validation.** Quartus fit/timing, PLL lock, and on-board testing
   have not been done.

## Honest summary

The hard central boot gate (machine identification) is solved and the whole
non-CPU subsystem set is simulation-verified, but this is **not** a
flash-and-boot core yet. Building it is useful for on-hardware bring-up and
debugging; it is not a working Quadra 950 you can use.
