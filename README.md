# Quadra950_MiSTer

A work-in-progress **Apple Macintosh Quadra 950** (Motorola 68040) core for the
[MiSTer FPGA](https://mister-devel.github.io/MkDocs_MiSTer/) platform.

> **Status: Phase 2 in progress (CPU + memory + video/VIA, sim-verified).** The
> repository has an accurate hardware spec, the MiSTer framework wiring, and the
> system interconnect with the real Quadra 950 memory map. Working, simulation-
> verified so far (see [`sim/`](sim/)):
> - **CPU** — a 68020-class TG68 core through a `TS`/`TA` bus adapter (boots and
>   executes; GHDL).
> - **Memory** — a real MCU↔DDR3 controller with ROM loading (Icarus).
> - **Video** — a DAFB framebuffer: VRAM + 256-colour CLUT + 8bpp scanout (Icarus).
> - **I/O** — a 6522 VIA (timers + interrupts) wired through `iobus`, with the
>   reset ROM overlay clearing on first `$40000000` access (Icarus).
>
> It is not yet a full bootable system — the RTC (Caboose), SCSI, ADB, floppy
> and sound are still stubs, and it targets a 68020-class CPU, not a true 040
> (see [`docs/CPU_NOTES.md`](docs/CPU_NOTES.md)).

## Why this is hard (read this first)

The Quadra 950 is one of the most ambitious targets on MiSTer, for two reasons:

1. **The 68040 CPU.** Unlike the 68000 (which has mature open cores), there is
   **no mature, open-source, synthesizable 68040** with its on-die FPU, dual
   MMUs and caches. That IP is the crux of the whole project. The current
   approach (per [`docs/CPU_NOTES.md`](docs/CPU_NOTES.md)) brings the system up
   on a 68020-class core (**TG68**, now integrated and sim-verified) and extends
   toward the 040 (MMU → FPU → cache/burst) from there.
2. **The system.** DAFB video, dual NCR 53C96 SCSI, Enhanced ASC + DFAC sound,
   SWIM floppy, ADB via an IOP, NuBus/YANCC, and the MCU/JDB/Relayer glue —
   each is a real chip that has to be re-implemented. Plus a 1 MB Apple ROM you
   must supply yourself.

This repo is honest about that: it lays a correct foundation and a phased plan
rather than pretending to be a finished core.

## Documentation

| Doc | What's in it |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Full, cited hardware spec (CPU, chips, video, sound, I/O) |
| [`docs/MEMORY_MAP.md`](docs/MEMORY_MAP.md) | Address map the decoder implements |
| [`docs/CPU_NOTES.md`](docs/CPU_NOTES.md) | The 68040 problem and how we approach it |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Phased build plan (you are at Phase 0) |

> Naming note: the 900/950 use the **MCU / JDB+Relayer / YANCC / DAFB / IOP /
> Caboose** chips — **not** the djMEMC/IOSB parts often cited online (those are
> the later Centris/Quadra 610/650/800). See `ARCHITECTURE.md`.

## Repository layout

```
Quadra950.sv            emu-module wrapper (framework-facing top level)
Quadra950.qpf/.qsf/.sdc Quartus project files
files.qip               RTL source manifest (add files here, not via Quartus IDE)
sys/                    MiSTer framework (copied as-is; updateable)
rtl/
  quadra950.sv          system interconnect + address decode
  cpu/cpu_wrapper.vhd   TG68 bus adapter (16-bit clkena -> 32-bit TS/TA)
  cpu/tg68k/            vendored TG68KdotC kernel (LGPLv3)
  chipset/              mcu (DDR3), iobus (JDB+Relayer), via, caboose, yancc
  video/dafb.sv         Direct Access Frame Buffer (video)
  audio/asc.sv          Enhanced Apple Sound Chip (+DFAC)
  io/                   scsi_ncr53c96, swim, adb, iop, sonic
  pll/                  PLL (placeholder settings; regenerate before real build)
sim/                    GHDL (CPU) + Icarus (MCU) testbenches — see sim/README.md
releases/               built .rbf files go here (core_YYYYMMDD.rbf)
docs/                   specification and plan
```

## Building

Requires **Quartus 17.0.x Standard** (the MiSTer-standard version) and a
DE10-Nano. Open `Quadra950.qpf` and compile, or use the MiSTer build scripts.

⚠️ The included `rtl/pll` and `Quadra950.sdc` carry placeholder timing from the
framework template. Regenerate the PLL for the Quadra system/CPU/video clocks
and add real constraints before expecting a meaningful build.

## ROM

The 1 MB Quadra 950 ROM is copyrighted Apple firmware and is **not** included.
You must supply your own dump; it will be loaded via the OSD.

## License

RTL authored here is GPLv2 (matching the MiSTer framework in `sys/`). The
`sys/` framework retains its upstream MiSTer license. The vendored TG68 core in
`rtl/cpu/tg68k/` is © Tobias Gubener, licensed **LGPLv3** (headers retained).
