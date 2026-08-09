# DAFB II register map (Quadra 950)

The Quadra 950 uses the **DAFB II** ASIC (Apple part `343S0128-A`). This is the
hardware register layout the core's `rtl/video/dafb.sv` targets, so the real Mac
ROM / Mac OS video driver can program it.

**Sources (authoritative, reverse-engineered):**
- MAME `src/mame/apple/dafb.cpp` — exact offsets, masks, clock state machine.
- Linux m68k `drivers/video/macfb.c` — layout + palette programming.
- *Guide to the Macintosh Family Hardware* (DAFB chapter) / Apple Quadra 950
  Developer Note — clock domains, pinouts, bus timing.

## Address layout

Registers occupy four 256-byte blocks, **4-byte register spacing** (register
index `n` at byte offset `n<<2`). Register base is `$F980_0000` (also mirrored in
the `$50Fx` I/O space); the VRAM framebuffer aperture is separate.

| Block | Range | Function |
|-------|-------|----------|
| 0 | `+0x000`–`+0x0FF` | DAFB control |
| 1 | `+0x100`–`+0x1FF` | SWATCH programmable CRTC (timing) |
| 2 | `+0x200`–`+0x2FF` | RAMDAC / CLUT (AC842A-class) |
| 3 | `+0x300`–`+0x3FF` | Clock (dot-clock synthesizer) |

### Block 0 — control (`+0x000`)
| Offset | R/W | Meaning |
|--------|-----|---------|
| `+0x00` | RW | Frame-buffer base, high bits (20:9) |
| `+0x04` | RW | Frame-buffer base, low bits (8:5) |
| `+0x08` | RW | Line stride (in 32-bit words) |
| `+0x0C` | RW | Timing control |
| `+0x10` | RW | Config (bit3 convolution, bit2 interlace) / VBL int clear |
| `+0x1C` | R  | Monitor sense (3-bit monitor-ID lines) |
| `+0x24` | RW | **Turbo SCSI** channel-1 status (discrete DAFB / Q950 only) |
| `+0x28` | RW | **Turbo SCSI** channel-2 status (discrete DAFB / Q950 only) |
| `+0x2C` | R  | Test/version — bits 11:9 = DAFB version; **DAFB II = 3** |

### Block 1 — SWATCH CRTC (`+0x100`)
Fully programmable timing (the "Swatch" engine), unlike the fixed-index video of
simpler Mac chips: horizontal active-start / front-porch / total and the vertical
equivalents, plus VBL/cursor interrupt enable+status and cursor/animation lines.
Exact sub-offsets follow MAME `dafb.cpp` (register index `<<2` within the block).

### Block 2 — RAMDAC / CLUT (`+0x200`)
| Offset | Meaning |
|--------|---------|
| `+0x00` | Palette **write index** (0x00–0xFF) |
| `+0x10` | Palette **data** — sequential **R, G, B** byte writes; index auto-increments after B |
| `+0x20` | PBCTRL — pixel depth select |

Depth codes (PBCTRL): `1bpp / 2bpp / 4bpp / 8bpp (indexed) / 16bpp x555
("thousands", DAFB-II-only) / 24bpp (direct "millions")`.

### Block 3 — clock (`+0x300`)
Dot-clock synthesizer select (e.g. ~30.24 MHz for 640×480-class modes up to a
~100 MHz source for 1152×870). On real silicon this is a serial-shift PLL
(DP8531 on discrete DAFB); the FPGA equivalent is a reconfigurable pixel PLL
(see TARGET_SPEC item 7).

## Turbo SCSI

The Q950's discrete DAFB II wraps Apple's **Turbo SCSI** logic between the 68040
bus and the two onboard **NCR 5396** SCSI controllers: it inserts programmable
wait-states and asserts `DTACK` during pseudo-DMA, giving fast disk transfer
without a full DMA engine. The status registers live at control `+0x24/+0x28`.
The core models the SCSI controllers directly (`rtl/io/scsi_ncr53c96.sv`) at the
$50F1xxxx I/O aliases rather than through the DAFB Turbo-SCSI wrapper — a
documented simplification.

## Core status vs this map

`rtl/video/dafb.sv` implements the four-block structure, the index+data RAMDAC
CLUT, the DAFB-II version register, monitor sense, the programmable SWATCH-style
CRTC, and 8/16/32-bpp scanout. Exact depth codes and SWATCH sub-offsets follow
MAME where documented; anything not yet validated against a real ROM is flagged
in the source. Confirming the precise base placement and depth-code values needs
a Quadra 950 ROM run (see docs/BOOT_ANALYSIS.md).
