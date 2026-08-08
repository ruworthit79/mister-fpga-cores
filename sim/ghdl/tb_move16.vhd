------------------------------------------------------------------------------
--  tb_move16 - 68040 MOVE16 (Ax)+,(Ay)+ 16-byte block move (GHDL)
--
--     $08: MOVEA.L #$00000200,A0    ; 207C 0000 0200
--     $0E: MOVEA.L #$00000300,A1    ; 227C 0000 0300
--     $14: MOVE16  (A0)+,(A1)+      ; F620 9000
--     $18: MOVE.L  A0,($400).L      ; 23C8 0000 0400
--     $1E: MOVE.L  A1,($404).L      ; 23C9 0000 0404
--     $24: STOP    #$2700           ; 4E72 2700
--
--  Source $200..$20F preloaded with 00 11 22 .. FF. PASS if $300..$30F equals
--  it, A0=$210 ($400), A1=$310 ($404).
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_move16 is
end tb_move16;

architecture sim of tb_move16 is
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

	type mem_t is array(0 to 2047) of std_logic_vector(7 downto 0);

	function init_mem return mem_t is
		variable m : mem_t := (others => x"00");
	begin
		m(16#00#):=x"00"; m(16#01#):=x"00"; m(16#02#):=x"10"; m(16#03#):=x"00"; -- SSP
		m(16#04#):=x"00"; m(16#05#):=x"00"; m(16#06#):=x"00"; m(16#07#):=x"08"; -- PC
		m(16#08#):=x"20"; m(16#09#):=x"7C"; m(16#0A#):=x"00"; m(16#0B#):=x"00";
		m(16#0C#):=x"02"; m(16#0D#):=x"00";                                     -- MOVEA.L #$200,A0
		m(16#0E#):=x"22"; m(16#0F#):=x"7C"; m(16#10#):=x"00"; m(16#11#):=x"00";
		m(16#12#):=x"03"; m(16#13#):=x"00";                                     -- MOVEA.L #$300,A1
		m(16#14#):=x"F6"; m(16#15#):=x"20"; m(16#16#):=x"90"; m(16#17#):=x"00"; -- MOVE16 (A0)+,(A1)+
		m(16#18#):=x"23"; m(16#19#):=x"C8"; m(16#1A#):=x"00"; m(16#1B#):=x"00";
		m(16#1C#):=x"04"; m(16#1D#):=x"00";                                     -- MOVE.L A0,($400).L
		m(16#1E#):=x"23"; m(16#1F#):=x"C9"; m(16#20#):=x"00"; m(16#21#):=x"00";
		m(16#22#):=x"04"; m(16#23#):=x"04";                                     -- MOVE.L A1,($404).L
		m(16#24#):=x"4E"; m(16#25#):=x"72"; m(16#26#):=x"27"; m(16#27#):=x"00"; -- STOP #$2700
		-- source data at $200: 00 11 22 33 .. FF
		for i in 0 to 15 loop
			m(16#200# + i) := std_logic_vector(to_unsigned(i*16 + i, 8));
		end loop;
		return m;
	end function;

	signal mem   : mem_t := init_mem;
	signal a_lat : integer range 0 to 2047 := 0;
begin
	dut : entity work.cpu_wrapper
		port map(clk => clk, ce => ce, reset => reset, addr => addr, dout => dout,
		         din => din, be => be, rw => rw, ts => ts, ta => ta, fc => fc, ipl => "111");

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
		variable base     : integer range 0 to 2044;
		variable serviced : std_logic := '0';
	begin
		if rising_edge(clk) then
			ta <= '0';
			if ts = '1' then
				if serviced = '0' then
					base  := to_integer(unsigned(addr(10 downto 2))) * 4;
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
		variable ok : boolean := true;
	begin
		reset <= '1';
		wait for 200 ns;
		reset <= '0';
		for i in 0 to 12000 loop
			wait until rising_edge(clk);
		end loop;

		for i in 0 to 15 loop
			assert mem(16#300# + i) = mem(16#200# + i)
				report "FAIL: dest byte " & integer'image(i) & " = 0x" &
					to_hstring(mem(16#300# + i)) & " expected 0x" & to_hstring(mem(16#200# + i))
				severity failure;
		end loop;

		assert mem(16#400#)=x"00" and mem(16#401#)=x"00" and mem(16#402#)=x"02" and mem(16#403#)=x"10"
			report "FAIL: A0 post-increment = 0x" &
				to_hstring(mem(16#400#)&mem(16#401#)&mem(16#402#)&mem(16#403#)) & " expected 0x00000210"
			severity failure;
		assert mem(16#404#)=x"00" and mem(16#405#)=x"00" and mem(16#406#)=x"03" and mem(16#407#)=x"10"
			report "FAIL: A1 post-increment = 0x" &
				to_hstring(mem(16#404#)&mem(16#405#)&mem(16#406#)&mem(16#407#)) & " expected 0x00000310"
			severity failure;

		report "PASS: MOVE16 (A0)+,(A1)+ moved 16 bytes; A0=$210 A1=$310" severity note;
		std.env.finish;
	end process;
end sim;
