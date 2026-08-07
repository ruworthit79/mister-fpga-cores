derive_pll_clocks
derive_clock_uncertainty

# ----------------------------------------------------------------------------
# Core-specific timing constraints
# ----------------------------------------------------------------------------
# The emulated 68040 runs at 33 MHz nominal (Quadra 950). On the DE10-Nano the
# core is clocked from a PLL; the CPU logic is expected to be gated by a clock
# enable (cpu_ce) rather than a physically separate 33 MHz clock, so the fabric
# runs at the PLL system clock and the CPU advances on cpu_ce ticks.
#
# Add explicit false paths / multicycles here once the CPU and SDRAM/DDR
# controllers are integrated. Placeholder examples (commented until real clock
# names exist):
#
# set_false_path -from {*|reset_reg} -to {*}
# set_multicycle_path -from {emu|quadra950|cpu|*} -setup 2
