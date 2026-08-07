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

## What full ROM-boot convergence requires (open work)

1. Identify which candidate DecoderInfo the ROM walks for our config and read
   its DDR masks (`-0xC(a0)`, `-0xB(a0)`) and expected value/mask
   (`[+0x18]`/`[+0x20]`) — i.e. finish tracing the `$31AC` dispatch to the
   Quadra 950 entry.
2. Drive VIA1/VIA2 port-A/B input pins (`iobus.sv`) to that signature so
   `d1 & mask` matches `$1408`/`$0E08`.
3. Expect **further** gates after identity: RAM sizing (MCU bank probing),
   VIA/RTC time, ADB, then SCSI so a System file can be read. Each is its own
   probe-fidelity step, debuggable in this same harness (CPU PC + I/O trace).

This is a long ROM-fidelity reverse-engineering tail; it is independent of the
Phase-5 68040 CPU work (Level A/B/C), which does not depend on solving it.
