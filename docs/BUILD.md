# Building & running the Quadra 950 core on the Superstation One

The Superstation One is a MiSTer-compatible board (Intel Cyclone V, same
`5CSEBA6U23I7` device family and pinout as the DE10-Nano), so this core builds
with the standard MiSTer toolchain and runs from the MiSTer menu.

## 1. Prerequisites

- **Quartus Prime 17.0.x** (Standard or Lite — free). The project pins
  `LAST_QUARTUS_VERSION = "17.0.2 Standard Edition"` and the bundled MiSTer
  `sys/` framework targets this version. Newer Quartus will offer to migrate the
  project; that usually works but 17.0.x is the tested baseline.
- A Linux or Windows host. ~2–4 GB RAM free, ~15–40 min compile time.
- The **Quadra 950 ROM** image (1 MB, e.g. checksum `3DC27823`). Not
  redistributable — supply your own dump. Needed at runtime, not build time.

## 2. Build

From the repo root:

**Linux / macOS (or Git Bash / WSL on Windows):**

```bash
./build.sh              # full compile -> output_files/Quadra950.rbf
./build.sh clean        # remove build artifacts
```

**Windows (Command Prompt / PowerShell):**

```bat
build.bat               :: full compile -> output_files\Quadra950.rbf
build.bat clean         :: remove build artifacts
```

Run `build.bat` from the **"Quartus Prime <ver> Command Prompt"** shortcut (it
puts `quartus_sh` on PATH), or from a normal prompt after
`set QUARTUS_ROOTDIR=C:\intelFPGA\17.0\quartus`.

**Any OS (GUI):** open `Quadra950.qpf` in Quartus and
**Processing → Start Compilation**.

Both scripts run the same underlying flow, `quartus_sh --flow compile Quadra950`.
Quartus itself is cross-platform (Windows and Linux); the project files, relative
paths, and the MiSTer `sys/` framework are identical on both.

The project is wired for a hands-off build:

- `Quadra950.qsf` sources `sys/sys.tcl`, `sys/sys_analog.tcl`, and `files.qip`.
- `files.qip` lists all core RTL (CPU: TG68 kernel + `fpu_040` + `cpu_wrapper`;
  chipset/video/audio/io) and the system PLL (`rtl/pll.qip`).
- `build_id.v` is generated automatically by the `PRE_FLOW_SCRIPT_FILE`
  (`sys/build_id.tcl`) — no manual step.
- `GENERATE_RBF_FILE ON` produces the MiSTer-loadable `.rbf`.

**Output:** `output_files/Quadra950.rbf`.

## 3. Deploy to the board

1. Copy `output_files/Quadra950.rbf` to the SD card under
   `/media/fat/_Computer/` (rename however you like, keeping `.rbf`).
2. Put the Quadra 950 ROM somewhere on the card, e.g.
   `/media/fat/games/Quadra950/quadra950.rom`.
3. (Optional) SCSI disk images — raw `.img`/`.hd`/`.vhd`/`.dsk` — for the two
   SCSI targets.

## 4. Run

1. Select **Quadra950** from the MiSTer menu.
2. In the core's OSD:
   - **Load Quadra 950 ROM** → pick your `.rom`. The core holds reset during the
     download and boots fresh from the new ROM when it completes.
   - **Mount SCSI0 / SCSI1** → attach disk images (once you have a bootable
     volume).
   - **RAM** → 64 / 128 / 256 MB; **Screen size** → 640×480 … 1152×870;
     **Aspect ratio** → Original / Full.
3. Keyboard and mouse map to ADB via the standard MiSTer PS/2 translation.
4. PRAM (NVRAM) is saved/restored through the MiSTer save-file mechanism
   (ioctl index 2).

## 5. What to expect

The core runs the real Quadra 950 ROM power-on self-test. As of this writing it
clears machine identification, the ROM checksum, the SCC/serial and VIA setup,
and the **POST/STM decision** (the earlier boot-blocker, fixed — see
`docs/BOOT_ANALYSIS.md`), then proceeds into the ROM's hardware-timed
initialization (ASC sound-chip setup and other settling delays).

Those delays are the reason full boot could not be verified in the
cycle-accurate simulator (they cost billions of simulated cycles) — **on real
hardware they cost microseconds**, which is exactly why on-board bring-up is the
right place to carry boot forward from here. First-build checks: PLL lock, timing
closure (`output_files/*.sta.rpt`), HDMI/VGA sync, then walk the boot on silicon.

## 6. Notes / limitations

- CPU is a TG68 (68020-class) kernel with a 68040 personality (MOVEC 040 control
  regs, cache/MMU instructions as no-ops, MOVE16, structural FPU). It cleared
  POST; heavier 68040/FPU conformance is future work (`docs/PHASE5_SCOPE.md`).
- Main RAM and the ROM image live in DDR3; SDRAM and the secondary SD are unused
  (pins tri-stated).
- Peripheral coverage and the post-boot build-out order are in
  `docs/PERIPHERAL_STATUS.md`.
