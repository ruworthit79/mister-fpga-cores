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

### 2. Extend toward 68040 incrementally
On top of a working 020/030 core, add, in priority order:
1. **MMU** (biggest compatibility unlock — enables modern System versions, VM).
2. **FPU** (unlocks scientific/graphics software; huge but self-contained).
3. **Cache + burst bus semantics** (performance + timing fidelity).
Each is independently testable.

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
