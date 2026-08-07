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
- ✅ Programmable DAFB CRTC: 4 selectable Apple timings (640×480, 832×624,
  1024×768, 1152×870) wired to the OSD "Screen size" option. **Icarus-verified**
  (`tb_dafb_modes`).
- ✅ I/O map + byte lane validated against a real Quadra 950 ROM; addresses
  corrected (ASC $50F14000, SCSI $50F10000, VIA confirmed). See
  [ROM_VALIDATION.md](ROM_VALIDATION.md).
- ✅ PRAM save/restore: Caboose backup port wired to the hps_io NVRAM ioctl.
  **Icarus-verified** (serial ↔ backup port share the array).
- ✅ 33 MHz CPU clock-enable: `cpu_ce` divider enabled; the bus adapter captures
  a pulsed TA across ce gaps. **GHDL-verified** (1-in-3 ce + pulsed ack boot).
- ✅ VIA1/RTC port-B bit mapping corroborated against the ROM (see ROM_VALIDATION.md).
- ⬜ `asc`: 4-voice wavetable mode + DFAC record path (FIFO mode is what Mac
  sound uses; wavetable deferred)
- ⬜ Confirm the 2nd SCSI channel address; regenerate the PLL; set CPU_DIV for
  the real 33 MHz rate

## Phase 5 — Toward a real 68040 🚧 (scoped)
Full scoping in **[PHASE5_SCOPE.md](PHASE5_SCOPE.md)**. Interface anchors added:
`rtl/cpu/mmu_040.sv` (transparent-1:1 stub = the Level-A starting point) and
`rtl/cpu/fpu_040.sv` (68LC040 "no FPU" stub). Summary of the path:
- ⬜ **5.0** Full-system mixed-language sim harness (prerequisite for boot)
- ⬜ **Level A** — 040 personality (MOVE16, cache-instr no-ops, 040 exception
  frames, CPU-type reporting) + MMU register interface & transparent
  translation + LC040 FPU → boot Mac OS non-VM
- ⬜ **Level B** — hardware FPU (+FPSP trap) + real MMU table-walk/ATC → apps + VM
- ⬜ **Level C** — 4KB+4KB caches + snooping + burst bus → fidelity / A/UX
- ⬜ NuBus (`yancc`) + Ethernet (`sonic`) — optional, low priority

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
