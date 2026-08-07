------------------------------------------------------------------------------
--  tb_cpu_040nop - 68040 cache/MMU control instructions execute as no-ops
--
--  On a real 68040 the cache ($F4xx: CINV/CPUSH) and MMU ($F5xx: PFLUSH/PTEST)
--  control instructions execute in supervisor mode. This core has no cache and
--  a transparent (1:1) MMU, so they must be architecturally valid no-ops -- NOT
--  line-F traps (which the 040 ROM/OS does not expect for these opcodes and
--  cannot service, hanging boot). This test runs a batch of them between a
--  register load and a store; the stored value must be untouched, proving the
--  CPU consumed each opcode and continued without trapping.
--
--     $08: MOVE.L #$AAAA5555,D0     ; 203C AAAA 5555
--     $0E: CPUSHA bc                ; F4F8
--     $10: CINV... (bc)             ; F418
--     $12: PFLUSHA                  ; F518
--     $14: PTEST (a0)               ; F548
--     $16: NOP                      ; 4E71
--     $18: MOVE.L D0,($100).L       ; 23C0 0000 0100
--     $1E: STOP #$2700              ; 4E72 2700
--
--  PASS if $100 = $AAAA5555 (no trap diverted execution).
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpu_040nop is
end tb_cpu_040nop;

architecture sim of tb_cpu_040nop is

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

	type mem_t is array(0 to 511) of std_logic_vector(7 downto 0);
	signal mem : mem_t := (
		16#00# => x"00", 16#01# => x"00", 16#02# => x"10", 16#03# => x"00", -- SSP
		16#04# => x"00", 16#05# => x"00", 16#06# => x"00", 16#07# => x"08", -- PC
		16#08# => x"20", 16#09# => x"3C", 16#0A# => x"AA", 16#0B# => x"AA",
		16#0C# => x"55", 16#0D# => x"55",                                   -- MOVE.L #$AAAA5555,D0
		16#0E# => x"F4", 16#0F# => x"F8",                                   -- CPUSHA bc
		16#10# => x"F4", 16#11# => x"18",                                   -- CINV (bc)
		16#12# => x"F5", 16#13# => x"18",                                   -- PFLUSHA
		16#14# => x"F5", 16#15# => x"48",                                   -- PTEST (a0)
		16#16# => x"4E", 16#17# => x"71",                                   -- NOP
		16#18# => x"23", 16#19# => x"C0", 16#1A# => x"00", 16#1B# => x"00",
		16#1C# => x"01", 16#1D# => x"00",                                   -- MOVE.L D0,($100).L
		16#1E# => x"4E", 16#1F# => x"72", 16#20# => x"27", 16#21# => x"00", -- STOP #$2700
		others => x"00"
	);

	signal a_lat : integer range 0 to 511 := 0;

begin

	dut : entity work.cpu_wrapper
		port map(
			clk => clk, ce => ce, reset => reset,
			addr => addr, dout => dout, din => din, be => be,
			rw => rw, ts => ts, ta => ta, fc => fc, ipl => "111"
		);

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
	begin
		reset <= '1';
		wait for 200 ns;
		reset <= '0';

		for i in 0 to 8000 loop
			wait until rising_edge(clk);
		end loop;

		assert mem(16#100#) = x"AA" and mem(16#101#) = x"AA" and
		       mem(16#102#) = x"55" and mem(16#103#) = x"55"
			report "FAIL: an 040 cache/MMU op trapped or corrupted D0; $100 = 0x" &
				to_hstring(mem(16#100#) & mem(16#101#) & mem(16#102#) & mem(16#103#))
			severity failure;

		report "PASS: CPUSHA/CINV/PFLUSHA/PTEST executed as no-ops ($100 = 0xAAAA5555)" severity note;
		std.env.finish;
	end process;

end sim;
