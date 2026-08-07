------------------------------------------------------------------------------
--  cpu_wrapper - 68k CPU integration + bus adapter for the Quadra 950 core
--
--  Wraps the TG68KdotC kernel (Tobias Gubener, LGPLv3, vendored in tg68k/) and
--  adapts its 16-bit, clock-enable-driven bus to the core's simplified
--  68040-style synchronous 32-bit bus (TS asserts a transfer, TA acknowledges).
--
--  This is the Phase-1 CPU: a 68020-class core standing in for the 68040 so the
--  system (memory, video, I/O) can be brought up. See docs/CPU_NOTES.md for the
--  path from here to real 040 behaviour (MMU, FPU, cache/burst).
--
--  The TG68 kernel performs 32-bit accesses as pairs of 16-bit word cycles and
--  signals each access via `busstate`:
--     "00" fetch code   "10" read data   "11" write data   "01" no access
--  It advances one internal step whenever clkena_in is high. This wrapper runs
--  a bus cycle (TS..TA) for each memory access and pulses clkena_in to advance
--  the core, gated by `ce` so the CPU runs at the emulated ~33 MHz.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_wrapper is
	port(
		clk   : in  std_logic;
		ce    : in  std_logic;                       -- 33 MHz clock enable
		reset : in  std_logic;                       -- active high

		addr  : out std_logic_vector(31 downto 0);
		dout  : out std_logic_vector(31 downto 0);   -- CPU -> bus (write data)
		din   : in  std_logic_vector(31 downto 0);   -- bus -> CPU (read data)
		be    : out std_logic_vector(3 downto 0);    -- byte enables (big-endian)
		rw    : out std_logic;                       -- 1 = read, 0 = write
		ts    : out std_logic;                       -- transfer start
		ta    : in  std_logic;                       -- transfer acknowledge
		berr  : in  std_logic := '0';                -- bus error (TEA): abort the
		                                             -- cycle and take exception
		fc    : out std_logic_vector(2 downto 0);    -- function code

		ipl   : in  std_logic_vector(2 downto 0)     -- interrupt priority level
	);
end cpu_wrapper;

architecture rtl of cpu_wrapper is

	component TG68KdotC_Kernel is
		generic(
			SR_Read        : integer := 2;
			VBR_Stackframe : integer := 2;
			extAddr_Mode   : integer := 2;
			MUL_Mode       : integer := 2;
			DIV_Mode       : integer := 2;
			BitField       : integer := 2;
			BarrelShifter  : integer := 1;
			MUL_Hardware   : integer := 1
		);
		port(
			clk            : in  std_logic;
			nReset         : in  std_logic;
			clkena_in      : in  std_logic;
			data_in        : in  std_logic_vector(15 downto 0);
			IPL            : in  std_logic_vector(2 downto 0);
			IPL_autovector : in  std_logic;
			berr           : in  std_logic;
			CPU            : in  std_logic_vector(1 downto 0);
			addr_out       : out std_logic_vector(31 downto 0);
			data_write     : out std_logic_vector(15 downto 0);
			nWr            : out std_logic;
			nUDS           : out std_logic;
			nLDS           : out std_logic;
			busstate       : out std_logic_vector(1 downto 0);
			longword       : out std_logic;
			nResetOut      : out std_logic;
			FC             : out std_logic_vector(2 downto 0);
			clr_berr       : out std_logic;
			skipFetch      : out std_logic;
			regin_out      : out std_logic_vector(31 downto 0);
			CACR_out       : out std_logic_vector(3 downto 0);
			VBR_out        : out std_logic_vector(31 downto 0)
		);
	end component;

	-- Kernel <-> wrapper signals
	signal k_addr      : std_logic_vector(31 downto 0);
	signal k_data_w    : std_logic_vector(15 downto 0);
	signal k_data_in   : std_logic_vector(15 downto 0);
	signal k_nWr       : std_logic;
	signal k_nUDS      : std_logic;
	signal k_nLDS      : std_logic;
	signal k_busstate  : std_logic_vector(1 downto 0);
	signal k_longword  : std_logic;
	signal k_fc        : std_logic_vector(2 downto 0);
	signal k_clkena    : std_logic;

	signal k_skip : std_logic;                      -- kernel wants to skip a fetch

	-- unused kernel debug outputs
	signal u_nrst, u_clrberr         : std_logic;
	signal u_regin, u_vbr            : std_logic_vector(31 downto 0);
	signal u_cacr                    : std_logic_vector(3 downto 0);

	-- bus cycle FSM (mirrors the reference TG68K.vhd phases):
	--   "00" idle/evaluate  "01" assert TS  "10" sample TA + latch data  "11" advance
	signal s_state    : std_logic_vector(1 downto 0);
	signal clkena_e   : std_logic;                  -- memory-completion pulse
	signal r_data     : std_logic_vector(15 downto 0);
	signal ta_lat     : std_logic;                  -- TA captured across ce gaps
	signal berr_pend  : std_logic;                  -- a bus error is being taken

	signal mem_access : std_logic;
	signal uds, lds   : std_logic;

begin

	cpu : TG68KdotC_Kernel
		generic map(
			SR_Read => 2, VBR_Stackframe => 2, extAddr_Mode => 2,
			MUL_Mode => 2, DIV_Mode => 2, BitField => 2,
			BarrelShifter => 1, MUL_Hardware => 1
		)
		port map(
			clk => clk, nReset => not reset, clkena_in => k_clkena,
			data_in => k_data_in, IPL => ipl, IPL_autovector => '1',
			berr => berr_pend, CPU => "11",     -- 68020 mode; berr on TEA
			addr_out => k_addr, data_write => k_data_w,
			nWr => k_nWr, nUDS => k_nUDS, nLDS => k_nLDS,
			busstate => k_busstate, longword => k_longword,
			nResetOut => u_nrst, FC => k_fc, clr_berr => u_clrberr,
			skipFetch => k_skip, regin_out => u_regin,
			CACR_out => u_cacr, VBR_out => u_vbr
		);

	mem_access <= '0' when k_busstate = "01" else '1';
	uds <= not k_nUDS;
	lds <= not k_nLDS;

	-- Combinational bus outputs (stable while the kernel is stalled).
	addr <= k_addr;
	rw   <= k_nWr;                                  -- 1 = read, 0 = write
	fc   <= k_fc;
	ts   <= '1' when (s_state = "01" or s_state = "10") else '0';

	-- Byte enables + write-data placement (big-endian: byte 0 = bits 31..24)
	be <= (uds & lds & '0' & '0') when k_addr(1) = '0'
	      else ('0' & '0' & uds & lds);
	dout <= (k_data_w & x"0000") when k_addr(1) = '0'
	        else (x"0000" & k_data_w);

	-- Kernel read data: the addressed 16-bit half, registered in phase "10".
	k_data_in <= r_data;

	-- Completion pulse: assert one cycle AFTER data is latched, matching the
	-- reference's clkena-in-last-phase timing.
	clkena_e <= '1' when s_state = "11" else '0';

	-- Advance the kernel: level-based on the LIVE busstate (no-access steps and
	-- skipped fetches advance every cycle; memory accesses advance in phase "11").
	-- Gated by ce so the CPU runs at the emulated rate.
	k_clkena <= ce and (clkena_e or k_skip or (not mem_access));

	process(clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then
				s_state   <= "00";
				r_data    <= (others => '0');
				berr_pend <= '0';
			elsif ce = '1' then
				case s_state is
					when "00" =>                    -- evaluate live busstate
						berr_pend <= '0';
						if mem_access = '1' and k_skip = '0' then
							s_state <= "01";        -- begin a bus cycle
						end if;
					when "01" =>                    -- TS asserted
						s_state <= "10";
					when "10" =>                    -- sample TA (or bus error)
						if ta = '1' or ta_lat = '1' then
							if k_addr(1) = '0' then
								r_data <= din(31 downto 16);
							else
								r_data <= din(15 downto 0);
							end if;
							s_state <= "11";        -- ready -> advance next
						elsif berr = '1' then       -- unmapped/timeout: bus error
							berr_pend <= '1';        -- take TEA on the advance cycle
							s_state   <= "11";
						end if;
					when others =>                  -- "11" advance the kernel
						berr_pend <= '0';
						s_state   <= "00";
				end case;
			end if;
		end if;
	end process;

	-- Capture TA across ce gaps: devices may pulse TA for a single clock, which
	-- could fall in a ce-disabled cycle. Latch it (ungated by ce) for the whole
	-- bus cycle so the CPU still completes the transfer at the emulated rate.
	process(clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then         ta_lat <= '0';
			elsif s_state = "00" then   ta_lat <= '0';   -- idle: clear before a cycle
			elsif ta = '1' then         ta_lat <= '1';   -- capture ack during 01/10
			end if;
		end if;
	end process;

end rtl;
