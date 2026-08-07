------------------------------------------------------------------------------
--  tb_cpu - end-to-end CPU test for the Quadra 950 core (GHDL)
--
--  Instantiates the real TG68 core via cpu_wrapper and a behavioral 32-bit
--  memory that speaks the core's TS/TA bus protocol. Memory is preloaded with
--  a tiny hand-assembled 68k program:
--
--     reset SSP = $00001000   (long @ $00)
--     reset PC  = $00000008   (long @ $04)
--     $08:  MOVE.L #$12345678,D0     ; 203C 1234 5678
--     $0E:  MOVE.L D0,($00000100).L  ; 23C0 0000 0100
--     $14:  STOP   #$2700            ; 4E72 2700
--
--  PASS if location $100 holds $12345678 after the program runs, proving the
--  CPU fetched and executed instructions through the adapter's bus.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpu is
end tb_cpu;

architecture sim of tb_cpu is

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
		16#08# => x"20", 16#09# => x"3C",                                   -- MOVE.L #imm,D0
		16#0A# => x"12", 16#0B# => x"34", 16#0C# => x"56", 16#0D# => x"78", -- $12345678
		16#0E# => x"23", 16#0F# => x"C0",                                   -- MOVE.L D0,(abs).L
		16#10# => x"00", 16#11# => x"00", 16#12# => x"01", 16#13# => x"00", -- $00000100
		16#14# => x"4E", 16#15# => x"72", 16#16# => x"27", 16#17# => x"00", -- STOP #$2700
		others => x"00"
	);

	signal a_lat : integer range 0 to 511 := 0;
	signal done  : boolean := false;

begin

	dut : entity work.cpu_wrapper
		port map(
			clk => clk, ce => ce, reset => reset,
			addr => addr, dout => dout, din => din, be => be,
			rw => rw, ts => ts, ta => ta, fc => fc, ipl => "111"  -- no interrupt (active low)
		);

	clk <= not clk after 10 ns;            -- 50 MHz

	-- ce: a divided clock enable (high 1 clk in 3), so the CPU advances at an
	-- emulated slower rate. Validates that the bus adapter tolerates ce<1
	-- (freezes cleanly and still completes transfers).
	ce_gen : process(clk)
		variable c : integer range 0 to 2 := 0;
	begin
		if rising_edge(clk) then
			if c = 2 then c := 0; ce <= '1'; else c := c + 1; ce <= '0'; end if;
		end if;
	end process;

	-- Combinational read data: big-endian 32-bit word at the latched (word-
	-- aligned) address. a_lat is stored already aligned to 4.
	din <= mem(a_lat) & mem(a_lat + 1) & mem(a_lat + 2) & mem(a_lat + 3);

	-- Behavioral memory implementing the TS/TA handshake. TA is asserted for a
	-- SINGLE cycle (pulsed ack) - deliberately the hard case: combined with the
	-- 1-in-3 ce enable, the pulse often lands in a ce-disabled cycle, so this
	-- exercises the adapter's ta-capture-across-ce-gaps logic.
	mem_proc : process(clk)
		variable base     : integer range 0 to 508;
		variable n        : integer := 0;
		variable serviced : std_logic := '0';
	begin
		if rising_edge(clk) then
			ta <= '0';
			if ts = '1' then
				if serviced = '0' then
					base  := to_integer(unsigned(addr(8 downto 2))) * 4;  -- align to 4
					a_lat <= base;
					if n < 40 then
						report "acc#" & integer'image(n) &
							" addr=0x" & to_hstring(addr) &
							" rw=" & std_logic'image(rw) &
							" rword=0x" & to_hstring(mem(base) & mem(base+1) & mem(base+2) & mem(base+3)) &
							" wdata=0x" & to_hstring(dout);
						n := n + 1;
					end if;
					if rw = '0' then               -- write, honour byte enables
						if be(3) = '1' then mem(base + 0) <= dout(31 downto 24); end if;
						if be(2) = '1' then mem(base + 1) <= dout(23 downto 16); end if;
						if be(1) = '1' then mem(base + 2) <= dout(15 downto  8); end if;
						if be(0) = '1' then mem(base + 3) <= dout( 7 downto  0); end if;
					end if;
					ta <= '1';                     -- single-cycle ack pulse
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

		-- Let the program run.
		for i in 0 to 6000 loop
			wait until rising_edge(clk);
		end loop;

		-- Check result at $100.
		assert mem(16#100#) = x"12" and mem(16#101#) = x"34" and
		       mem(16#102#) = x"56" and mem(16#103#) = x"78"
			report "FAIL: $100 = " &
				integer'image(to_integer(unsigned(mem(16#100#)))) & " " &
				integer'image(to_integer(unsigned(mem(16#101#)))) & " " &
				integer'image(to_integer(unsigned(mem(16#102#)))) & " " &
				integer'image(to_integer(unsigned(mem(16#103#))))
			severity failure;

		report "PASS: CPU executed program; $100 = 0x12345678" severity note;
		std.env.finish;
	end process;

end sim;
