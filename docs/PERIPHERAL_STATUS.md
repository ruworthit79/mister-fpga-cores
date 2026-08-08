# Peripheral status & build-out plan

Status of every peripheral RTL block against the Quadra 950 target spec
(`docs/TARGET_SPEC.md`). "Wired" = instantiated in `rtl/quadra950.sv` and
exercised by the boot ROM in the full-system sim. "Manifest-only" = compiled by
`files.qip` (so it synthesizes) but not yet instantiated — reserved for the
OS-era peripherals the boot ROM does not touch during POST.

## Boot-critical (wired, verified)

| Block | File | Base | Tests | Notes |
|-------|------|------|-------|-------|
| VIA1 | `chipset/via.sv` | `$50F00000` | Icarus `tb_via` | Timer2, SR, IFR/IER; **port-A inputs pulled high** (STM-divert fix) |
| VIA2 | `chipset/via.sv` | `$50F02000` | Icarus `tb_via` | µC handshake (PA=0xFF idle, PB1 ack/PB2 strobe) |
| iobus | `chipset/iobus.sv` | `$50Fxxxxx` | Icarus | alias-tolerant VIA decode; SCC status; IRQ priority |
| MCU/DDR3 | `chipset/mcu.sv` | RAM/ROM | Icarus `tb_mcu` | overlay clear, 32-bit bus, burst |
| Caboose | `chipset/caboose.sv` | VIA1 PB | Icarus `tb_caboose` | RTC/PRAM serial (bit0 data/bit1 clk/bit2 enb) |
| DAFB | `video/dafb.sv` | `$F9000000` | Icarus `tb_dafb`(+modes) | framebuffer, programmable CRTC, VBL→VIA1 CA1 |
| ASC | `audio/asc.sv` | `$50F14000` | Icarus `tb_asc` | FIFO + DFAC; reached during POST |
| SCSI | `io/scsi_ncr53c96.sv` | `$50F10000` | Icarus `tb_scsi` | NCR 53C96 datapath |
| ADB | `io/adb.sv` | via IOP | Icarus `tb_adb` | keyboard/mouse |
| CPU | `cpu/*` | — | GHDL (6) | TG68 kernel + 68040 personality + FPU |

## OS-era (manifest-only stubs — not touched by POST)

| Block | File | Base | Lines | Build-out priority |
|-------|------|------|-------|--------------------|
| SONIC Ethernet | `io/sonic.sv` | `$50F0A000` | 33 | Med — DP83932, needs MAC + DMA to DDR |
| SWIM floppy | `io/swim.sv` | `$50F0C000` | 32 | Low — 1.44 MB MFM, needs disk image plumbing |
| IOP (6502) | `io/iop.sv` | `$50F04000` | 40 | Med — ADB/serial I/O processor microcode host |
| YANCC NuBus | `chipset/yancc.sv` | slot space | 38 | Low — only needed for NuBus cards |

These are decoded as "no device" today; they read back benign values and do not
block boot. They are wired into `files.qip` so the project synthesizes and so the
instantiation points exist when build-out begins.

## Recommended build-out order (post-boot)

1. **Reach a startup device first** — finish the boot chain so the ROM looks for a
   bootable SCSI volume; that makes SCSI the first peripheral to harden with a
   real disk image (already has a datapath).
2. **SWIM** or **SCSI CD** for install media.
3. **SONIC** for networking once the OS is up.
4. **YANCC/NuBus** last (optional expansion).
