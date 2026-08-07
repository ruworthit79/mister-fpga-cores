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

## Phase 1 — CPU + boot ROM 🚧 (mostly done, sim-verified)
- ✅ CPU integration + bus adapter (`rtl/cpu/cpu_wrapper.vhd`) wrapping the TG68
  kernel; 16-bit clkena bus → 32-bit TS/TA. **GHDL-verified**: the real core
  boots (reset vectors), executes, and stores to memory (`sim/ghdl/`).
- ✅ Vendored TG68KdotC kernel (LGPLv3) as the 68020-class stand-in — see [CPU_NOTES.md](CPU_NOTES.md)
- ✅ `mcu`: DDR3 read/write engine, 32↔64-bit packing, byte-enable writes, ROM
  image load via `ioctl`. **Icarus-verified** (`sim/iverilog/`).
- ✅ Reset ROM overlay routing (ROM served at low addresses after reset)
- ✅ Interconnect wires CPU + MCU with the real memory-map decode (elaborates)
- 🚧 **Milestone (CPU fetches/executes from ROM):** both halves proven in sim
  against the shared TS/TA contract; full mixed-language (VHDL+Verilog) system
  co-sim needs ModelSim/Questa or Quartus (not possible with GHDL/Icarus alone).
- ⬜ Remaining before hardware: regenerate the PLL for real clocks; 33 MHz `ce`
  divider; clear the overlay on the VIA bit; DDR3 burst (line) reads for speed.

## Phase 2 — Video + minimal I/O 🚧 (core blocks done, sim-verified)
- ✅ `dafb`: real VRAM framebuffer (4 byte-lanes), 256×24 CLUT/RAMDAC, 8bpp
  indexed readout with base/stride regs, VBL interrupt. **Icarus-verified**
  (VRAM/CLUT access + scanout). CRTC timing fixed 640×480 (programmable + more
  depths still TODO).
- ✅ `via` ×2: functional 6522 (T1/T2 timers, IFR/IER, ports, CA1/CB1 edges).
  **Icarus-verified** (timer IRQ, masking). SR / CA2-CB2 handshakes TODO.
- ✅ `iobus`: JDB/Relayer sub-decode of `$50F0_xxxx` to VIA1/VIA2, phase-2 `ce`,
  IRQ→IPL roll-up (active low), DAFB VBL → VIA1 CA1.
- ✅ Reset ROM overlay now clears on first `$40000000` access (per Apple's note).
- ⬜ `caboose`: RTC/PRAM so the OS gets a valid clock
- ⬜ VIA data byte-lane vs. real Mac wiring; verify against a real ROM
- 🚧 **Milestone (ROM draws "Welcome to Macintosh"):** needs `caboose` + the
  remaining I/O and a full mixed-language system sim / hardware build.

## Phase 3 — Storage + input 🚧 (datapaths done, sim-verified)
- ✅ `caboose`: RTC 32-bit seconds counter + 256-byte PRAM over the Apple serial
  protocol, wired to VIA1 port B. **Icarus-verified** (seconds + PRAM R/W).
- ✅ `scsi_ncr53c96` ×2: 53C96 register model + READ(6)/WRITE(6) CDB parse +
  DMA to the hps_io block interface. **Icarus-verified** (sector read + write
  against a disk model). Wired to the top-level `sd_*` block channels 0/1.
- ✅ `adb`: PS/2 → ADB keyboard/mouse translation + Talk R0 register model.
  **Icarus-verified**. Wired into `iobus` (host command side awaits the IOP).
- ⬜ `iop` mailbox: 6502-based I/O processor to drive ADB/SWIM host side
- ⬜ `swim`: floppy (lower priority than SCSI)
- ⬜ SCSI CD-ROM target (for the Superstation One dock's optical drive)
- 🚧 **Milestone (boots System 7 from a SCSI image):** each datapath is proven
  in isolation; end-to-end boot needs the IOP host side, a real ROM, and a full
  mixed-language system sim / hardware build.

## Phase 4 — Sound + polish 🚧 (sound done, sim-verified)
- ✅ `asc`: Apple Sound Chip FIFO playback — stereo 8-bit FIFOs, offset-binary
  → signed-16 conversion, sample-rate playout, half-empty IRQ. **Icarus-
  verified**; wired into I/O space ($50F3) and the audio output.
- ⬜ `asc`: 4-voice wavetable mode + DFAC record path
- ⬜ Save/load PRAM to MiSTer persistent storage (expose Caboose PRAM to hps_io)
- ⬜ Wire the OSD "Screen size" option to a programmable DAFB CRTC (multiple
  Apple timings); today DAFB timing is fixed 640×480
- ⬜ Cycle/timing tuning; regenerate the PLL; 33 MHz `ce` divider

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
