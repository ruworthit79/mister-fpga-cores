------------------------------------------------------------------------------
--  tb_fpu - 68040 FPU foundation test (GHDL, VHDL fpu_040)
--
--  Validates the VHDL fpu_040 (register model + structural ops + IEEE
--  classification) that is wired into the CPU. Mirrors sim/iverilog/tb_fpu.v.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fpu is
end tb_fpu;

architecture sim of tb_fpu is
	signal clk      : std_logic := '0';
	signal reset    : std_logic := '1';
	signal op_valid : std_logic := '0';
	signal cmd      : std_logic_vector(4 downto 0) := (others => '0');
	signal src_reg  : std_logic_vector(2 downto 0) := (others => '0');
	signal dst_reg  : std_logic_vector(2 downto 0) := (others => '0');
	signal cr_sel   : std_logic_vector(2 downto 0) := (others => '0');
	signal ext_in   : std_logic_vector(79 downto 0) := (others => '0');
	signal ext_out  : std_logic_vector(79 downto 0);
	signal fpsr_out : std_logic_vector(31 downto 0);
	signal fpcr_out : std_logic_vector(31 downto 0);
	signal present  : std_logic;
	signal done     : std_logic;
	signal unimpl   : std_logic;

	constant FPU_FMOVE_RR : std_logic_vector(4 downto 0) := "00001";
	constant FPU_FMOVE_LD : std_logic_vector(4 downto 0) := "00010";
	constant FPU_FMOVE_ST : std_logic_vector(4 downto 0) := "00011";
	constant FPU_FABS     : std_logic_vector(4 downto 0) := "00100";
	constant FPU_FNEG     : std_logic_vector(4 downto 0) := "00101";
	constant FPU_FTST     : std_logic_vector(4 downto 0) := "00110";
	constant FPU_TO_CR    : std_logic_vector(4 downto 0) := "00111";
	constant FPU_FROM_CR  : std_logic_vector(4 downto 0) := "01000";
	constant FPU_ARITH    : std_logic_vector(4 downto 0) := "01001";
	constant FPU_FADD     : std_logic_vector(4 downto 0) := "01010";
	constant FPU_FSUB     : std_logic_vector(4 downto 0) := "01011";
	constant FPU_FMUL     : std_logic_vector(4 downto 0) := "01100";
	constant FPU_FDIV     : std_logic_vector(4 downto 0) := "01101";
	constant FPU_FSQRT    : std_logic_vector(4 downto 0) := "01110";
	constant FPU_LD_S     : std_logic_vector(4 downto 0) := "01111";
	constant FPU_LD_D     : std_logic_vector(4 downto 0) := "10000";
	constant FPU_ST_S     : std_logic_vector(4 downto 0) := "10001";
	constant FPU_ST_D     : std_logic_vector(4 downto 0) := "10010";
	constant CR_FPCR      : std_logic_vector(2 downto 0) := "001";

	constant P1   : std_logic_vector(79 downto 0) := x"3FFF8000000000000000";
	constant N1   : std_logic_vector(79 downto 0) := x"BFFF8000000000000000";
	constant ZERO : std_logic_vector(79 downto 0) := x"00000000000000000000";
	constant PINF : std_logic_vector(79 downto 0) := x"7FFF8000000000000000";
	constant QNAN : std_logic_vector(79 downto 0) := x"7FFFC000000000000000";
	-- extended-precision test values
	constant TWO   : std_logic_vector(79 downto 0) := x"40008000000000000000";
	constant THREE : std_logic_vector(79 downto 0) := x"4000C000000000000000";
	constant FIVE  : std_logic_vector(79 downto 0) := x"4001A000000000000000";
	constant SIX   : std_logic_vector(79 downto 0) := x"4001C000000000000000";
	constant FOUR  : std_logic_vector(79 downto 0) := x"40018000000000000000";
	constant NINE  : std_logic_vector(79 downto 0) := x"40029000000000000000";
	constant X2_5  : std_logic_vector(79 downto 0) := x"4000A000000000000000";  -- ext 2.5
	-- single 2.5 = 0x40200000 in the low 32 bits; double 2.5 = 0x4004000000000000
	constant SGL25 : std_logic_vector(79 downto 0) := x"00000000000040200000";
	constant DBL25 : std_logic_vector(79 downto 0) := x"00004004000000000000";

	signal unimpl_latch : std_logic := '0';

	procedure issue(signal clk_s : in std_logic;
	                signal ov : out std_logic; signal c : out std_logic_vector(4 downto 0);
	                signal s : out std_logic_vector(2 downto 0); signal d : out std_logic_vector(2 downto 0);
	                signal cr : out std_logic_vector(2 downto 0); signal e : out std_logic_vector(79 downto 0);
	                cc : std_logic_vector(4 downto 0); ss : std_logic_vector(2 downto 0);
	                dd : std_logic_vector(2 downto 0); crc : std_logic_vector(2 downto 0);
	                ee : std_logic_vector(79 downto 0)) is
	begin
		wait until falling_edge(clk_s);
		c <= cc; s <= ss; d <= dd; cr <= crc; e <= ee; ov <= '1';
		wait until falling_edge(clk_s);
		ov <= '0';
		wait until falling_edge(clk_s);
	end procedure;

begin
	dut : entity work.fpu_040
		port map(clk=>clk, reset=>reset, op_valid=>op_valid, cmd=>cmd,
		         src_reg=>src_reg, dst_reg=>dst_reg, cr_sel=>cr_sel,
		         ext_in=>ext_in, ext_out=>ext_out, fpsr_out=>fpsr_out,
		         fpcr_out=>fpcr_out, present=>present, done=>done, unimpl=>unimpl);

	clk <= not clk after 5 ns;

	-- latch the 1-cycle unimpl pulse
	process(clk) begin
		if rising_edge(clk) then
			if unimpl = '1' then unimpl_latch <= '1'; end if;
		end if;
	end process;

	stim : process
		variable errors : integer := 0;
		procedure chk(cond : boolean; msg : string) is
		begin
			if not cond then report "FAIL: " & msg severity warning; errors := errors + 1; end if;
		end procedure;
	begin
		wait for 40 ns; reset <= '0'; wait until falling_edge(clk);

		chk(present = '1', "present should be 1");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "000", "000", P1);
		chk(fpsr_out(27)='0' and fpsr_out(26)='0' and fpsr_out(25)='0' and fpsr_out(24)='0', "CC(+1.0)");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_RR, "000", "001", "000", ZERO);

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FNEG, "001", "010", "000", ZERO);
		chk(fpsr_out(27)='1', "CC N after FNEG (-1.0)");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FABS, "010", "011", "000", ZERO);
		chk(fpsr_out(27)='0', "CC N cleared after FABS");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "100", "000", ZERO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FTST, "100", "000", "000", ZERO);
		chk(fpsr_out(26)='1', "CC Z for zero");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "101", "000", PINF);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FTST, "101", "000", "000", ZERO);
		chk(fpsr_out(25)='1', "CC I for +Inf");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "110", "000", QNAN);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FTST, "110", "000", "000", ZERO);
		chk(fpsr_out(24)='1', "CC NAN for NaN");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "000", "000", "000", ZERO);
		chk(ext_out = P1, "FMOVE FP0->ext store");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_TO_CR, "000", "000", CR_FPCR, x"00000000000000000030");
		chk(fpcr_out = x"00000030", "FPCR write");
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FROM_CR, "000", "000", CR_FPCR, ZERO);
		chk(ext_out(31 downto 0) = x"00000030", "FPCR read-back");

		-- ---- hardware arithmetic datapath: FADD / FSUB / FMUL ----
		-- FP0 = 2.0, FP1 = 3.0
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "000", "000", TWO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "001", "000", THREE);
		-- FADD FP0,FP1 -> FP1 = 3.0 + 2.0 = 5.0
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FADD, "000", "001", "000", ZERO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "001", "000", "000", ZERO);
		chk(ext_out = FIVE, "FADD 2.0+3.0=5.0");
		-- FSUB FP0,FP1 -> FP1 = 5.0 - 2.0 = 3.0
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FSUB, "000", "001", "000", ZERO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "001", "000", "000", ZERO);
		chk(ext_out = THREE, "FSUB 5.0-2.0=3.0");
		-- FP2 = 2.0, FP3 = 3.0; FMUL FP2,FP3 -> FP3 = 3.0 * 2.0 = 6.0
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "010", "000", TWO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "011", "000", THREE);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMUL, "010", "011", "000", ZERO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "011", "000", "000", ZERO);
		chk(ext_out = SIX, "FMUL 2.0*3.0=6.0");

		-- ---- FDIV / FSQRT ----
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "000", "000", SIX);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "001", "000", TWO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FDIV, "001", "000", "000", ZERO);  -- FP0=6/2
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "000", "000", "000", ZERO);
		chk(ext_out = THREE, "FDIV 6.0/2.0=3.0");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "000", "000", FOUR);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FSQRT, "000", "001", "000", ZERO);  -- FP1=sqrt(FP0)
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "001", "000", "000", ZERO);
		chk(ext_out = TWO, "FSQRT 4.0=2.0");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_LD, "000", "000", "000", NINE);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FSQRT, "000", "001", "000", ZERO);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "001", "000", "000", ZERO);
		chk(ext_out = THREE, "FSQRT 9.0=3.0");

		-- ---- format conversions: single/double <-> extended ----
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_LD_S, "000", "010", "000", SGL25);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "010", "000", "000", ZERO);
		chk(ext_out = X2_5, "LD single 2.5 -> ext");
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_ST_S, "010", "000", "000", ZERO);
		chk(ext_out(31 downto 0) = x"40200000", "ST ext 2.5 -> single");

		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_LD_D, "000", "011", "000", DBL25);
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_FMOVE_ST, "011", "000", "000", ZERO);
		chk(ext_out = X2_5, "LD double 2.5 -> ext");
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_ST_D, "011", "000", "000", ZERO);
		chk(ext_out(63 downto 0) = x"4004000000000000", "ST ext 2.5 -> double");

		-- no earlier op raises unimpl, so the latch is still '0' here
		issue(clk, op_valid, cmd, src_reg, dst_reg, cr_sel, ext_in, FPU_ARITH, "000", "000", "000", ZERO);
		wait until falling_edge(clk); wait until falling_edge(clk);
		chk(unimpl_latch = '1', "FADD-class op raises unimpl (FPSP)");

		if errors = 0 then
			report "PASS: FPU VHDL (FMOVE/FABS/FNEG/FTST, FADD/FSUB/FMUL/FDIV/FSQRT, single/double conv, unimpl)" severity note;
		else
			report "FAIL: FPU foundation VHDL" severity failure;
		end if;
		std.env.finish;
	end process;
end sim;
