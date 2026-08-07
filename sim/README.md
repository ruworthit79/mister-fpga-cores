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

## MCU ↔ DDR3 — Icarus Verilog (`sim/iverilog/`)

Exercises the memory controller (`rtl/chipset/mcu.sv`) against a behavioral
DDR3 model (`ddr3_model.v`): ROM image load via `ioctl` and read-back in 68k
big-endian order, full-word RAM write/read, and byte-enable partial writes.

```sh
cd sim/iverilog && ./run.sh
# -> PASS: MCU/DDR3 all checks passed
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
