# Build Roadmap

A realistic, phased plan. Each phase produces something testable. Phases 0–2
are achievable with existing open IP; the later phases are the long game.

Legend: ✅ done · 🚧 in progress · ⬜ not started

---

## Phase 0 — Foundation ✅ (this commit)
- ✅ Accurate hardware spec ([ARCHITECTURE.md](ARCHITECTURE.md), [MEMORY_MAP.md](MEMORY_MAP.md))
- ✅ MiSTer project scaffold: `sys/` framework, Quartus files, `emu` wrapper
- ✅ System interconnect (`rtl/quadra950.sv`) with real memory-map decode
- ✅ Documented stubs for every custom chip (correct silicon names)
- ✅ Placeholder video path (real VGA sync + test pattern)

## Phase 1 — CPU + boot ROM 🚧
- 🚧 CPU integration point (`rtl/cpu/cpu_wrapper.sv`) — bus contract defined
- ⬜ Drop in a 68020/030-class open core (TG68K/ao68k) — see [CPU_NOTES.md](CPU_NOTES.md)
- ⬜ `mcu`: real DDR3 read/write engine, 32↔64-bit packing, bank decode
- ⬜ Load a Quadra 950 ROM image into DDR3 (`ioctl` index 0) + reset overlay
- ⬜ **Milestone:** CPU fetches and executes from ROM; early POST visible

## Phase 2 — Video + minimal I/O ⬜
- ⬜ `dafb`: programmable CRTC, real VRAM, 1/2/4/8-bpp + CLUT/RAMDAC
- ⬜ `via` ×2: integrate a 6522 core (timers, IRQ, overlay/sound-enable bits)
- ⬜ `iobus`: JDB/Relayer sub-decode within `$50xx_xxxx`
- ⬜ `caboose`: RTC/PRAM so the OS gets a valid clock
- ⬜ **Milestone:** ROM draws the "Welcome to Macintosh" / disk icon

## Phase 3 — Storage + input (bootable) ⬜
- ⬜ `scsi_ncr53c96` ×2: register set, phases, DMA to the block interface
- ⬜ `iop` mailbox + `adb`: PS/2 → ADB keyboard/mouse
- ⬜ `swim`: floppy (lower priority than SCSI)
- ⬜ **Milestone:** boots a System 7 install from a SCSI disk image; usable

## Phase 4 — Sound + polish ⬜
- ⬜ `asc`/DFAC: FIFO + 4-voice playback, 22.257 kHz → 16-bit resample
- ⬜ Save/load PRAM to MiSTer persistent storage
- ⬜ Multiple Apple video timings selectable from the OSD
- ⬜ Cycle/timing tuning

## Phase 5 — Toward real 68040 fidelity ⬜
- ⬜ MMU (enables modern System versions / VM / A/UX)
- ⬜ FPU (IEEE-754) — large, self-contained
- ⬜ Cache + burst bus semantics; satisfy the stock 950 ROM (Gestalt = 26)
- ⬜ NuBus (`yancc`) + card emulation, Ethernet (`sonic`) — optional, low priority

---

## Dependencies & risks
- **CPU is the critical path.** Everything in Phases 2–3 can be developed and
  unit-tested against a simple bus-functional model in parallel, but end-to-end
  boot needs a working CPU first.
- **ROM sourcing is the user's responsibility.** The 1 MB Quadra 950 ROM is
  copyrighted Apple firmware; it is not and will not be included here.
- **DE10-Nano resource budget.** A full 040 + FPU + MMU is large for a
  Cyclone V; fitting/timing at a useful clock is a real risk to validate early.
- **"040-ness" of a substitute CPU.** An 020/030 substitute is a *Quadra-class*
  machine, not a literal 950; label builds honestly.

## How to contribute to a phase
Each stub lists its own TODO checklist in the file header. Pick a module, keep
the port contract in `rtl/quadra950.sv` stable, and add sources to `files.qip`
(never via the Quartus IDE, which rewrites the `.qsf`).
