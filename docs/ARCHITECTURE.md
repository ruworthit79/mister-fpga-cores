# Macintosh Quadra 950 — Hardware Architecture

This document is the reference specification the core is built against. Facts
are taken primarily from Apple's own *Macintosh Quadra 900 Developer Note* and
*Quadra 950 Developer Note* (the 950 note is a short "delta" over the 900),
cross-checked against EveryMac and the MAME `macquadra700.cpp` driver (which
covers the 700/900/950).

> **Important naming correction.** Many online sources (including some wikis)
> claim the Quadra 900/950 use the **djMEMC** memory controller and **IOSB**
> I/O chip. That is **wrong** — those are the *later* "Wombat" ASICs of the
> Centris/Quadra **610/650/800**. The 900/950 use an earlier set of discrete
> custom chips named below (MCU, JDB+Relayer, YANCC, DAFB, IOPs, Caboose).

The Quadra 950 (March 1992 – Oct 1995) is a speed-bumped Quadra 900. Relative
to the 900 it changes only: 33 MHz CPU (vs 25), 80 ns VRAM (vs 100) with a
reprogrammed DAFB, 16-bpp on large monitors, a faster 24.28 MHz I/O bus, and a
25 MHz SONIC. Everything else is identical. Gestalt machine type = 26.

---

## CPU

| Property | Value |
|---|---|
| Model | Motorola **MC68040** |
| Clock | **33.33 MHz** system/bus clock (internal logic 2× = 66.67 MHz; **not** a clock-doubled 040 — effective rate 33 MHz) |
| L1 cache | **4 KB instruction + 4 KB data**, on-die, copyback capable (secondary sources say "8 KB" = the 4+4 total). No L2. |
| FPU | **On-die** (not an external 68881/2) |
| MMU | **On-die** dual paged MMUs (instruction + data); not a 68851 |

The 68040's bus is a 32-bit non-multiplexed **synchronous** bus with a
TS/TA/TEA handshake and burst (line) transfers — substantially different from
the 68000/020 asynchronous DTACK bus. This matters for CPU integration (see
[CPU_NOTES.md](CPU_NOTES.md)).

---

## Memory

| Property | Value |
|---|---|
| RAM base | 8 MB typical (US); some EU units 4 MB |
| RAM slots | **16× 30-pin SIMM slots**, 4 banks × 4 SIMMs (four 8-bit SIMMs = one 32-bit bank) |
| SIMM spec | 30-pin, **80 ns** fast-page-mode DRAM; 1/4/16 MB sizes |
| Max RAM | **64 MB** documented by Apple (4 MB SIMMs); **256 MB** reachable with third-party 16 MB SIMMs |
| ROM | **1 MB** (two 256K×16, 150 ns), base `$4000_0000`, ROM SIMM socket for expansion |
| VRAM | **1 MB standard, 2 MB max**, 4 VRAM SIMM banks, **80 ns** |

---

## Custom chips / ASICs (real 900/950 silicon)

| Function | Real part(s) | Notes |
|---|---|---|
| Memory controller | **MCU** (Memory Control Unit) | RAM/ROM timing, 68040 burst, bank base regs, reset ROM overlay |
| I/O bus adapter | **JDB** (Junction Data Bus) + **Relayer** | Bridge system bus → IIfx-style I/O bus; JDB = data path, Relayer = chip-selects/DSACK/arbitration |
| NuBus controller | **YANCC** ("Yet Another NuBus Controller Chip") | + two 16-bit transceivers |
| Video | **DAFB** (Direct Access Frame Buffer) | Built-in framebuffer + programmable CRTC, reprogrammed for 80 ns VRAM/16 bpp in the 950 |
| I/O processors | two **IOPs** (6502-based) | One drives SWIM (floppy) + ADB; the other drives the SCC (serial) |
| RTC / PRAM / power | **Caboose** (68HC05 family) | RTC, PRAM, power, keyswitch. **Not** the ADB manager. MAME substitutes its `egret` device for it. |
| Sound | **Enhanced ASC** + **DFAC** + **Sporty** | ASC = playback, DFAC = input/filter/ADC, Sporty = output amp |

---

## Video (DAFB)

- Built-in framebuffer on the system bus (no NuBus card); 4 VRAM banks;
  performance approaching the Macintosh Display Card 8•24GC.
- **RAMDAC:** Apple custom CLUT/DAC (same family as Apple's Display Card
  4•8 / 8•24 / 8•24GC) — not a stock Brooktree part per Apple's docs.
- **Depths / resolutions (950):**
  - **1 MB VRAM:** up to 24 bpp on 12″ RGB; 16 bpp on 13″/16″ RGB; 8 bpp on 21″.
  - **2 MB VRAM:** 24 bpp on 12″/13″/16″ RGB; 16 bpp on 21″ and 19″ (1024×768).
  - Range 512×384 → 1152×870; VGA; NTSC/PAL via Apple convolution.
  - Headline 950 addition: **16-bpp ("Thousands") on large monitors**.

Common Apple timings to implement: **640×480, 832×624, 1024×768, 1152×870**.

---

## SCSI

- **Dual channel**: **two NCR/AMD 53C96** controllers (internal + external,
  electrically isolated), SCSI-2 class, ~5 MB/s internal, external DB-25.
- Note the well-known **53C96 FIFO-retention quirk** the 700/900/950 SCSI
  Manager depends on — must be modelled for correct behaviour.

## Sound

- **Enhanced ASC**: 4-channel, 8-bit playback at **~22.257 kHz**; output as
  8-bit stereo.
- **DFAC**: mono record path (mic / line / internal CD) with anti-alias + ADC.
- **Sporty**: output amplifier. 3.5 mm mono in / stereo out.

## Floppy

- **SWIM** controller (driven via the SWIM IOP) + **Apple SuperDrive** 1.44 MB HD.

## ADB (keyboard / mouse)

- Managed by an **IOP + ADB transceiver** (the IIfx approach), **not** by
  Egret/Cuda. Host-polled single-wire bus; keyboard default addr `$2`, mouse `$3`.

## Ethernet

- **Built-in** on the I/O bus (not NuBus), **AAUI** connector (external
  transceiver for 10BASE-T etc.).
- Chip: **National Semiconductor SONIC DP83932** — the **25 MHz** version in
  the 950.

## NuBus

- **5 NuBus slots** ($A–$E) + built-in video in the slot **$9** region, plus
  **one 68040 PDS** (must meet 33 MHz timing).
- NuBus '90 partially supported (20 MHz 2× clock, block/pseudo-block).
- Bridged by **YANCC** + two 16-bit transceivers (1-longword write buffer,
  write-error interrupt).

## Real-time clock / PRAM

- Managed by **Caboose**, backed by a 3.6 V lithium battery. Mac epoch =
  1 Jan 1904.

---

## Sources & reliability

- **Apple Quadra 900 / 950 Developer Notes** — primary and authoritative;
  source for all chip names, caches, the address map, and video depth tables.
- **EveryMac** — reliable for consumer specs (slot power, connectors, the
  256 MB third-party figure, the "not clock-doubled" clarification).
- **MAME `macquadra700.cpp`** — cross-check; instantiates DAFB (`DAFB_Q950`),
  DFAC @ 22257 Hz, SWIM, NCR53C96, VIAs; does **not** use djMEMC/IOSB for these
  machines (confirming the developer-note architecture).

### Known conflicts
1. **Max RAM:** 64 MB (Apple) vs 256 MB (third-party). Both physically valid.
2. **Chip naming:** MCU / JDB+Relayer (correct for 900/950) vs djMEMC/IOSB
   (wrong — those are Centris/Quadra 610/650/800).
3. **ADB manager:** IOP (correct) vs Egret/Cuda (wrong for this machine).
