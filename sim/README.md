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

```sh
cd sim/iverilog && ./run.sh
# -> PASS: MCU/DDR3 all checks passed
# -> PASS: VIA all checks passed
# -> PASS: DAFB all checks passed
```

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
