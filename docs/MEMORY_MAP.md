# Quadra 950 Address Map

From Apple's *Quadra 900 Developer Note* (Figures 1-2 / 1-3), identical on the
950. This is what the address decoder in `rtl/quadra950.sv` implements.

| Range | Size | Contents |
|---|---|---|
| `$0000_0000` – … | 64 MB / bank | **RAM** (each bank occupies 64 MB of address space) |
| `$4000_0000` – `$400F_FFFF` | 1 MB | **ROM** (normal location) |
| `$5000_0000` – `$5FFF_FFFF` | 256 MB | **I/O space** (VIA1, VIA2, IOPs, SCC, SCSI ×2, SONIC, sound, YANCC regs) |
| `$9000_0000` – `$EFFF_FFFF` | 256 MB/slot | **NuBus superslot** space (superslots $9–$E) |
| `$F900_0000` – `$FEFF_FFFF` | 16 MB/slot | **NuBus standard slot** space (slots $9–$E) |

### Reset ROM overlay

At reset the **MCU** maps ROM to `$0000_0000` and disables RAM there. On the
first access to `$4000_0000`, it remaps ROM to `$4000_0000` and restores RAM at
`$0000_0000`. The decoder models this with the `rom_overlay` register in
`rtl/quadra950.sv` (currently set at reset; the clear-on-first-ROM-access
handshake is a TODO).

### Built-in video

DAFB registers and the VRAM frame buffer live in the **NuBus slot $9** region:
standard-slot space around `$F900_0000` and superslot space around
`$9000_0000`. The scaffold decodes `$F9xx_xxxx` to the DAFB for now.

### I/O sub-regions (within `$50xx_xxxx`)

Exact offsets come from the developer note; to be filled in as the `iobus`
(JDB+Relayer) decode is implemented:

- VIA1, VIA2
- SWIM IOP (floppy + ADB), SCC IOP (serial)
- SCSI #0 (internal 53C96), SCSI #1 (external 53C96)
- SONIC (Ethernet)
- Sound (ASC / DFAC)
- YANCC control registers

### MiSTer implementation note

Emulated RAM and the ROM image live in **DDR3** on the DE10-Nano, behind the
`mcu` module. VRAM will be either block RAM or a reserved DDR3 region behind
`dafb`. SCSI disks are mounted image files exposed through the `hps_io` block
interface (`sd_lba` / `sd_rd` / `sd_wr` / `sd_buff_*`).
