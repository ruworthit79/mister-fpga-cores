# ROM Validation

The design's memory-map and reset assumptions were checked against a real
**Macintosh Quadra 950 ROM** (1 MB, checksum `0x3DC27823`) by disassembling its
boot code and scanning it for hardware base addresses. The ROM itself is
copyrighted Apple firmware and is **not** included in this repository; this
document records only what was learned from it.

## Method

- Verified the image: 1,048,576 bytes; the stored checksum at offset 0
  (`0x3DC27823`) equals the sum of all 16-bit words from offset 4 — an intact,
  genuine dump.
- Disassembled the reset path with a 68k disassembler (Capstone M68K).
- Scanned the whole image for 32-bit big-endian occurrences of candidate
  hardware base addresses to confirm the I/O map.

## Findings

### Reset / overlay — CONFIRMED
- Reset vector is read from low memory: **SP = ROM[0]**, **PC = ROM[4] =
  `0x0000002A`**, which does `jmp` to the boot code at ROM offset `0x8C`; the
  first instruction there is `move.w #$2700, sr` (supervisor, interrupts
  masked). This matches the core's overlay design exactly (ROM mapped at `$0`
  at reset; SP@0 / PC@4).
- ROM is referenced at `$40000000` (124×) and mirrored at `$40800000` (17×).
  The core's overlay-clear on first `$40xxxxxx` access, and its ROM address
  decode, both cover this.

### I/O map — CONFIRMED, with corrections applied
Scanning for aligned base addresses gave a clean device map, now reflected in
`rtl/quadra950.sv` / `rtl/chipset/iobus.sv`:

| Device | Address | Status |
|---|---|---|
| I/O space | `$50000000` | ✅ matched `sel_io = addr[31:24]==0x50` |
| VIA1 | `$50F00000` | ✅ matched (decode by `~addr[13]`) |
| VIA2 | `$50F02000` | ✅ matched (decode by `addr[13]`) |
| SCC (serial) | `$50F04000` | noted (IOP, not yet implemented) |
| SONIC (Ethernet) | `$50F0A000` | noted (stub) |
| SCSI (internal) | `$50F10000` | ✅ **corrected** (was `$50F1xxxx`, now `$50F10000`) |
| ASC (sound) | `$50F14000` | ✅ **corrected** (was `$50F3xxxx`) |
| DAFB (video) | `$F9000000` | ✅ matched `sel_dafb = addr[31:24]==0xF9` |
| NuBus | `$60000000` | ✅ within `sel_nubus` |

### Byte lane — RESOLVED
VIA/SCSI/ASC registers sit at 4-byte-aligned addresses (VIA registers are
`base + reg*0x200`). Our RTL models the 68040's own 32-bit data bus, and for a
byte access to a 4-aligned address the 68040 drives/reads that byte on
**D31–D24** (big-endian). The device connections were moved from `[7:0]` to
`[31:24]` accordingly (`cpu_wrapper` already places byte write-data there).

## Still open / uncertain
- **Second SCSI channel** address: only `$50F10000` is confirmed; the external
  53C96 is placed tentatively at `$50F12000` and needs confirmation.
- **VIA register-to-function mapping** (which port bit is overlay/sound/RTC
  data-clock-enable) and the **RTC command encoding** were not exhaustively
  traced; they follow the "Guide to the Macintosh Family Hardware" and remain
  to be verified against boot behaviour.
- The **machine ID / Gestalt** check (Quadra 950 = 26) is expected in the boot
  path; satisfying it fully depends on the CPU/ROM interaction, which needs a
  full-system (mixed-language) simulation to observe.
