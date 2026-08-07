# Simulation / verification

Phase 1 is verified in two independent halves that meet at the CPU's simple
`TS`/`TA` bus contract (a transfer starts on `ts`, completes on `ta`). Each
half runs under a free, open-source simulator.

## CPU + bus adapter — GHDL (`sim/ghdl/`)

Exercises the **real TG68 core** (`rtl/cpu/tg68k/`) through the adapter
(`rtl/cpu/cpu_wrapper.vhd`) against a behavioral memory that speaks `TS`/`TA`.
The memory is preloaded with a hand-assembled 68k program that loads
`$12345678` into D0 and stores it to `$100`.

```sh
cd sim/ghdl && ./run.sh
# -> PASS: CPU executed program; $100 = 0x12345678
```

What it proves: reset-vector fetch (SSP/PC), instruction fetch/execute, the
16-bit-clkena → 32-bit big-endian bus translation, byte lanes, and IPL polarity.

## Verilog RTL — Icarus Verilog (`sim/iverilog/`)

`./run.sh` builds and runs all three Verilog testbenches:

- **`tb_mcu`** — memory controller (`rtl/chipset/mcu.sv`) vs. a behavioral DDR3
  model: ROM image load via `ioctl` + big-endian read-back, RAM write/read,
  byte-enable partial writes.
- **`tb_via`** — 6522 VIA (`rtl/chipset/via.sv`): port output, T1 timer
  underflow raising IRQ, read-to-clear, and IER interrupt masking.
- **`tb_dafb`** — DAFB framebuffer (`rtl/video/dafb.sv`): CPU VRAM + CLUT
  access, and 8bpp scanout indexed through the CLUT onto r/g/b (uses a tiny
  CRTC so a frame is short).
- **`tb_caboose`** — RTC/PRAM (`rtl/chipset/caboose.sv`): the Apple serial
  protocol — a seconds byte and an extended-PRAM byte written then read back.
- **`tb_adb`** — ADB (`rtl/io/adb.sv`): a PS/2 key and mouse move translated to
  ADB register-0 responses on Talk R0, and SRQ.
- **`tb_scsi`** — NCR 53C96 (`rtl/io/scsi_ncr53c96.sv`): a READ(6) and WRITE(6)
  against a behavioral disk model through the hps_io block interface.
- **`tb_asc`** — Apple Sound Chip (`rtl/audio/asc.sv`): FIFO playback with
  offset-binary → signed-16 conversion on both channels.

```sh
cd sim/iverilog && ./run.sh
# -> PASS: MCU/DDR3 all checks passed
# -> PASS: VIA all checks passed
# -> PASS: DAFB all checks passed
# -> PASS: Caboose all checks passed
# -> PASS: ADB all checks passed
# -> PASS: SCSI all checks passed
# -> PASS: ASC all checks passed
```

## Full-core simulation — GHDL→Verilog (`sim/verilog-full/`)

The CPU is VHDL and the peripherals are Verilog, which normally blocks a
single-simulator full-system run. `ghdl synth --out=verilog` sidesteps that by
emitting a Verilog netlist of the CPU, so the **whole core** can run in Icarus.

```sh
cd sim/verilog-full && ./run.sh
# convert_cpu.sh -> cpu_synth.v (generated, git-ignored)
# -> PASS: converted CPU executed program; $100 = 0x12345678
```

`tb_cpu_v` proves the converted netlist is functionally equivalent (same boot
program as the GHDL test). This is the enabler for Phase 5 milestone 5.0 —
simulating the full core with the real ROM. See `docs/PHASE5_SCOPE.md`.

**Simulator note:** Icarus runs the converted core fine for short tests, but it
does *not* scale to a full ROM boot — it can't compile the ~35k-line netlist
together with a 1 MB memory in practical time (an iverilog large-array
limitation). `tb_boot.v` (the full boot harness) is written and
simulator-agnostic, but should be run under **Verilator** (compiled C++ sim),
not Icarus.

## Not covered here

Full-system co-simulation mixes VHDL (the CPU) and Verilog (everything else).
GHDL and Icarus are single-language, so end-to-end "CPU boots a real ROM
through the MCU" needs a mixed-language simulator (ModelSim/Questa) or a
Quartus build on hardware. The two halves above validate both sides of the
`TS`/`TA` interface they share.

## Installing the tools (Debian/Ubuntu)

```sh
apt-get install -y ghdl iverilog
```
