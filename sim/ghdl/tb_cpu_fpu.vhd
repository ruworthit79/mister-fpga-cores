------------------------------------------------------------------------------
--  tb_cpu_fpu - the CPU executes 68040 FPU (F-line) instructions (GHDL)
--
--  Acceptance test for wiring the kernel's F-line dispatch to the integrated
--  fpu_040. Proves the FPU is "live": register-to-register structural FPU
--  instructions decode, drive the FPU, and let execution continue (no line-F
--  trap), and the FPU's FPSR reflects the operation.
--
--  Requires cpu_wrapper to expose the FPU status as a debug port:
--     fpu_fpsr : out std_logic_vector(31 downto 0)   -- live FPSR
--     fpu_present : out std_logic                     -- 1 = FPU present
--
--  Program (supervisor mode after reset). FP0 = 0 at reset.
--     $08: FTST FP0        ; F200 003A   -> FPSR Z=1 (zero)
--     $0C: FNEG FP0        ; F200 001A   -> FP0 = -0, FPSR N=1 Z=1
--     $10: MOVE.L #$DEADBEEF,D0          ; 203C DEAD BEEF  (sentinel)
--     $16: MOVE.L D0,($100).L            ; 23C0 0000 0100
--     $1C: STOP #$2700                   ; 4E72 2700
--
--  PASS if:
--    - $100 = $DEADBEEF  (execution continued PAST the FPU ops = no F-line trap)
--    - fpu_present = 1
--    - fpu_fpsr Z (bit26) = 1 and N (bit27) = 1  (FNEG of zero -> -0)
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpu_fpu is
end tb_cpu_fpu;

architecture sim of tb_cpu_fpu is
	signal clk   : std_logic := '0';
	signal reset : std_logic := '1';
	signal ce    : std_logic := '0';
	signal addr  : std_logic_vector(31 downto 0);
	signal dout  : std_logic_vector(31 downto 0);
	signal din   : std_logic_vector(31 downto 0) := (others => '0');
	signal be    : std_logic_vector(3 downto 0);
	signal rw    : std_logic;
	signal ts    : std_logic;
	signal ta    : std_logic := '0';
	signal fc    : std_logic_vector(2 downto 0);
	signal fpu_fpsr    : std_logic_vector(31 downto 0);
	signal fpu_present : std_logic;

	type mem_t is array(0 to 511) of std_logic_vector(7 downto 0);
	signal mem : mem_t := (
		16#00# => x"00", 16#01# => x"00", 16#02# => x"10", 16#03# => x"00", -- SSP
		16#04# => x"00", 16#05# => x"00", 16#06# => x"00", 16#07# => x"08", -- PC
		16#08# => x"F2", 16#09# => x"00", 16#0A# => x"00", 16#0B# => x"3A", -- FTST FP0
		16#0C# => x"F2", 16#0D# => x"00", 16#0E# => x"00", 16#0F# => x"A2", -- FADD FP0,FP1 (HW)
		16#10# => x"F2", 16#11# => x"00", 16#12# => x"00", 16#13# => x"1A", -- FNEG FP0
		16#14# => x"20", 16#15# => x"3C", 16#16# => x"DE", 16#17# => x"AD",
		16#18# => x"BE", 16#19# => x"EF",                                   -- MOVE.L #$DEADBEEF,D0
		16#1A# => x"23", 16#1B# => x"C0", 16#1C# => x"00", 16#1D# => x"00",
		16#1E# => x"01", 16#1F# => x"00",                                   -- MOVE.L D0,($100).L
		16#20# => x"4E", 16#21# => x"72", 16#22# => x"27", 16#23# => x"00", -- STOP #$2700
		others => x"00"
	);

	signal a_lat : integer range 0 to 511 := 0;
begin
	-- NOTE: cpu_wrapper must be extended with fpu_fpsr / fpu_present outputs and
	-- must instantiate fpu_040, driven by the kernel's F-line decode.
	dut : entity work.cpu_wrapper
		port map(clk => clk, ce => ce, reset => reset, addr => addr, dout => dout,
		         din => din, be => be, rw => rw, ts => ts, ta => ta, fc => fc,
		         ipl => "111", fpu_fpsr => fpu_fpsr, fpu_present => fpu_present);

	clk <= not clk after 10 ns;

	ce_gen : process(clk)
		variable c : integer range 0 to 2 := 0;
	begin
		if rising_edge(clk) then
			if c = 2 then c := 0; ce <= '1'; else c := c + 1; ce <= '0'; end if;
		end if;
	end process;

	din <= mem(a_lat) & mem(a_lat + 1) & mem(a_lat + 2) & mem(a_lat + 3);

	mem_proc : process(clk)
		variable base     : integer range 0 to 508;
		variable serviced : std_logic := '0';
	begin
		if rising_edge(clk) then
			ta <= '0';
			if ts = '1' then
				if serviced = '0' then
					base  := to_integer(unsigned(addr(8 downto 2))) * 4;
					a_lat <= base;
					if rw = '0' then
						if be(3) = '1' then mem(base + 0) <= dout(31 downto 24); end if;
						if be(2) = '1' then mem(base + 1) <= dout(23 downto 16); end if;
						if be(1) = '1' then mem(base + 2) <= dout(15 downto  8); end if;
						if be(0) = '1' then mem(base + 3) <= dout( 7 downto  0); end if;
					end if;
					ta <= '1';
					serviced := '1';
				end if;
			else
				serviced := '0';
			end if;
		end if;
	end process;

	stim : process
		variable errors : integer := 0;
		procedure chk(cond : boolean; msg : string) is
		begin
			if not cond then report "FAIL: " & msg severity warning; errors := errors + 1; end if;
		end procedure;
	begin
		reset <= '1'; wait for 200 ns; reset <= '0';
		for i in 0 to 8000 loop wait until rising_edge(clk); end loop;

		chk(fpu_present = '1', "FPU present");
		chk(mem(16#100#)=x"DE" and mem(16#101#)=x"AD" and mem(16#102#)=x"BE" and mem(16#103#)=x"EF",
		    "execution continued past FPU ops (no F-line trap); $100=$DEADBEEF, got 0x" &
		    to_hstring(mem(16#100#)&mem(16#101#)&mem(16#102#)&mem(16#103#)));
		chk(fpu_fpsr(26)='1', "FPSR Z set (FNEG of zero -> -0)");
		chk(fpu_fpsr(27)='1', "FPSR N set (FNEG of zero -> -0)");

		if errors = 0 then
			report "PASS: CPU executes FPU F-line ops (FTST/FADD/FNEG live; FPSR Z/N; no trap)" severity note;
		else
			report "FAIL: CPU/FPU F-line dispatch" severity failure;
		end if;
		std.env.finish;
	end process;
end sim;
