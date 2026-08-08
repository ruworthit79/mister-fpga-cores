# Boot analysis — where the real Quadra 950 ROM stops, and why

This documents the exact point at which the real ROM stalls in the full-system
Verilator harness (`sim/verilog-full/boot_top.v`), reverse-engineered from the
ROM itself with a Capstone m68k disassembler. It is the single source of truth
for "what does the ROM need next to boot further."

## Summary

Boot is **deterministic** and stops in the ROM's **universal machine
identification** ("DecoderInfo" / box-ID) scan. The CPU is healthy: reset
vector, overlay clear, and VIA bring-up all succeed with **zero exceptions**.
The stall is not a CPU bug and not a hang — it is an *infinite retry* of the
identity probe because the machine never recognizes itself as a Quadra 950.

```
reset ─► $8C ─► main $4052 ─► … ─► identity scan  ◄──────────┐
                                     │                        │
             dispatch $31ac ─► VIA-pin probe $47AE ─► compare │
                against box-ID tables $31C4 / $31C8           │
                                     │                        │
                              no match → default $2F52 ────────┘  (re-probe)
```

## The identity loop (ROM addresses)

- **`$2F7C..$2F8A`** — byte-compare table walk over `$31C8`
  (`cmp.b $13(a1),d2`); on no match it reaches the 0 terminator and falls to…
- **`$2F52..$2F62`** — default dispatch through the self-relative list at
  `$31AC` (`adda.l (a1)+,a0 ; jmp (a0,a2.l)`).
- **`$3154..$317A`, `$46AA..$46B2`, `$3DEC..$3DF2`** — dispatch glue.
- **`$47AE`** — the VIA-pin probe (see below); assembles the identity word
  `d1` from live port pins.
- Result compared against two self-relative tables:
  - **word table from `$31C4`** — `cmp.w $12(entry),d2`, entries at `$36BC`+
    (0x40 bytes each).
  - **byte table from `$31C8`** — `cmp.b $13(entry),d2` then `and.l $20(entry),d0`.

Because no candidate matches, the scan loops forever. In sim it runs a
value-independent, fixed number of iterations per unit time (≈259K fetches per
4M sim clocks), never reaching machine init (`drew=0`, no Happy-Mac path).

## What the probe reads — `$47AE`

`$47AE` reads a VIA base (`a1 = $8(a0)`, taken from the active DecoderInfo)
and assembles the identity from **port A and port B input pins**, using a
DDR-manipulation read so it samples the *external* pin levels:

```
d2 = VIA[reg15 ORA-noHS]:VIA[reg3 DDRA]      ; save
VIA[reg3 DDRA]  = DDRA & mask(-0xC(a0))      ; force our pins to INPUT
d1(hi) = VIA[reg15 ORA-noHS]                 ; <-- sample port-A input pins
restore DDRA, ORA
d2 = VIA[reg0 ORB]:VIA[reg2 DDRB]            ; save
VIA[reg2 DDRB]  = DDRB & mask(-0xB(a0))      ; force our pins to INPUT
d1(lo) = VIA[reg0 ORB]                       ; <-- sample port-B input pins
restore DDRB, ORB
swap d1                                       ; identity word in d1 high half
```

A second block (`$47FC` onward, gated by `btst #$B,d0`) does the same on a
second VIA, filling `d1`'s low half. The compare then does `d0 = d1 &
$20(entry)` and matches against the table.

**Consequence:** the machine signature lives on the VIA1/VIA2 **port-A/B input
pins**, masked per-candidate. In this core those pins are tied to 0
(`iobus.sv`: `pa_in(8'h00)`, `pb_in(8'h00)`), so `d1 = 0`, which matches no
Quadra candidate.

## Box-ID tables (extracted from the ROM)

Word table from `$31C4` — each entry's discriminator is `machine:class`
(`[+0x10] = $DC00_MMCC`, `[+0x12] = $MMCC`; `[+0x18]` is a hardware-config /
slot field):

| entry  | code `$12` | `[+0x18]` cfg | note                         |
|--------|-----------|---------------|------------------------------|
| 0036BC | 0304      | 00001F3F      | class 04                     |
| 0036FC | 0204      | 00001F3F      | class 04                     |
| 00373C | 0505      | 0000773F      | class 05                     |
| 0037BC | 0706      | 00000000      | class 06                     |
| 00383C | 0D07      | 0000773F      | class 07                     |
| 0038FC | 1008      | 05A0183F      | class 08 (5-slot NuBus)      |
| 00387C | 0E08      | 07A31807      | class 08 — **Quadra 900/950**|
| 0038BC | 1408      | 07A31807      | class 08 — **Quadra 900/950**|
| 00393C | 0F09      | 00401F3F      | class 09                     |
| …fdXX  | default   | 00000000      | per-class fallbacks          |

`$0E08` and `$1408` share the identical hardware-config word `07A31807`,
consistent with the Quadra 900 and Quadra 950 being the same NuBus board at
different clocks. One of these is the target identity.

## Experiment run (negative result)

Drove `pa_in`/`pb_in` on both VIAs to `0xFF` and unmapped I/O to `0xFFFFFFFF`
(scratch build). Result was **byte-identical** to the all-zero build (258,850
fetches, same loop). Interpretation: neither all-0s nor all-1s matches the
Quadra candidate's masked signature — convergence needs the *exact* per-candidate
pin pattern, not merely non-zero pins.

## Detection is a candidate-probe chain (deeper trace)

The identity scan is not one test but a **chain of hardware-probe candidates**
tried in order (self-relative list at `$31AC`: offsets `$460, $3B8, $124,
$1C4, $264, $304, …`). Each candidate points at a `DecoderInfo` record and a
probe routine; the first whose probe *succeeds* fixes the machine, then the
box-ID tables above pick the exact model. Detection is therefore two-level:
a probe identifies the **chip family**, then `$47AE` (VIA pins) selects the
**model** within it.

- **`$31AC` candidate #1** → `DecoderInfo @ $360C` → probe `$3162`. The
  DecoderInfo is a device-base map: `+$08 = $50F0_0000` (VIA1),
  `+$0C = $50F0_4000` (SCC), `+$20 = $50F1_0000` (SCSI), `+$2C = $50F0_2000`
  (VIA2), `+$30 = $50F1_4000` (ASC), `+$58 = $50F8_0000`.
- **Probe `$3162`** read/write-tests `[$08(a0)]+$1C00 = $50F0_1C00`, which is
  **VIA1 register 14 = IER**, via helper `$46AA`.
- **Helper `$46AA`** is a register-behaviour + **address-aliasing** test: it
  writes walking patterns to `(a2)` and reads them back, and it does
  `tst.b/cmp.b (a2, d2.l)` with `d2 = $100000 / $80000 / $40000` — comparing the
  register against its images at `+$100000` etc. This is what generated the
  `$5100_1C00` access seen at runtime (`$50F0_1C00 + $100000`). The result
  (aliased vs not, and how many bits behave) distinguishes machines.

So convergence needs the probed registers to reproduce the **real Quadra 950
decode/aliasing behaviour**, not just hold a value.

## Fix applied: full I/O-space decode ($5x), bus errors eliminated

`quadra950.sv` decoded I/O as only `$50xx_xxxx` (the first 16 MB), so every
high alias the probe reads (`$5100_1C00`, …) bus-errored. But the I/O space is
the whole `$5000_0000–$5FFF_FFFF`, and real Macs decode it incompletely (wide
aliasing). `sel_io` was widened to `cpu_addr[31:28]==4'h5`. Effect in the
full-system harness: **bus errors during detection went 10 → 0**, `$5100_1C00`
now acks, and fetches advanced (258,850 → 276,821). The probe no longer faults;
it still loops because the *aliasing pattern* our decode presents does not yet
match what the Quadra 950 candidate expects (VIA images at `$50F0_1C00` vs
`$5100_1C00` differ, since `+$100000` lands at `addr[23:16]=$00`, outside the
VIA's `$F0` decode).

## RESOLVED: machine-ID gate passed via alias-tolerant VIA decode

Instrumenting the decision path showed candidate #1 (`$3162`) failing at
`$3178` (`bne $2f58`): its `$46AA` probe read/write-tests VIA1 IER at
`$50F0_1C00` **and** compares it against the image at `+$100000 = $5100_1C00`.
Because our VIA decoded only the exact `$50F0` page, the alias read differed and
the candidate failed. Modelling the Quadra's real **incomplete I/O decode** —
VIA selected on the register-page pattern `addr[19:14]==0` with `addr[23:20]`
treated as don't-care, so the VIAs alias every `$10_0000` — makes the alias
respond identically. Result in the full-system harness:

- Candidate #1 now **passes** the full `$46AA` sequence
  (`$3178→$317C→$3186→$318A→$3194→$3198→$31A0`), runs the `$47AE` model probe,
  and reaches the **table-match path** `$2F30→$2F3A→$2F44` — the ROM identified
  the machine (Quadra family; DecoderInfo `@ $360C`, whose device bases match
  the documented Q950 map).
- Boot **advances past detection** into device configuration: it now probes the
  further DecoderInfo device pages (`$50F8_xxxx`, `$50F4_xxxx`, …). Fetches
  259K→300K, `berr=0`, last PC in the ROM image (`$40800000+`).

Fix committed in `iobus.sv` (`in_via = addr[19:14]==0`). All eight Icarus unit
tests and the three GHDL CPU tests still pass.

## RESOLVED: cache-enable — 68040 CACR fix

After identification the ROM ran the post-detection routine at `$4640`, which
does `MOVEC` to **CACR setting bit 31 (68040 data-cache enable, DE)** and bit 15
(IE), then reads CACR back to verify. The kernel's CACR was 68020-style (4 bits,
read-masked), so the 040 enable bits were lost and boot stalled re-running the
cache/probe code (the `$4080_46xx` `$46AA` loop, ~88 K I/O accesses).

Fix: make CACR 68040-accurate — 32-bit, storing/returning DE (bit31) + IE
(bit15). No real cache exists, so the bits simply round-trip. Effect: boot
advances past the cache loop, I/O-loop traffic drops **88832 → 3476**, last PC
`$408046B2 → $40847516`.

## Current boot frontier: ROM checksum (a normal step, not a gate)

`$40847516` is the **ROM checksum loop** (`$47504` sets up a ROM base + length,
then `$47516`: `move.w (a0)+,d0 ; add.l d0,d1 ; subq #2,d3 ; bne` sums every ROM
word and compares to the stored checksum at `$47522`). This is legitimate
early-boot work, not a stall — it just sums 512 K+ words, so it needs **~2M+
CPU fetches**. The full-system Verilator harness (`--timing` + the ~36 K-line
converted CPU netlist) runs at only ~300 K fetches per ~25 min wall-clock, so it
cannot brute-force through the checksum in a practical sim run. On real 25–50 MHz
hardware the checksum completes in a fraction of a second.

So the boot sequence now verified in sim is:
**reset → overlay clear → machine-ID (Quadra) → 040 cache enable → ROM
checksum**, all with `berr=0` and zero unexpected exceptions — each step
unblocked by a correct 68040 behaviour (I/O aliasing, CACR).

## RESOLVED: sim throughput — fast harness runs THROUGH the checksum

The `--timing` harness was too slow (~200 K fetches in 55 min) to pass the
~1.4M-fetch checksum. Added a **fast harness** (`sim/verilog-full/run_fast.sh`,
`boot_core.v` + `sim_main_full.cpp`): the full core as a clock-input module (no
`#` delays) built by Verilator **without `--timing`**, driven by a C++ clock
loop — **~30× faster** (4M cycles in ~12 s). Boot now runs cleanly **through the
checksum** (~1.4M fetches) and into **ROM initialization** (a sequential
ROM-data scan `$8b000→$eb000+`), `berr=0`, no stalls.

## Current frontier: SCC (Z8530) serial init — being addressed

After the checksum + init scan, boot settles into a tight loop at ROM
`$4AEBA–$4AEC8` (stuck ~12M fetches):
```
$4AEBA: move.w #1,d0 ; move.b d0,$2(a3,d3) ; btst #0,$2(a3) ; beq $4AEBA
```
`a3 = DecoderInfo+$C = $50F0_4000` = the **SCC (Zilog Z8530)**. The routine
writes a WR config table (`$4AE64`+) then polls a read register's bit 0 (All
Sent / transmitter idle). The SCC was stubbed (reads 0), so the bit never sets
and init loops forever.

**Fix (in `iobus.sv`):** a minimal SCC status model — the Z8530 register-pointer
two-step access, returning RR0 = Tx Buffer Empty and RR1 = All Sent (no real
serial link), on the correct big-endian byte lane. Expected to release the SCC
init loop so boot continues to the next stage.

## RESOLVED: SCC init — `ack` was double-toggling the Z8530 register pointer

The first SCC status model still failed: reads returned RR0 (`0x04`) when the
ROM expected the pointed register. Root cause was **not** the SCC model but the
iobus **acknowledge**: the read mux used a self-clearing `ack` (`ack<=0` default,
set on `sel & ~ack`), so while the CPU held `sel` across a multi-cycle access
`ack` oscillated `0→1→0→1`. The SCC pointer update is gated on
`(scc_ctrl & sel & ~ack)`, so it fired on every ack-low cycle and toggled the
Z8530 pointer twice per access. Fix: make `ack` **level-held** — assert on the
first cycle, hold while `sel`, drop only when `sel` deasserts — so the pointer
update and the latched `dout` each happen exactly once. (Isolated Icarus SCC
test now reads RR1 = All Sent; VIA machine-ID reads unaffected.)

### What the SCC loop actually is (disassembly, not a guess)

Disassembling `$4A9FE`/`$4AF9E` shows the loop is the ROM's **serial-receive
poll**, not an "All Sent" wait: `$4AF9E` reads RR0 bit0 (Rx Char Available); with
nothing on the wire it returns `d0=0x8000` ("no char") and `tst.w d0; bmi`
branches away cleanly. So RR0 bit0 = 0 is the *correct* response and no longer
blocks. The surrounding loop (`$4A840…$4AFCC`) is a **serial-startup timeout
wait**: it arms VIA1 **Timer 2** (`$50F0_1000/1200` = T2C-L/H = `0xFFFF`) and
polls VIA1 IFR bit5 (`$50F0_1A00`), counting **12 timeouts** before giving up on
serial and proceeding to normal boot.

## VERIFIED: boot sweeps the entire ROM and VIA Timer 2 fires

With the `ack` fix, the fast harness shows boot advancing far past the old gate:

* PC climbs **linearly through the whole ROM upper half**, `NEWPC` stepping
  `$4088_A000 → $408F_F000` (≈ the top of the 1 MB ROM) — a large decompress /
  init sweep running to completion, `berr=0`, no bus stalls.
* **VIA1 Timer 2 works**: repeated `T2 EXPIRED` events with `ifr=0x22`
  (bit5 = T2, bit1 = CA1/VBL from DAFB), `ier=0x00` (polled, matches the ROM).
  Timer 2 expires every ~187 k fetches, so the 12-timeout serial wait clears in
  ~2.2 M fetches.

## Current frontier: the ROM's STM (Serial Test Monitor) diagnostic

With machine-ID, 040 cache, ROM checksum, SCC/serial and the VIA2 microcontroller
handshake all cleared, boot runs the full power-on self-test (POST) and then
**diverts into the ROM's built-in serial diagnostic** instead of continuing to a
startup device. The diagnostic is identifiable from its own strings in high ROM:

```
04af08: STM Version 2.1, Scott Smyers
04af28: CTE Version 1.5.1
04aede: *ERROR*   04aee6: *APPLE*
```

STM = **Serial Test Monitor**; it emits an `*APPLE*` sign-on and then sits in a
command-wait loop (`ROM $4A840`) polling the SCC receive register (`$50F0_4002`,
RR0 bit0 = Rx char available) and VIA1 Timer 2 (`$50F0_1A00` IFR bit5) forever —
it is waiting for commands from a host on the serial port that never come. On a
healthy machine STM is **only entered on a POST failure**; on normal boot the ROM
skips it. So the machine is failing at least one POST subtest.

### What was traced and fixed

* The single site that sets the STM failure flag is `bset #$1a,d7` at ROM
  `$46D5A`, the tail of a VIA POST subtest (`$4B0DA`, run 256×) that selects an
  ACR shift mode, writes the VIA **shift register** (reg $A), and polls IFR bit2
  (SR transfer complete). Our VIA had **no shift register**, so IFR bit2 never
  set and the subtest failed. **Fixed** by implementing the 6522 SR (reg $A + ACR
  shift modes + IFR-bit2 completion); verified in isolation (`sim tb_sr`,
  IFR bit2 sets after 14 polls) and against the isolated iobus/SCC test.
* The VIA2 microcontroller handshake (`$47240`/`$4723A`, port A data + PB2 strobe
  + PB1 ack) was also made to pass by presenting VIA2 idle/ready port levels
  (PA=0xFF, PB1 following the strobe) — this is part of STM's own setup.

### The STM divert — ROOT-CAUSED and FIXED (VIA1 port-A input)

The STM entry decision is `$4A806 bne` on **`d7` bit26**. Full-system Verilator
register capture (probing the synthesized kernel `regfile[]`) showed `d7` =
`0x04410001` at the decision — bit26 set. The **only** ROM site that sets `d7`
bit26 is `$46D5A` (`bset #26,d7`), and the branch that reaches it is at `$46CCE`:

```
    bclr #0,(0x600,a2)     ; a2 = $50F00000 (VIA1); DDRA bit0 -> input
    bclr #1,(0x1E00,a2)    ; ORA bit1
    btst #0,(0x1E00,a2)    ; read VIA1 port-A bit0 (register 15, ORA no-handshake)
    beq  $46D5A            ; PA0 == 0  ->  bset #26,d7  ->  STM
```

So the ROM sets **VIA1 PA0 to input and requires it to read 1**. `iobus.sv`
instantiated VIA1 with `.pa_in(8'h00)`, so PA0 read 0 and the subtest failed.
On real Quadra 950 hardware the VIA1 port-A input pins are pulled high (PA7 = SCC
WrReq idle-high, PA6 = board sense, …). **Fix:** drive `via1_pa_in = 8'hFF`.

Verified in the full-system boot sim: `d7` bit26 is **never set**, the CPU
**never enters the STM loop** (previously stuck at `$4A840` forever), and boot
advances ~2.6M fetches into new territory — the entire upper-ROM POST sweep
(`$408Fxxxx`), ASC init (`$50F14834`), then a RAM copy/test loop at `$407116`
(`tst.b (a5); dbf d4` inside `move.b (a4)+,(a1)+`). At the decision code now
`d7`=`0x00000001` (bit26 clear) and `d0` bit12=1, so **both** STM conditions are
false — the code passes straight through the decision and continues booting.

### Next frontier — ASC init delay loops (sim-performance, not a bug)

After the STM divert clears, boot runs a long initialization phase centred on the
**ASC** (Apple Sound Chip, `$50F14000`). Register capture at the loop entry
(`$4070F8`) shows it is table-driven: `movem.w (a4)+,d0/d1/d2` loads the counts
from a **ROM data table** (e.g. `d2 = $1388 = 5000` outer iterations), and the
body is `move.b (a0)+,d4 … tst.b (a5); dbf d4` — an inner **delay** loop with
`d4`/`d5` ≈ 65k counts, sweeping `A0` across the ASC registers. These are genuine
hardware settling delays: trivial at 33 MHz (µs–ms) but many millions of cycles
in a cycle-accurate Verilator run, so the sim cannot practically reach the end of
the phase in real time. It is **bounded** (pointers advance, counters count down),
not a hang.

To verify downstream boot in sim, `boot_core.v` has a **sim-only delay
accelerator**: when the CPU spins inside a ≤8-byte PC window it zeroes the inner
delay counters (`d4`/`d5` low words) so the `dbf` delay exits immediately, leaving
the functional counters (`d2` outer, `d3` copy) intact. This touches only the
sim's copy of the kernel `regfile`, never the core RTL, and is purely a
simulation-speed aid.

### Status of the boot chain

Solved gates: machine identification, 040 cache enable, ROM checksum, SCC/serial
init, VIA1 Timer 2, VIA shift register, VIA2 microcontroller handshake, **VIA1
port-A input (STM divert)**. All peripheral unit tests (8 Icarus) and CPU/FPU
tests (6 GHDL) pass. Boot now clears the POST/STM decision and proceeds into the
ASC init / delay phase; the next real gate is downstream of those delays (video
init, then the boot-device search). The CPU's 68040 instruction support (MOVEC 040
control regs, CINV/CPUSH/PFLUSH/PTEST no-ops, MOVE16, FPU structural ops) proved
sufficient for POST — the STM divert was a peripheral input bug, not a
CPU-conformance wall.
