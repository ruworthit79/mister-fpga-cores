# Target specification — "maxed Quadra 950" running Mac OS 8.1

This is the agreed end-goal for the core. It closely matches a fully-loaded real
Quadra 950, which is exactly what the core is designed around. Each line is
mapped to its current status and the concrete work to reach it. Statuses:
✅ done/verified · 🟡 partial/in progress · ⛔ not started.

## The spec

| # | Requirement | Real Q950 reference | Status | Gap to close |
|---|-------------|--------------------|--------|--------------|
| 1 | **68040 CPU @ 33 MHz** | MC68040 33 MHz | 🟡 | TG68 (68020-class) + 040 personality. Done: MOVEC 040 regs, cache/MMU control ops, LC040 F-line. In progress: MOVE16. Remaining: 040 exception frames, CPU-type=68040 reporting. Clock: `clk_sys` divider set for ~33 MHz. |
| 2 | **Integrated FPU** | on-die 68040 FPU | 🟡 | **Foundation + kernel dispatch live** (`fpu_040.vhd`): FP0-FP7 + FPCR/FPSR/FPIAR, FMOVE/FABS/FNEG/FTST, IEEE classification, `present=1`, `unimpl`→FPSP. The CPU now **executes** reg-reg F-line FPU ops (`$F200` decode → `fpu1` handshake → `fpu_040`), verified by GHDL `tb_cpu_fpu` (FTST/FNEG run, FPSR updates, no trap). Remaining: memory-operand path (FMOVE.X `<ea>`↔FPn), then the HW arithmetic datapath (FADD/FMUL/FDIV/FSQRT…, the big lift — adapt the open MC68881 VHDL core). See `docs/FPU_SCOPE.md`. Interim = LC040 + software FPSP. |
| 3 | **8 KB L1 cache, no L2** | 4 KB I + 4 KB D on-die; no L2 | ⛔ | Cache instructions are currently correct no-ops. Real 4K+4K caches + burst bus = Level C. Affects performance/timing, **not** correctness — OS 8.1 boots without it. |
| 4 | **RAM ≤ 80 ns, max 256 MB** | 16 SIMM slots, 256 MB max, 80 ns FPM | ✅ | **64/128/256 MB selectable** (OSD `RAM`). The MCU masks the RAM address to the installed size so higher accesses alias/wrap — how sized DRAM presents to the ROM's memory-sizing probe (previously `ram_128mb` was a no-op). Verified in `tb_mcu` (aliasing at each size). "80 ns" is a bus-timing characteristic modeled by the 33 MHz bus, backed by faster DDR3. |
| 5 | **2 MB VRAM** | DAFB 1 MB, expandable to 2 MB | 🟡 | DAFB VRAM is a tiny block-RAM test buffer today. 2 MB exceeds Cyclone V block RAM (~0.7 MB), so VRAM must move to **SDRAM** (Superstation One has 128 MB) or DDR3. Architectural change. |
| 6 | **832×624 @ 24-bit** | DAFB w/ 2 MB VRAM (needs ~1.56 MB) | ⛔ | DAFB reads out **8 bpp only** today. Add 16/24 bpp scanout + the CLUT/direct-color path. |
| 7 | **1152×870 @ 8-bit** | DAFB w/ 2 MB VRAM (needs ~1.0 MB) | ⛔ | Needs a **reconfigurable pixel clock** + programmable CRTC timing (today the pixel clock is fixed clk/2 = 25 MHz = 640×480 only). 1152×870@75 Hz needs a ~100 MHz pixel clock. |
| 8 | **Ethernet** | SONIC DP83932 @ $50F0_A000 | ⛔ | `rtl/io/sonic.sv` is a stub. Implement SONIC + MiSTer network path. Not required to boot OS 8.1. |
| 9 | **Floppy** | SWIM + IWM, via IOP | ⛔ | `rtl/io/swim.sv` / `rtl/io/iop.sv` are stubs. Implement SWIM + the 6502 IOP mailbox. |
| 10 | **DVD / CD usage** | SCSI CD-ROM (Superstation One DVD dock) | 🟡 | SCSI datapath is verified (NCR 53C96). Add a SCSI **CD/DVD-ROM device model** and mount an ISO via hps_io. OS 8.1 needs the Apple CD driver. |
| 11 | **Boots Mac OS 8.1** | — | ⛔ | Requires 1+2 (040+FPU or LC040+FPSP), enough RAM, a real MMU or clean transparent translation, HFS on a SCSI disk, and passing the whole ROM boot chain. See `docs/BOOT_ANALYSIS.md`. |

## Mac OS 8.1 hard requirements (the OS itself)

- **68040 CPU** — 8.0+ dropped 68030; a 68040 personality is mandatory (item 1).
- **FPU** — 8.1 expects it; LC040 systems rely on the FPSP package. Full HW FPU
  (item 2) is the authentic path.
- **MMU** — the OS uses the 040 MMU. Basic boot can run on **transparent (1:1)
  translation** (already in place); **Virtual Memory** needs the real table
  walk (Level B). OS 8.1 boots with VM off.
- **RAM** — ~8 MB minimum; 16–32 MB comfortable. Item 4 covers this easily.
- **Disk** — an HFS-formatted SCSI volume with a System 8.1 install; the SCSI
  block path (item 10) delivers it.

## Key architectural decisions this spec forces

1. **VRAM → SDRAM.** 2 MB can't be block RAM on Cyclone V. Route DAFB VRAM to
   the Superstation One's 128 MB SDRAM (currently tri-stated/unused) or share
   DDR3. This also unblocks the deep color depths (items 5–7).
2. **A second, reconfigurable pixel PLL** for the non-640×480 modes (item 7),
   reprogrammed per selected resolution.
3. **FPU is the critical-path lift** for a *complete* 040. Sequence it after the
   ISA/personality (item 1) is finished, using the MC68881 VHDL core as a base.
4. **"80 ns / 256 MB"** are modeled characteristics, not literal DRAM timing —
   the core presents the 33 MHz 68040 bus; the backing store is DDR3/SDRAM.

## Realistic path to the spec (phased)

- **P5a — finish the 68040 personality:** MOVE16 (in progress), 040 exception
  frames, CPU-type reporting. → item 1.
- **P5b — boot chain:** clear the ROM device-probe gates (device pages → RAM
  sizing → RTC → SCSI) so it reaches a desktop in sim. → item 11 (with LC040).
- **P6 — display:** VRAM→SDRAM (2 MB), 16/24 bpp scanout, reconfigurable pixel
  clock + CRTC for 832×624 and 1152×870. → items 5, 6, 7.
- **P7 — storage/boot media:** SCSI HDD + CD/DVD-ROM device, mount OS 8.1 image.
  → items 10, 11.
- **P8 — FPU:** integrate/adapt the MC68881-class FPU. → item 2.
- **P9 — MMU (real) + caches:** table-walk MMU (VM) and 4K+4K caches + burst.
  → items 3, plus authentic 040.
- **P10 — peripherals:** SONIC Ethernet, SWIM floppy + IOP. → items 8, 9.
- **P11 — hardware bring-up:** Quartus fit/timing, PLL lock, on-board test
  (`docs/HARDWARE.md`), 256 MB RAM config. → item 4 + deployment.

This is a large program, but the spec is internally consistent and matches real
Q950 hardware. The current core has the memory map, the CPU integration, and
most subsystems in place and simulation-verified; the gating items are the FPU,
the real MMU, the display depth/timing work, and finishing the ROM boot chain.
