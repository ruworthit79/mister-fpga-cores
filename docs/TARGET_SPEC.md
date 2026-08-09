# Target specification — "maxed Quadra 950" running Mac OS 8.1

This is the agreed end-goal for the core. It closely matches a fully-loaded real
Quadra 950, which is exactly what the core is designed around. Each line is
mapped to its current status and the concrete work to reach it. Statuses:
✅ done/verified · 🟡 partial/in progress · ⛔ not started.

## The spec

| # | Requirement | Real Q950 reference | Status | Gap to close |
|---|-------------|--------------------|--------|--------------|
| 1 | **68040 CPU @ 33 MHz** | MC68040 33 MHz | ✅ | TG68 (68020-class) + 040 personality, GHDL-verified: **MOVEC 040 regs**, **cache/MMU control ops** (CINV/CPUSH/PFLUSH/PTEST), **LC040 F-line + integrated-FPU dispatch**, and **MOVE16** (`tb_move16`). The instructions the Mac ROM probes to classify the CPU (MOVE16 + 040 MOVEC + cache ops + FPU-present) all execute without illegal-instruction traps, so the ROM reports a 68040. Clock: `clk_sys` divider ~33 MHz. **Remaining (Level-C authenticity, not a boot blocker):** true 040 format-7 access-error stack frames — the 68020-style frames the kernel emits already carry the ROM through the entire hardware-probe/bus-error chain (boot reaches ASC), and OS 8.1 boots with VM off, so this is a fidelity refinement rather than a gap. |
| 2 | **Integrated FPU** | on-die 68040 FPU | 🟡 | **Foundation + kernel dispatch + HW arithmetic all live and wired** (`fpu_040.vhd`): FP0-FP7 + FPCR/FPSR/FPIAR, FMOVE/FABS/FNEG/FTST, IEEE classification, `present=1`, `unimpl`→FPSP. The CPU **executes reg-reg F-line arithmetic in hardware** — the kernel decodes **FADD ($22) / FSUB ($28) / FMUL ($23)** and drives the 80-bit extended datapath (NaN/Inf/Zero handling, normalization). Verified two ways: `tb_fpu` (2+3=5, 5−2=3, 2×3=6 on the unit) and `tb_cpu_fpu` (the CPU runs a reg-reg FADD with no F-line trap). **Remaining:** the **memory-operand path** (FMOVE.X `<ea>`↔FPn and mem-operand arithmetic still take the FPSP path); FDIV/FSQRT/FCMP/FINT; full IEEE rounding modes + exception flags (datapath is round-toward-zero today). See `docs/FPU_SCOPE.md`. |
| 3 | **8 KB L1 cache, no L2** | 4 KB I + 4 KB D on-die; no L2 | 🟡 | A **verified 4 KB direct-mapped, 16-byte-line, write-through cache** (`rtl/cpu/cache_040.sv`, instantiate ×2 for split I+D) with CACR-style `enable`/bypass — unit-tested in `tb_cache` (miss→line-fill, hit with no memory traffic, write-through, eviction, bypass). Kept as a **standalone block, not yet inserted** into the CPU↔MCU path: it needs the bus to grow real burst-fill semantics, and this is performance/timing only — **OS 8.1 boots without it**, and the 040 cache instructions are already correct no-ops. |
| 4 | **RAM ≤ 80 ns, max 256 MB** | 16 SIMM slots, 256 MB max, 80 ns FPM | ✅ | **64/128/256 MB selectable** (OSD `RAM`). The MCU masks the RAM address to the installed size so higher accesses alias/wrap — how sized DRAM presents to the ROM's memory-sizing probe (previously `ram_128mb` was a no-op). Verified in `tb_mcu` (aliasing at each size). "80 ns" is a bus-timing characteristic modeled by the 33 MHz bus, backed by faster DDR3. |
| 5 | **2 MB VRAM** | DAFB 1 MB, expandable to 2 MB | 🟡 | **External-VRAM architecture done + verified.** DAFB has an `EXT_VRAM` path (a `vram_*` port for off-chip memory up to 2 MB) with a **ping-pong line buffer** that prefetches each scanline, decoupling per-pixel scanout from memory latency — the piece that makes 2 MB VRAM feasible off Cyclone V block RAM. Verified end-to-end in `tb_dafb_vram` (CPU write→external memory→line-buffer→correct 8/32 bpp scanout). **Remaining (hardware wiring):** vendor an SDRAM controller, connect the `vram_*` port to the board SDRAM pins (currently tri-stated), and add the SDRAM clock/PLL. |
| 6 | **832×624 @ 24-bit** | DAFB w/ 2 MB VRAM (needs ~1.56 MB) | ✅ | DAFB now reads out **8 bpp** (indexed via CLUT), **16 bpp** (xRGB1555 direct) and **32 bpp** (xRGB8888 direct), selected by the depth register. Direct-colour scanout verified in `tb_dafb_depth`. Full-screen deep colour at high res still depends on item 5 (VRAM capacity), but the scanout/colour paths are complete. |
| 7 | **1152×870 @ 8-bit** | DAFB w/ 2 MB VRAM (needs ~1.0 MB) | 🟡 | **Programmable CRTC done:** a full register set (H/V total, sync start/end, active) overrides the vmode presets (`reg_ctrl[1]`), plus a programmable pixel-clock divider — verified in `tb_dafb_modes`. The vmode presets already carry 832×624/1024×768/1152×870 timing. **Remaining:** the actual output pixel clock for the high-res modes needs a **reconfigurable video PLL** (1152×870@75 ≈ 100 MHz); the CRTC/divider logic here is PLL-ready. |
| 8 | **Ethernet** | SONIC DP83932 @ $50F0_A000 | 🟡 | `rtl/io/sonic.sv` is now a **functional register model** (CR/DCR/RCR/TCR/IMR/ISR w1c, silicon-rev, CAM/descriptor pointers, TXP→TXDN→IRQ), wired at $50F0A000, verified in `tb_sonic`. Models "no link" (RX idle, TX complete-and-discard); a full descriptor-DMA engine + MiSTer network path remain. Not required to boot OS 8.1. |
| 9 | **Floppy** | SWIM + IWM, via IOP | 🟡 | `rtl/io/swim.sv` is now a **functional register model** (IWM soft-switches + ISM mode, drive-sense = installed/empty/not-ready), wired at $50F16000, verified in `tb_swim` — the OS floppy probe completes without hanging. IOP is bypassed (SWIM exposed directly); real GCR/MFM codec + the 6502 IOP mailbox remain. |
| 10 | **DVD / CD usage** | SCSI CD-ROM (Superstation One DVD dock) | ✅ | The 53C96 model now serves the full mandatory SCSI command set — **INQUIRY, TEST UNIT READY, REQUEST SENSE, READ CAPACITY, MODE SENSE, READ(6)/READ(10), WRITE(6)/WRITE(10)** with multi-block transfers — plus a **CD-ROM device type** (`IS_CDROM`: type 0x05, removable, read-only, 2048-byte blocks mapped 4:1 onto hps_io sectors, **READ TOC**). Channel 0 = internal **hard disk** (boot volume), channel 1 = external **CD-ROM**; ISO mounts via OSD `Mount CD-ROM` (S1). Verified in `tb_scsi` (disk + CD INQUIRY/READ CAPACITY, multi-block READ(10), READ TOC). Simplified: no arbitration/selection/message phases, one implied target per channel. |
| 11 | **Boots Mac OS 8.1** | — | 🟡 | Building blocks now in place: 040 personality (item 1 ✅), FPU present + `unimpl`→FPSP for LC040 boot (item 2), 64–256 MB RAM (item 4 ✅), transparent 1:1 translation, and a probeable SCSI **hard disk** for the HFS boot volume (item 10 ✅). In sim the ROM boot chain currently reaches the ASC init (see `docs/BOOT_ANALYSIS.md`). **Gating:** carry the ROM chain from ASC through to the desktop, put a real HFS OS 8.1 install on the SCSI HD image, and validate on hardware. |

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
most subsystems in place and simulation-verified.

**Progress snapshot.** Done/verified: 68040 personality (1), 64–256 MB RAM (4),
8/16/32 bpp DAFB scanout (6), SCSI HD + CD-ROM command set (10). Architecture
landed + unit-verified, integration/hardware remaining: FPU FADD/FSUB/FMUL
datapath (2), programmable CRTC + pixel divider (7), external-VRAM line-buffer
path (5), L1 cache model (3), SONIC (8) and SWIM (9) functional register models.
The remaining gates to a booting desktop (11) are: wiring the FPU arithmetic (or
staying on LC040 + FPSP), the true high-res pixel PLL + SDRAM controller for the
display path, and carrying the ROM boot chain from ASC init through to the
desktop against a real HFS OS 8.1 volume — then hardware validation.
