# The 68040 Problem — CPU Integration Notes

This is the single hardest part of the project and the main reason a Quadra 950
core does not already exist for MiSTer. Read this before touching
`rtl/cpu/cpu_wrapper.vhd`.

## Why the 68040 is hard

Unlike the 68000 — which has excellent, mature, cycle-accurate open cores
(`fx68k`, `TG68`) — there is **no mature, open-source, synthesizable MC68040**.
An 040 is a large, superscalar-ish design with:

- **On-die FPU** — a full IEEE-754 FPU is a major project on its own.
- **Dual paged MMUs** (instruction + data) — required by A/UX and by virtual
  memory in later System/Mac OS. Many apps run without it; the OS increasingly
  does not.
- **4 KB + 4 KB caches with copyback** and **burst (line) bus transfers** — the
  bus protocol (TS/TA/TEA, synchronous, bursts) is unlike the 68000/020 bus.

Writing a correct, fast 040 from scratch is a multi-year effort.

## Options, most realistic first

### 1. Bring the system up on a 68020/030-class core *(DONE — current state)*
This is the path taken. The **TG68KdotC** kernel (LGPLv3) is vendored in
`rtl/cpu/tg68k/` and wrapped by `rtl/cpu/cpu_wrapper.vhd`, which adapts its
16-bit `clkena`-driven bus to the core's 32-bit `TS`/`TA` bus. It is
GHDL-verified booting and executing (see `sim/ghdl/`). Running in CPU="11"
(68020) mode gives 32-bit addressing, 32-bit MUL/DIV, and bit-field ops.
Accept that:
- No FPU-dependent software.
- No MMU → no A/UX, no protected/virtual memory; classic Mac OS mostly works
  because it ran on MMU-less 020 machines too (with the right ROM/OS combo).

This validates the entire rest of the core (memory, video, I/O, storage) while
the CPU question is worked separately. **This is the milestone the scaffold
targets.**

### 2. Extend toward 68040 incrementally *(Level A in progress)*
On top of a working 020/030 core, add, in priority order:
1. **MMU** (biggest compatibility unlock — enables modern System versions, VM).
2. **FPU** (unlocks scientific/graphics software; huge but self-contained).
3. **Cache + burst bus semantics** (performance + timing fidelity).
Each is independently testable.

**Level-A "040 personality" landed in the TG68 kernel** (see
`docs/PHASE5_SCOPE.md` for the full roadmap; all changes are GHDL-verified in
`sim/ghdl/`):

- **MOVEC 68040 control registers.** The kernel's MOVEC whitelist and register
  file were extended with TC (`$003`), ITT0/ITT1 (`$004/$005`), DTT0/DTT1
  (`$006/$007`), MMUSR (`$805`), URP (`$806`), SRP (`$807`). They store and
  read back the written value (round-trip verified by `tb_cpu_040`), which the
  MMU register interface (roadmap 5.2a) and the ROM's MMU bring-up require.
  Translation itself stays **transparent (1:1)** for Level A regardless of TC —
  no table walk yet (that is Level B, `mmu_040.sv`).
- **68040 cache/MMU control instructions as no-ops.** `$F4xx` (CINV/CPUSH) and
  `$F5xx` (PFLUSH/PTEST) now execute as privileged single-word no-ops instead
  of taking a line-F trap — correct here because there is no cache and the MMU
  is transparent. User-mode use still raises a privilege violation, like a real
  040. Verified by `tb_cpu_040nop`.
- **LC040 FPU personality.** The FPU F-line opcodes (`$F2xx`/`$F3xx`) still take
  the line-F (vector 11) trap, which is exactly the LC040 behaviour: the FPSP
  software package emulates them. No hardware FPU is present (`fpu_040.sv` is a
  Level-B anchor).

**MOVE16 is now implemented and verified** (see below). Still open for Level A:
full **68040 exception stack frames** (format `$7` access-error frame; mainly
matters once the MMU can fault, Level B) and explicit CPU-type=68040 reporting.

#### MOVE16 (`$F620-$F627`, `(Ax)+,(Ay)+`) — DONE

MOVE16 moves a 16-byte, 16-byte-aligned block. Unlike CINV/CPUSH it cannot be a
no-op (that would corrupt block copies). The postincrement-both form is now
implemented in the kernel: the `"1111"` decode detects `$F620-$F627`, captures
`Ay` from the extension word via `get_2ndOPC` (`sndOPC(14:12)`), and a
`m16r`/`m16w` microstate pair does **four longword read→write passes** —
reusing the memory-to-memory MOVE data-hold path (`exec_DIRECT`) — with a
2-bit longword counter, incrementing `Ax`/`Ay` by 16 total. Verified by
`sim/ghdl/tb_move16` (moves 16 bytes; `A0`→+16, `A1`→+16) and it still converts
cleanly through `ghdl synth`. The absolute-address forms
(`$F600/$F608/$F610/$F618`) still take a line-F trap (rare; TODO). Alignment
note: a real 040 ignores `A[3:0]` and bursts a line; the 4×`MOVE.L` realization
is bit-identical for the 16-byte-aligned operands BlockMove uses.

##### Original implementation analysis (kept for reference)

Encoding (5 forms; `Ax`=`opcode(2:0)`):
- `$F620|Ax` `(Ax)+,(Ay)+` — **primary form**, has a 2nd word `1yyy...` with
  `Ay = sndOPC(14:12)`; both registers post-increment by 16.
- `$F600/$F608/$F610/$F618 |Ax` — the four `(Ax)[+]`↔`(xxx).L` absolute forms
  (opcode word + 32-bit address); only the `(Ax)+` variants post-increment.

Recommended approach — **reuse the existing memory-to-memory MOVE datapath**,
which already works for `MOVE.L (Ax)+,(Ay)+`:
- The needed primitives were located: `get_2ndOPC` captures the 2nd word into
  `sndOPC`; `dest_2ndHbits` selects the dest register from `sndOPC(14:12)`
  (exactly `Ay`); `set_direct_data`/`use_direct_data` + `ea_data<=data_read`
  pass the read longword to the write; `set(postadd)` does the `An += size`
  writeback; `cmpm`/`op_AxAy` are compact mem-to-mem-with-post-increment
  microstate templates.
- Decode `(opcode and $FFF8)=$F620` in the `"1111"` case, `get_2ndOPC`, then run
  the `MOVE.L (Ax)+,(Ay)+` read→write pass **four times** via a 2-bit counter
  and two added microstates (`m16r`/`m16w`, already reserved in a scratch
  branch), advancing the real PC past the 2 instruction words only after the
  4th longword.
- Caveat to document when landed: real 040 MOVE16 forces 16-byte alignment
  (ignores `A3:0`); the 4×`MOVE.L` realization is bit-identical for the aligned
  operands BlockMove uses, which is the normal case.
- Verify with a GHDL testbench (drafted: `tb_move16` — preload 16 bytes, run
  `MOVE16 (A0)+,(A1)+`, assert the destination matches and `A0`/`A1` advanced by
  16). Must also re-pass `tb_cpu`/`tb_cpu_040`/`tb_cpu_040nop` and re-convert
  cleanly through `ghdl synth`.

### 3. Evaluate the Apollo / 68080 ("AC68080") lineage
Very capable (superscalar 68k with FPU/MMU), but **not openly licensed** for
arbitrary reuse. **Licensing must be cleared before any use** — do not assume
it is usable just because it exists.

## The bus adapter (`cpu_wrapper.vhd`)

Whatever core is chosen, `cpu_wrapper` translates it to the simplified
68040-style synchronous bus the rest of the core expects:

- `ts` — transfer start (CPU asserts to begin a bus cycle)
- `ta` — transfer acknowledge (system asserts to complete it)
- `addr` / `dout` / `din` / `be` / `rw` / `fc` — address, data, byte enables,
  read/write, function codes
- `ce` — 33 MHz clock enable (advance the core at the emulated rate)
- `ipl[2:0]` — interrupt priority level in

Most 020-class cores expose an asynchronous DTACK/DSACK bus; the wrapper's job
is to convert DTACK↔TA and present a clean synchronous interface upward.

## Fidelity vs. the real machine

Even a perfect 020/030 substitution is **not** a Quadra 950 — the ROM checks
the machine type (Gestalt = 26) and expects 040 behaviour in places. Plan to:
- Patch/adapt a compatible ROM, or
- Extend the CPU far enough that the stock 950 ROM is satisfied.

Document clearly, in the README and releases, what a given build actually is
(e.g. "Quadra-class system on an 030-level CPU") so users are not misled.
