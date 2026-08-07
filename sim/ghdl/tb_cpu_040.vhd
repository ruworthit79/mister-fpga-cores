------------------------------------------------------------------------------
--  tb_cpu_040 - MOVEC 68040 control-register round-trip test (GHDL)
--
--  Verifies the 040 personality added to the TG68 kernel: MOVEC to/from the
--  68040 MMU control registers (TC/ITTx/DTTx/URP/SRP/MMUSR) must STORE the
--  written value and READ IT BACK unchanged, or the ROM's MMU bring-up (which
--  writes a translation register and reads it back to verify) faults.
--
--  Hand-assembled program (supervisor mode after reset, MOVEC is privileged):
--     $08: MOVE.L #$00C04000,D0     ; 203C 00C0 4000
--     $0E: MOVEC  D0,DTT0           ; 4E7B 0006   (Rc $006 = DTT0)
--     $12: MOVEC  DTT0,D1           ; 4E7A 1006
--     $16: MOVE.L D1,($100).L       ; 23C1 0000 0100   -> expect $00C04000
--     $1C: MOVE.L #$C0008000,D0     ; 203C C000 8000
--     $22: MOVEC  D0,TC             ; 4E7B 0003   (Rc $003 = TC)
--     $26: MOVEC  TC,D2             ; 4E7A 2003
--     $2A: MOVE.L D2,($104).L       ; 23C2 0000 0104   -> expect $C0008000
--     $30: STOP   #$2700            ; 4E72 2700
--
--  PASS if $100 = $00C04000 and $104 = $C0008000 (both registers round-trip).
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpu_040 is
end tb_cpu_040;

architecture sim of tb_cpu_040 is

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
		16#08# => x"20", 16#09# => x"3C", 16#0A# => x"00", 16#0B# => x"C0",
		16#0C# => x"40", 16#0D# => x"00",                                   -- MOVE.L #$00C04000,D0
		16#0E# => x"4E", 16#0F# => x"7B", 16#10# => x"00", 16#11# => x"06", -- MOVEC D0,DTT0
		16#12# => x"4E", 16#13# => x"7A", 16#14# => x"10", 16#15# => x"06", -- MOVEC DTT0,D1
		16#16# => x"23", 16#17# => x"C1", 16#18# => x"00", 16#19# => x"00",
		16#1A# => x"01", 16#1B# => x"00",                                   -- MOVE.L D1,($100).L
		16#1C# => x"20", 16#1D# => x"3C", 16#1E# => x"C0", 16#1F# => x"00",
		16#20# => x"80", 16#21# => x"00",                                   -- MOVE.L #$C0008000,D0
		16#22# => x"4E", 16#23# => x"7B", 16#24# => x"00", 16#25# => x"03", -- MOVEC D0,TC
		16#26# => x"4E", 16#27# => x"7A", 16#28# => x"20", 16#29# => x"03", -- MOVEC TC,D2
		16#2A# => x"23", 16#2B# => x"C2", 16#2C# => x"00", 16#2D# => x"00",
		16#2E# => x"01", 16#2F# => x"04",                                   -- MOVE.L D2,($104).L
		16#30# => x"4E", 16#31# => x"72", 16#32# => x"27", 16#33# => x"00", -- STOP #$2700
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

		assert mem(16#100#) = x"00" and mem(16#101#) = x"C0" and
		       mem(16#102#) = x"40" and mem(16#103#) = x"00"
			report "FAIL: DTT0 round-trip, $100 = 0x" &
				to_hstring(mem(16#100#) & mem(16#101#) & mem(16#102#) & mem(16#103#))
			severity failure;

		assert mem(16#104#) = x"C0" and mem(16#105#) = x"00" and
		       mem(16#106#) = x"80" and mem(16#107#) = x"00"
			report "FAIL: TC round-trip, $104 = 0x" &
				to_hstring(mem(16#104#) & mem(16#105#) & mem(16#106#) & mem(16#107#))
			severity failure;

		report "PASS: MOVEC 040 regs round-trip (DTT0=$00C04000, TC=$C0008000)" severity note;
		std.env.finish;
	end process;

end sim;
