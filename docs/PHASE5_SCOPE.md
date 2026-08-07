# Phase 5 Scope — Toward a Real 68040

This is a scoping document, not an implementation plan we can finish here. It
breaks the 68040 problem into pieces, says which pieces the Quadra 950 software
actually needs, and lays out a dependency-ordered path with honest effort and
risk. Read [`CPU_NOTES.md`](CPU_NOTES.md) first for the background.

---

## 1. Where we are

The core currently runs the **TG68** kernel through `cpu_wrapper.vhd`: a
68020-*class* subset, **no FPU, no MMU, no caches**, not cycle-accurate. It is
enough to bring the *system* up (memory, video, VIA, RTC, SCSI, ADB, sound are
all verified against it), but it is not a 68040 and the real Quadra ROM will
not be satisfied by it as-is.

## 2. What a 68040 adds — and whether the Mac needs it

| Feature | What it is | Needed to **boot** Mac OS? | Needed for apps / A‑UX? |
|---|---|---|---|
| **Integrated FPU** | On-die IEEE-754: hardware for FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/FMOVE/FINT…; **traps transcendentals** (FSIN/FCOS/FETOX…) and packed-decimal to the software **FPSP** | No (ROM can accept a 68LC040 with no FPU) | Yes — SANE/graphics/scientific apps |
| **Dual paged MMUs + ATC** | Instruction+data MMUs, two 64-entry address-translation caches, the 040-specific 3-level table (4K/8K pages), TT registers, `URP/SRP/TC/MMUSR` via MOVEC, `PFLUSH/PTEST` | Partially — the ROM/OS configure the MMU and expect the register interface and instructions to work; **transparent 1:1** is enough for non-VM boot | Yes — Virtual Memory and A/UX need real table-walk translation |
| **4KB+4KB caches** | 4-way set-assoc I/D caches, copyback/write-through, bus **snooping** for DMA coherency | No (caches are transparent; ROM enables them but function is unaffected) | Only for performance/fidelity; snooping matters if caches + DMA coexist |
| **Burst bus** | 16-byte line fills (4 longwords) with TS/TA/TEA/TBI | No (single transfers work when there is no cache) | Only with caches |
| **MOVE16** | 16-byte aligned block move (`$F6xx`) | **Yes** — used by ROM/OS fast copies | Yes |
| **Cache mgmt** | `CINV/CPUSH` (`$F4xx`), `CACR` via MOVEC | **Yes** — must not fault; can be no-ops without caches | — |
| **040 exception frames** | Stack frame formats $7 (access error) etc.; dropped `CALLM/RTM` | **Yes** — fault/trap handling must use 040 frames | Yes |
| **6-stage pipeline** | ~1 instr/cycle | No (functional core is fine) | Only for timing fidelity |

**Key takeaway:** booting Mac OS needs an *040 personality* (right CPU-type
reporting, MOVE16, cache-instruction acceptance, 040 exception frames, and an
MMU that at least answers its register interface and translates — 1:1 is fine).
It does **not** strictly need a hardware FPU, real caches, or burst bus. Those
unlock apps, VM/A‑UX, and fidelity, in that order.

## 3. The core-IP problem — build vs. adapt

There is **no drop-in open-source synthesizable 68040.** Options:

| Option | Reality |
|---|---|
| **Extend TG68** (current) | Possible but TG68 is a 68000/010/020-subset not designed for MMU/FPU/040; its 020 support is itself partial. Big surgery. |
| **Apollo / AC68080** | A full superscalar 68080 with FPU+MMU that *does* fit mid FPGAs — but it is **not openly licensed** for arbitrary reuse. **Licensing must be cleared with the Apollo Team before any use.** Likely a blocker. |
| **fx68k** | Cycle-accurate **68000 only** — not a path to 040. |
| **Write a new 040 core** | Cleanest long-term, multi-year effort. |

Recommendation: **extend the current TG68-based core toward an "040
personality"** for boot (Level A below), treating the FPU and real MMU as
separable add-on units with clean interfaces (stubs added in this commit:
`rtl/cpu/mmu_040.sv`, `rtl/cpu/fpu_040.sv`). Re-evaluate Apollo only if its
licensing can be cleared.

## 4. Target levels (the decision that shapes everything)

- **Level A — "040 personality to boot"** *(recommended first)*
  020/030-class execution + MMU **register interface + transparent (1:1)
  translation** + accept `CINV/CPUSH/CACR` as no-ops + **MOVE16** + 040
  exception frames + correct CPU-type reporting. FPU **absent** (present as
  68LC040). Goal: the real ROM's CPU/MMU probe passes and Mac OS boots in
  non-VM mode.
- **Level B — "usable Mac"**
  Add a **hardware FPU** (arith) with **FPSP** trapping for transcendentals,
  and a **real MMU table-walk + ATC** (enables Virtual Memory). Still
  single-transfer bus, no data cache. Runs the large majority of software.
- **Level C — "full fidelity"**
  Real 4-way I/D **caches** with copyback + **snooping**, **burst** bus,
  closer cycle behaviour, **A/UX**. Largest effort, mostly fidelity/perf.

## 5. Milestones (dependency-ordered) with effort bands

Effort bands are rough: **S** ≈ days, **M** ≈ 1–2 weeks, **L** ≈ 1–2 months,
**XL** ≈ multi-month, for one experienced FPGA/68k developer.

```
5.0  Full-system sim harness ......................... S   (PREREQUISITE) ✅ enabler proven
       SOLVED in-environment: `ghdl synth --out=verilog` converts the VHDL CPU
       (TG68 + cpu_wrapper) to a Verilog netlist, so the WHOLE core (CPU +
       Verilog peripherals) simulates with open tools - no ModelSim/Questa
       needed. Flow + equivalence proof: sim/verilog-full/ (convert_cpu.sh
       reproduces cpu_synth.v; tb_cpu_v boots the test program on the converted
       core in Icarus).
       Simulator choice: **Icarus is fine for short/targeted tests** but does
       NOT scale to a full ROM boot (chokes on the ~35k-line netlist + a 1 MB
       memory). **Verilator** (compiled C++) does - and the real ROM now runs:
       see BOOT RESULT below. Runner: sim/verilog-full/ (sim_main.cpp +
       run_verilator.sh; obj_dir/boot_sim built by Verilator).
```

### BOOT RESULT (Verilator, CPU-only harness)

Running the **real Quadra 950 ROM** through the converted TG68 CPU with a C++
memory map (ROM + reset overlay + RAM window; I/O reads 0):

- Reset vector read (SP@0/PC@4), `jmp` to `$8C`, into main boot at `$4052`.
- **ROM overlay clears** on the first `$40` access, then RAM appears at `$0`.
- **Reaches VIA hardware init** (`$50F0_xxxx`) after ~500 cycles.
- Runs **~1.9M bus cycles with ZERO exceptions** — the 68020-class TG68 does
  *not* fault on a 68040-only instruction in this early path.
- Then settles into a **hardware-probe / polling loop** (ROM `$2F5A` walks a
  device-descriptor table; `$46C0` bit-bangs a VIA register): it spins because
  the I/O stub returns 0, so the status bits it waits on never change.

Takeaway: the CPU is not the immediate blocker — **peripheral liveness is**.

### BOOT RESULT (Verilator, FULL-system harness)

`sim/verilog-full/boot_top.v` verilates the whole `quadra950` (converted CPU +
all verified peripherals) with a DDR3 model preloaded with the ROM. Findings:

1. **Unmapped access hung the bus.** The CPU ran the probe code (`$2E0x →
   $2F1x → $2F5x → $316x → $46ax`) then hung after ~85 fetches on a supervisor
   read to `$51001C00` — a device the ROM probes. The core had no bus-error
   path; the Mac ROM probes hardware by triggering/catching bus errors.
2. **Fix: bus error (TEA) on unmapped access** (cpu_wrapper `berr` + a
   quadra950 watchdog). After it, the CPU no longer hangs: **~2.59M fetches**
   with no stall, cycling through the probe routines (`$2F7C/$3162/$46ac/
   $47xx/$4814`). Video generates frames throughout.
3. **Root-caused the probe loop (see `docs/BOOT_ANALYSIS.md`).** The core is
   healthy — reset, overlay clear, VIA bring-up, zero exceptions — and the
   stall is the ROM's **universal machine-identification scan**, not a CPU or
   bus bug. The scan assembles a machine signature from VIA1/VIA2 port-A/B
   **input pins** (`$47AE` DDR-manipulation read) and compares it against
   box-ID tables at `$31C4`/`$31C8`. Those pins are tied to 0 here, so the
   signature is 0 and matches no Quadra candidate; the scan retries forever.
   The Quadra 900/950 identity is the class-08 code `$1408`/`$0E08`
   (shared HW-config `07A31807`). Driving the pins to `0xFF` gave a
   byte-identical loop — convergence needs the *exact* per-candidate pin
   pattern. This is a long ROM-fidelity RE tail (identity → RAM sizing → RTC →
   ADB → SCSI), independent of the Level-A/B/C CPU work.
```

5.1  040 personality & instruction gaps .............. S–M   [Level A]
       MOVE16; CINV/CPUSH/CACR (MOVEC) as functional no-ops; 040 exception
       stack frames; drop CALLM/RTM; report CPU type = 68040/68LC040.

5.2  MMU ............................................. M–L
   5.2a  Register interface + transparent translation . M     [Level A]
          TC, ITT0/1, DTT0/1, URP, SRP, MMUSR via MOVEC; PFLUSH/PTEST accepted;
          TT registers cover all space -> 1:1 addresses. (Stub already does 1:1.)
   5.2b  Real 3-level table walk + 64-entry ATC ....... L     [Level B]
          4K/8K pages; PTEST->MMUSR; PFLUSH invalidation; page-fault bus error
          with a format-$7 frame. Enables Virtual Memory / A-UX.

5.3  FPU ............................................. L–XL
   5.3a  LC040 personality (no FPU, F-line traps) ..... S     [Level A]
   5.3b  Hardware arithmetic subset .................. L      [Level B]
          FADD/FSUB/FMUL/FDIV/FSQRT/FABS/FNEG/FCMP/FMOVE/FINT + extended/double/
          single formats, rounding modes, FPSR/FPCR, exceptions.
   5.3c  FPSP trap interface ......................... M      [Level B]
          Trap unimplemented ops/data types to the software package (in ROM/OS).

5.4  Caches + burst bus ............................. M–L     [Level C]
       4KB+4KB 4-way, copyback/write-through, CINV/CPUSH real, line-burst
       TS/TA/TEA/TBI, snooping for SCSI/DAFB DMA coherency.

5.5  Boot bring-up & regression ..................... M
       ROM POST -> "Welcome to Macintosh" -> System 7 from a SCSI image;
       then FPU app + VM once Level B lands.
```

Dependency summary: **5.0 gates everything**; 5.1 + 5.2a + 5.3a = Level A boot;
5.2b + 5.3b + 5.3c = Level B; 5.4 = Level C.

## 6. Integration architecture

Where the new units plug into `cpu_wrapper.vhd`:

```
  TG68 core ── virtual addr/fc/rw ──►  mmu_040  ── physical addr ──►  TS/TA bus
        ▲                                  │ (fault → bus error / format-$7 frame)
        │                                  ▼
        │                             MMU regs (MOVEC: TC/ITTx/DTTx/URP/SRP/MMUSR)
        │
        └── F-line FPU op ──►  fpu_040  ──► result / FPSR ; trap → FPSP (software)
```

- The **MMU** sits between the CPU's virtual address and the physical `TS`/`TA`
  bus this project already defines. The Level-A stub passes addresses through
  1:1 and just answers the register interface — a drop-in that lets boot proceed.
- The **FPU** is an execution unit fed by decoded F-line coprocessor ops; the
  Level-A stub reports "not present" so the ROM sees a 68LC040.
- Cache/burst logic (Level C) would live between the MMU output and the bus.

## 7. FPGA resource & timing risk

Target parts: DE10-Nano `5CSEBA6` and Superstation One `5CSXFC6D6` — both
Cyclone V, ~110K LE. The Apollo 68080 (FPU+MMU) fits comparable devices, so a
Level-A/B 040 is **feasible but not free**:
- **FPU** (extended-precision multiply/divide/sqrt) is the biggest LE/DSP and
  timing consumer; expect it to dominate the budget and set fMAX.
- **Caches** add block-RAM + snooping logic (Level C).
- Timing: hitting a useful fMAX with the FPU in the datapath is the main risk;
  pipelining the FPU and keeping it off the critical path will matter.

## 8. Validation strategy

- **5.0 harness — now available for free.** The mixed-language barrier is
  broken: `ghdl synth --out=verilog` emits a Verilog netlist of the VHDL CPU,
  which Icarus simulates alongside the Verilog peripherals. Proven in
  `sim/verilog-full/` (the converted core boots the test program). So the full
  core can be simulated here without ModelSim/Questa or hardware; the next step
  is a boot TB that presents the Mac memory map + the real ROM image.
- **Unit tests** we *can* do here: MMU table-walk against hand-built page
  tables and known virtual→physical vectors; FPU ops against reference vectors
  (e.g. compare to a software IEEE-754 model); MOVE16 semantics.

## 9. Recommended path

1. **5.0** — stand up a mixed-language sim (or commit to on-hardware bring-up).
2. **Level A** (5.1 + 5.2a + 5.3a) — get the real ROM to boot Mac OS in non-VM
   mode with a 68LC040 personality. This is the highest-value, lowest-risk
   next milestone and turns "subsystems verified" into "it boots."
3. **Level B** (FPU + real MMU) — the big lift; unlocks apps and VM.
4. **Level C** (caches/burst/A‑UX) — fidelity and performance, last.

## 10. Biggest risks / unknowns

- **Sim/observability** (5.0): without it, Level-A debugging is slow and
  hardware-only.
- **FPU** is the single largest and riskiest sub-project (correctness +
  timing + area). LC040-first de-risks the boot milestone.
- **Apollo licensing** — the one shortcut that could collapse much of this, but
  only if it can be legally cleared.
- **CPU-type / Gestalt probe** details in the ROM: exactly what the 040 probe
  checks must be reverse-engineered to pass Level A (partially seen in
  [`ROM_VALIDATION.md`](ROM_VALIDATION.md); needs the 5.0 harness to nail down).
- The current TG68 base may need replacing rather than extending if its 020
  gaps or structure block MMU/FPU integration — a fork/rewrite risk to watch.
