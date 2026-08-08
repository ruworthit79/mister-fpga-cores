------------------------------------------------------------------------------
--  fpu_040 - 68040 Floating-Point Unit (VHDL, integrated into the TG68 CPU)
--
--  Owns the FPU programming model (FP0-FP7 in 80-bit extended precision, plus
--  FPCR / FPSR / FPIAR) and executes commands issued by the kernel's F-line
--  (coprocessor id 1) decode. This is the VHDL sibling of the validated
--  rtl/cpu/fpu_040.sv foundation, in VHDL so it lives inside the VHDL CPU core
--  and is exercised by the GHDL CPU testbenches. See docs/FPU_SCOPE.md.
--
--  Implemented: the "structural" ops (no arithmetic datapath) - FMOVE (reg,
--  load, store), FABS, FNEG, FTST, FMOVE to/from FPCR/FPSR/FPIAR, and IEEE
--  classification -> FPSR condition codes. Arithmetic (FADD/FMUL/...) raises
--  `unimpl` so the CPU takes the F-line trap (-> Apple FPSP), exactly as a real
--  68040 does for its unimplemented set.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fpu_040 is
	port(
		clk       : in  std_logic;
		reset     : in  std_logic;

		op_valid  : in  std_logic;                       -- 1-cycle strobe
		cmd       : in  std_logic_vector(4 downto 0);    -- FPU_* command
		src_reg   : in  std_logic_vector(2 downto 0);    -- FPm
		dst_reg   : in  std_logic_vector(2 downto 0);    -- FPn
		cr_sel    : in  std_logic_vector(2 downto 0);    -- control-reg select
		ext_in    : in  std_logic_vector(79 downto 0);   -- external operand
		ext_out   : out std_logic_vector(79 downto 0);   -- external result

		fpsr_out  : out std_logic_vector(31 downto 0);
		fpcr_out  : out std_logic_vector(31 downto 0);
		present   : out std_logic;                       -- 1 = FPU present
		done      : out std_logic;                       -- op completed
		unimpl    : out std_logic                        -- -> FPSP trap
	);
end fpu_040;

architecture rtl of fpu_040 is

	-- command encoding (mirror of the SystemVerilog foundation)
	constant FPU_NOP      : std_logic_vector(4 downto 0) := "00000";
	constant FPU_FMOVE_RR : std_logic_vector(4 downto 0) := "00001";
	constant FPU_FMOVE_LD : std_logic_vector(4 downto 0) := "00010";
	constant FPU_FMOVE_ST : std_logic_vector(4 downto 0) := "00011";
	constant FPU_FABS     : std_logic_vector(4 downto 0) := "00100";
	constant FPU_FNEG     : std_logic_vector(4 downto 0) := "00101";
	constant FPU_FTST     : std_logic_vector(4 downto 0) := "00110";
	constant FPU_TO_CR    : std_logic_vector(4 downto 0) := "00111";
	constant FPU_FROM_CR  : std_logic_vector(4 downto 0) := "01000";
	constant FPU_ARITH    : std_logic_vector(4 downto 0) := "01001";  -- unimpl -> FPSP
	constant FPU_FADD     : std_logic_vector(4 downto 0) := "01010";
	constant FPU_FSUB     : std_logic_vector(4 downto 0) := "01011";
	constant FPU_FMUL     : std_logic_vector(4 downto 0) := "01100";

	-- control-reg select
	constant CR_FPCR  : std_logic_vector(2 downto 0) := "001";
	constant CR_FPSR  : std_logic_vector(2 downto 0) := "010";
	constant CR_FPIAR : std_logic_vector(2 downto 0) := "100";

	type reg_array is array(0 to 7) of std_logic_vector(79 downto 0);
	signal fpreg : reg_array;
	signal FPCR  : std_logic_vector(31 downto 0);
	signal FPSR  : std_logic_vector(31 downto 0);
	signal FPIAR : std_logic_vector(31 downto 0);

	-- classify: returns condition codes {N, Z, I(nf), NAN}
	function classify(v : std_logic_vector(79 downto 0)) return std_logic_vector is
		variable e   : std_logic_vector(14 downto 0);
		variable frac: std_logic_vector(62 downto 0);
		variable m   : std_logic_vector(63 downto 0);
		variable z, inf, nan, n : std_logic;
		variable cc  : std_logic_vector(3 downto 0);
	begin
		e    := v(78 downto 64);
		frac := v(62 downto 0);
		m    := v(63 downto 0);
		if (unsigned(e) = 0) and (unsigned(m) = 0) then z := '1'; else z := '0'; end if;
		if (e = "111111111111111") and (unsigned(frac) = 0) then inf := '1'; else inf := '0'; end if;
		if (e = "111111111111111") and (unsigned(frac) /= 0) then nan := '1'; else nan := '0'; end if;
		n := v(79) and (not nan);
		cc := n & z & inf & nan;
		return cc;
	end function;

	-- ---- special-value predicates on the extended format ----
	function is_nan(v : std_logic_vector(79 downto 0)) return boolean is
	begin
		return (v(78 downto 64) = "111111111111111") and (unsigned(v(62 downto 0)) /= 0);
	end function;
	function is_inf(v : std_logic_vector(79 downto 0)) return boolean is
	begin
		return (v(78 downto 64) = "111111111111111") and (unsigned(v(62 downto 0)) = 0);
	end function;
	function is_zero(v : std_logic_vector(79 downto 0)) return boolean is
	begin
		return (unsigned(v(78 downto 64)) = 0) and (unsigned(v(63 downto 0)) = 0);
	end function;

	constant BIAS  : integer := 16383;
	constant EXPMX : integer := 32767;
	constant QNANv : std_logic_vector(79 downto 0) := x"7FFFC000000000000000";
	constant PZERO : std_logic_vector(79 downto 0) := (others => '0');

	function make_inf(s : std_logic) return std_logic_vector is
	begin
		return s & "111111111111111" & x"8000000000000000";
	end function;

	-- Extended-precision add/sub (caller pre-negates b's sign for FSUB).
	-- Round-toward-zero (truncation); exact for representable operands. Handles
	-- NaN/Inf/Zero specially. See docs/FPU_SCOPE.md for the fidelity scope.
	function fp_addsub(a, b : std_logic_vector(79 downto 0)) return std_logic_vector is
		variable sa, sb, rs : std_logic;
		variable ea, eb, re, sh, i : integer;
		variable ma, mb, bm, sm, rm : unsigned(63 downto 0);
		variable sum : unsigned(64 downto 0);
		variable dif : unsigned(63 downto 0);
		variable a_big : boolean;
	begin
		if is_nan(a) or is_nan(b) then return QNANv; end if;
		if is_inf(a) and is_inf(b) then
			if a(79) = b(79) then return a; else return QNANv; end if;
		end if;
		if is_inf(a)  then return a; end if;
		if is_inf(b)  then return b; end if;
		if is_zero(a) then return b; end if;
		if is_zero(b) then return a; end if;

		sa := a(79); sb := b(79);
		ea := to_integer(unsigned(a(78 downto 64)));
		eb := to_integer(unsigned(b(78 downto 64)));
		ma := unsigned(a(63 downto 0));
		mb := unsigned(b(63 downto 0));

		-- pick the larger magnitude as "big"
		if (ea > eb) or (ea = eb and ma >= mb) then a_big := true;  else a_big := false; end if;
		if a_big then re := ea; sh := ea - eb; bm := ma; rs := sa;
		             if sh >= 64 then sm := (others => '0'); else sm := shift_right(mb, sh); end if;
		else         re := eb; sh := eb - ea; bm := mb; rs := sb;
		             if sh >= 64 then sm := (others => '0'); else sm := shift_right(ma, sh); end if;
		end if;

		if sa = sb then                              -- same sign: add magnitudes
			sum := ('0' & bm) + ('0' & sm);
			if sum(64) = '1' then                    -- carry out of the integer bit
				rm := sum(64 downto 1);
				re := re + 1;
			else
				rm := sum(63 downto 0);
			end if;
		else                                         -- differing signs: subtract
			dif := bm - sm;
			if dif = 0 then return PZERO; end if;
			sh := 0;                                 -- normalize left (leading zeros)
			for i in 0 to 63 loop
				exit when dif(63) = '1';
				dif := shift_left(dif, 1);
				sh  := sh + 1;
			end loop;
			rm := dif;
			re := re - sh;
		end if;

		if re >= EXPMX then return make_inf(rs); end if;
		if re <= 0     then return PZERO; end if;    -- underflow -> zero (simplified)
		return rs & std_logic_vector(to_unsigned(re, 15)) & std_logic_vector(rm);
	end function;

	-- Extended-precision multiply. Round-toward-zero; NaN/Inf/Zero handled.
	function fp_mul(a, b : std_logic_vector(79 downto 0)) return std_logic_vector is
		variable rs : std_logic;
		variable ea, eb, re : integer;
		variable ma, mb : unsigned(63 downto 0);
		variable prod : unsigned(127 downto 0);
	begin
		if is_nan(a) or is_nan(b) then return QNANv; end if;
		rs := a(79) xor b(79);
		if (is_inf(a) and is_zero(b)) or (is_zero(a) and is_inf(b)) then return QNANv; end if;
		if is_inf(a)  or is_inf(b)  then return make_inf(rs); end if;
		if is_zero(a) or is_zero(b) then return rs & PZERO(78 downto 0); end if;

		ea := to_integer(unsigned(a(78 downto 64)));
		eb := to_integer(unsigned(b(78 downto 64)));
		ma := unsigned(a(63 downto 0));
		mb := unsigned(b(63 downto 0));

		prod := ma * mb;                             -- 64x64 -> 128
		re   := ea + eb - BIAS;
		if prod(127) = '1' then                      -- 1x.xxx -> normalize
			re := re + 1;
			-- take the top 64 bits
			if re >= EXPMX then return make_inf(rs); end if;
			if re <= 0     then return rs & PZERO(78 downto 0); end if;
			return rs & std_logic_vector(to_unsigned(re, 15)) & std_logic_vector(prod(127 downto 64));
		else                                         -- 1.xxx already normalized
			if re >= EXPMX then return make_inf(rs); end if;
			if re <= 0     then return rs & PZERO(78 downto 0); end if;
			return rs & std_logic_vector(to_unsigned(re, 15)) & std_logic_vector(prod(126 downto 63));
		end if;
	end function;

begin

	present  <= '1';
	fpsr_out <= FPSR;
	fpcr_out <= FPCR;

	process(clk)
		variable src  : std_logic_vector(79 downto 0);
		variable dstv : std_logic_vector(79 downto 0);
		variable bneg : std_logic_vector(79 downto 0);
		variable cc   : std_logic_vector(3 downto 0);
		variable res  : std_logic_vector(79 downto 0);
	begin
		if rising_edge(clk) then
			done   <= '0';
			unimpl <= '0';
			if reset = '1' then
				for i in 0 to 7 loop fpreg(i) <= (others => '0'); end loop;
				FPCR    <= (others => '0');
				FPSR    <= (others => '0');
				FPIAR   <= (others => '0');
				ext_out <= (others => '0');
			elsif op_valid = '1' then
				src  := fpreg(to_integer(unsigned(src_reg)));
				dstv := fpreg(to_integer(unsigned(dst_reg)));
				done <= '1';
				case cmd is
					when FPU_NOP => null;

					when FPU_FMOVE_RR =>
						fpreg(to_integer(unsigned(dst_reg))) <= src;
						cc := classify(src);
						FPSR(27 downto 24) <= cc;

					when FPU_FMOVE_LD =>
						fpreg(to_integer(unsigned(dst_reg))) <= ext_in;
						cc := classify(ext_in);
						FPSR(27 downto 24) <= cc;

					when FPU_FMOVE_ST =>
						ext_out <= fpreg(to_integer(unsigned(src_reg)));

					when FPU_FABS =>
						res := '0' & src(78 downto 0);
						fpreg(to_integer(unsigned(dst_reg))) <= res;
						FPSR(27 downto 24) <= classify(res);

					when FPU_FNEG =>
						res := (not src(79)) & src(78 downto 0);
						fpreg(to_integer(unsigned(dst_reg))) <= res;
						FPSR(27 downto 24) <= classify(res);

					when FPU_FTST =>
						FPSR(27 downto 24) <= classify(src);

					-- Hardware arithmetic (68k semantics: FPn = FPn <op> FPm).
					when FPU_FADD =>
						res := fp_addsub(dstv, src);
						fpreg(to_integer(unsigned(dst_reg))) <= res;
						FPSR(27 downto 24) <= classify(res);

					when FPU_FSUB =>
						bneg := (not src(79)) & src(78 downto 0);   -- FPn + (-FPm)
						res  := fp_addsub(dstv, bneg);
						fpreg(to_integer(unsigned(dst_reg))) <= res;
						FPSR(27 downto 24) <= classify(res);

					when FPU_FMUL =>
						res := fp_mul(dstv, src);
						fpreg(to_integer(unsigned(dst_reg))) <= res;
						FPSR(27 downto 24) <= classify(res);

					when FPU_TO_CR =>
						case cr_sel is
							when CR_FPCR  => FPCR  <= ext_in(31 downto 0);
							when CR_FPSR  => FPSR  <= ext_in(31 downto 0);
							when CR_FPIAR => FPIAR <= ext_in(31 downto 0);
							when others   => null;
						end case;

					when FPU_FROM_CR =>
						case cr_sel is
							when CR_FPCR  => ext_out <= x"000000000000" & FPCR;
							when CR_FPSR  => ext_out <= x"000000000000" & FPSR;
							when CR_FPIAR => ext_out <= x"000000000000" & FPIAR;
							when others   => ext_out <= (others => '0');
						end case;

					-- arithmetic + rounding conversions not implemented -> FPSP
					when others =>
						done   <= '0';
						unimpl <= '1';
				end case;
			end if;
		end if;
	end process;

end rtl;
