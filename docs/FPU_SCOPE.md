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

1. **Kernel F-line integration (5.3 glue).** ✅ DONE for the register-to-register
   general form. The kernel now decodes `$F200` (cpGEN, cp-id 1), consumes the
   command word (`get_2ndOPC`→`sndOPC`), and in a new `fpu1` microstate drives
   `fpu_040` for the reg-reg structural ops (FMOVE/FABS/FNEG/FTST, R/M=0) via a
   free-running handshake (op_valid strobe + latched done/unimpl, decoupled from
   the CPU ce cadence). On `unimpl` or any unsupported form it takes the line-F
   trap. `cpu_wrapper` instantiates `fpu_040` and exposes `fpu_fpsr`/
   `fpu_present`. Verified by `sim/ghdl/tb_cpu_fpu.vhd` (the CPU runs FTST/FNEG
   live, FPSR updates, no trap). **Still to add here:** the **memory-operand
   path** — FMOVE.X `<ea>`↔FPn (with the 96-bit extended memory format) and
   FMOVE to/from FPCR/FPSR/FPIAR via an EA — needed before FP values can come
   from memory (i.e. before real FP software does anything useful).
2. **Arithmetic datapath (5.3b) — the big lift.** FADD/FSUB/FMUL/FDIV/FSQRT/
   FCMP/FINT with correct rounding (FPCR) and IEEE flags (FPSR).
   - **Landed:** extended-precision (80-bit) **FADD / FSUB / FMUL** in
     `fpu_040.vhd` — exponent align, mantissa add/sub with normalization, 64×64
     mantissa multiply, NaN/Inf/Zero special cases; round-toward-zero for now.
     Unit-verified in `sim/ghdl/tb_fpu.vhd` (2+3=5, 5−2=3, 2×3=6) via the new
     `FPU_FADD`/`FPU_FSUB`/`FPU_FMUL` command codes.
   - **Wired into the CPU:** the kernel's F-line decode recognizes the
     register-to-register **FADD ($22) / FSUB ($28) / FMUL ($23) / FDIV ($20) /
     FSQRT ($04)** opmodes and drives the hardware datapath, so the CPU executes
     them in hardware instead of trapping — verified in `sim/ghdl/tb_cpu_fpu.vhd`
     (a reg-reg FADD runs with no F-line trap) and `sim/ghdl/tb_fpu.vhd`
     (6/2=3, √4=2, √9=3 on the unit).
   - **Format conversions implemented:** single↔extended and double↔extended
     (`single_to_ext`/`double_to_ext`/`ext_to_single`/`ext_to_double`, command
     codes `FPU_LD_S/LD_D/ST_S/ST_D`), unit-verified with 2.5 round-trips. These
     are the building blocks the memory-operand FMOVE needs.
   - **Remaining:** (a) the **memory-operand path** — wire the conversions into
     the kernel so FMOVE.X/S/D `<ea>`↔FPn fetches/stores the operand and drives
     `ext_in`/consumes `ext_out` (the FPU side is done; the kernel EA fetch is
     not); (b) FCMP/FINT; (c) the other rounding modes + IEEE exception flags
     (datapath is round-toward-zero today). Alternative to hand-building the rest:
     adapt the reverse-engineered **MC68881 VHDL** core.
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
