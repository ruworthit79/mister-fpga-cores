# Phase 8 — 68040 integrated FPU

Target-spec item: **"68040 with integrated FPU."** The Quadra 950 has a full
68040 (FPU on-die), and Mac OS 8.1 plus FP software expect it. This is the
single largest remaining CPU subsystem. This doc scopes it and records the
foundation that has landed.

## The 68040 FPU programming model

- **FP0–FP7** — eight 80-bit extended-precision registers.
- **FPCR** — control: rounding mode (RN/RZ/RM/RP), rounding precision
  (X/S/D), and exception enables.
- **FPSR** — status: condition codes `N Z I NAN` (bits 27..24), quotient byte,
  exception status, accrued exception bits.
- **FPIAR** — faulting FP instruction address.
- **Instruction set** (F-line, coprocessor id 001, `$F2xx`): FMOVE/FMOVEM,
  FABS/FNEG/FTST, FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/FINT/FINTRZ, format conversions
  (byte/word/long/single/double/extended/packed ↔ extended), and the
  transcendentals (FSIN/FCOS/FTAN/FETOX/FLOGN/FTWOTOX/…) plus FScc/FBcc/FNOP.

A real 68040 implements the arithmetic subset in hardware and **traps the rest
to the FPSP** (Floating-Point Software Package) — Apple ships the FPSP in the
ROM/OS. So a faithful core does NOT need every instruction in silicon; it needs
the hardware subset + a correct "unimplemented → F-line trap" path.

## Landed this phase — the FPU foundation (`rtl/cpu/fpu_040.vhd`)

Verified by `sim/ghdl/tb_fpu.vhd` (in the GHDL suite):

- Full register model: FP0–FP7, FPCR, FPSR, FPIAR.
- Structural ops (no arithmetic datapath needed): **FMOVE** (reg↔reg, load,
  store), **FABS**, **FNEG**, **FTST**, and FMOVE to/from the control registers.
- **IEEE classification** → FPSR condition codes (N, Z, Inf, NaN) on the 80-bit
  extended format.
- `present = 1` (reports an FPU), and a clean **`unimpl` output** that raises the
  F-line trap for every not-yet-implemented op (→ FPSP), exactly as a real 040
  does for its unimplemented set.
- A defined command interface (`cmd`, `src_reg`, `dst_reg`, `cr_sel`, `ext_in`,
  `ext_out`, `done`, `unimpl`) for the CPU's F-line decode to drive.

## Remaining work (ordered)

1. **Kernel F-line integration (5.3 glue).** Today the TG68 kernel traps ALL
   `$F` line. Add FPU-opcode decode ($F2xx / cp-id 001) in the kernel: parse the
   command word (R/M, source specifier, register/EA), fetch the operand via the
   normal EA machinery, drive `fpu_040`, and write back FPn or the EA. On
   `unimpl`, take the existing line-F trap. This is the same kind of microcode
   work as MOVE16, and is the gate to the FPU doing anything for software.
2. **Arithmetic datapath (5.3b) — the big lift.** FADD/FSUB/FMUL/FDIV/FSQRT/
   FCMP/FINT with correct rounding (FPCR) and IEEE flags (FPSR). Options:
   - adapt an open FPU (the OpenCores FPU / the reverse-engineered **MC68881
     VHDL** core — the 040 FPU is 68881/882-ISA-compatible), or
   - build a pipelined extended-precision datapath (kept off the CPU critical
     path). Format conversions (single/double ↔ extended) come with it.
3. **FPSP trap path (5.3c).** Ensure the transcendentals and packed-decimal
   types trap cleanly to the FPSP already present in the Mac ROM/OS. Mostly the
   `unimpl` path from step 1, plus the correct F-line exception frame.
4. **Gestalt / detection.** With `present=1` and the FPU responding, the OS
   should report an FPU; verify the ROM's FPU-detection probe is satisfied.

## Interim (until 5.3b lands): LC040 + FPSP

With the foundation's `unimpl` path, the core behaves as a **68LC040** (no HW
FPU) once step 1 is wired: FP software runs via the software FPSP — correct,
just slower. That is enough for Mac OS 8.1 to boot and run most software; the HW
arithmetic (step 2) is the performance/authenticity upgrade to a full 68040.

## Effort

Step 1 (integration): moderate microcode, days. Step 2 (HW arithmetic): the
major lift, weeks — this is what makes it a *full* 040 rather than an LC040.
Steps 3–4: small, gated by 1–2.
