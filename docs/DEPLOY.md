# Deploy & bring-up — Quadra 950 core on the Superstation One

End-to-end steps to build the bitstream and test it on the Superstation One
(MiSTer / DE10-Nano compatible, Cyclone V `5CSEBA6U23I7`).

## 1. Toolchain

Use **Quartus Prime Lite 17.0.x** (free) — it matches the MiSTer `sys/`
framework and this project's `LAST_QUARTUS_VERSION`, so there is **no project
migration and no IP upgrade**.

- Download Quartus Prime **Lite** 17.0 (17.0.2 update is fine) from the
  Intel/Altera FPGA download archive.
- **Include Cyclone V device support** (select it in the installer, or drop the
  "Cyclone V device support" file into the installer folder before running).
- The `.qsf` pins `17.0.2 Standard Edition`; **Lite 17.0.x builds this fine** —
  a harmless edition-mismatch note may appear.

> Newer Quartus (Lite 21.1 … 25) *can* target Cyclone V but needs a project
> migration + `Project → Upgrade IP Components` (the `altera_pll` v17.0 IP). It
> may work, but 17.0.x is the tested, clean path. Quartus Prime **Pro** cannot
> build Cyclone V at all.

## 2. Build the bitstream

From the repo root:

- **Windows:** open the “Quartus Prime 17.0 Command Prompt” (or
  `set QUARTUS_ROOTDIR=C:\intelFPGA_lite\17.0\quartus`) then `build.bat`
- **Linux:** `./build.sh`
- **GUI:** open `Quadra950.qpf` → Processing → Start Compilation

~15–40 min. Output: **`output_files/Quadra950.rbf`**. (`GENERATE_RBF_FILE` is ON.)

## 3. SD card layout (Superstation One / MiSTer)

1. Copy `output_files/Quadra950.rbf` → **`/media/fat/_Computer/`**
   (rename freely, e.g. `Quadra950_YYYYMMDD.rbf`).
2. Create **`/media/fat/games/Quadra950/`** and put in it:
   - the **1 MB Quadra 950 ROM** (checksum `3DC27823`), and
   - a **boot disk image** — a full bootable **System 7.5 / 8.0 / 8.1 HD image**
     (`.img`/`.dsk`) is ideal; a "Disk Tools" floppy image boots a minimal
     system for a first test.

## 4. On the Superstation One

1. Load the **Quadra950** core.
2. OSD (F12):
   - **Load Quadra 950 ROM** (`F0`) → pick the ROM. The core holds reset, loads
     the 1 MB image, then restarts from it.
   - **Mount SCSI HD** (`S0`) → pick the boot disk image.
   - (optional) **Mount CD-ROM** (`S1`) → an ISO.
   - **Reset**.

Settings persist via NVRAM (PRAM save/restore). OSD also exposes RAM size
(64/128/256 MB) and screen size.

## 5. What to expect (first bring-up is staged)

1. **Video + POST.** A stable video signal, and POST completes in ~1–2 s
   (the ROM's real-time delays that stall the *simulator* run at full 33 MHz
   speed on hardware). Watch the **disk-activity LED** for SCSI reads.
2. **Boot attempt.** Happy-Mac / boot screen as the volume is read, ideally to a
   desktop.
3. **Caveat.** Boot stages after POST (driver load, HFS mount) have only been
   simulated up to the delay wall, so hardware may surface something new — normal
   for bring-up. See `docs/BOOT_ANALYSIS.md` for how far sim got and why.

## 6. Bring-up troubleshooting — capture this

| Symptom | Likely area | Note for follow-up |
|---------|-------------|--------------------|
| No video / no sync | pixel clock / DAFB CRTC | try the 640×480 screen-size setting first |
| Video, gray screen, no chime | early POST / RAM | note if disk LED ever blinks |
| Sad-Mac + code | POST failure | **write down the two hex codes** |
| Happy-Mac then hang | SCSI/HFS boot path | note if disk LED is active |
| Boots to a `?` disk | no bootable volume found | check the S0 image is a bootable HFS volume |

Record: what's on screen, whether the disk LED blinks (SCSI activity), any
sad-Mac code, chime/no chime. A screen photo + those notes pinpoints the stage.

## 7. Status / honesty

This is an engineering bring-up. The real Quadra 950 ROM runs its full POST on
the core in simulation with **zero bus errors** (see `docs/BOOT_ANALYSIS.md`),
and the chip set / memory map are validated against a real board
(`docs/HARDWARE.md`). Reaching a **desktop** has not been demonstrated end-to-end
— that is exactly what this hardware test determines, and issues found here are
fixable on the branch.
