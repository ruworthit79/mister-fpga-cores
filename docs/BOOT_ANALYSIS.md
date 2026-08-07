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

## Next gate (open work)

After identification the ROM enters a **device-configuration / timing phase**
and currently loops there (heavy VIA1/VIA2 IER access at `$50F0_1C00`/
`$50F0_3C00`, executing the `$46AA`-style register tests in the ROM image
around `$4080_46xx`). This is the next probe-fidelity step to trace in this
harness. Expect **further** gates after it: RAM sizing (MCU bank probing),
VIA/RTC time + timer interrupts, ADB, then SCSI so a System file can be read.

This remains a long ROM-fidelity tail, but the first and central gate — machine
identification — is solved. It is independent of the Phase-5 68040 CPU work.
