----------------------------------------------------------------------------------
-- SPC7110.vhd
-- SPC7110 Chip Emulation Core
--
-- Implements the complete SPC7110 register file ($4800-$484F), state machines
-- for Data ROM access, decompression DMA, bank mapping, multiply/divide, and
-- the RTC-4513 interface.
--
-- PSRAM address output (this module drives ROM_ADDR_OUT):
--   Direct data ROM:  ROM_ADDR = 24'h100000 + {reg_4803,reg_4802,reg_4801}
--   Decompressor:     ROM_ADDR = 24'h100000 + comp_ptr (init from reg_4813:4811)
--   SNES-direct DROM: handled in main.v as {1'b0,(reg_483x+1),snes_addr[19:0]}
--     (bank 0 -> PSRAM $100000, bank 1 -> $200000, ...)
--
-- Decompressed data buffer: 64-byte rolling BRAM, addressed mod 64.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SPC7110 is
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;

    -- SNES bus interface (synchronous, already debounced by main.v)
    SNES_ADDR     : in  std_logic_vector(23 downto 0);
    SNES_WR       : in  std_logic;   -- active-low write strobe
    SNES_RD       : in  std_logic;   -- active-low read strobe
    SNES_WR_end   : in  std_logic;   -- single-cycle pulse on WR falling edge
    SNES_RD_start : in  std_logic;   -- single-cycle pulse on RD rising edge
    SNES_DATA_IN  : in  std_logic_vector(7 downto 0);
    SNES_DATA_OUT : out std_logic_vector(7 downto 0);
    SNES_DATA_OE  : out std_logic;   -- '1' when chip drives data bus

    -- PSRAM interface (to mapper arbitration in SPC7110Map)
    ROM_REQ       : out std_logic;   -- request bus to PSRAM
    ROM_ADDR_OUT  : out std_logic_vector(23 downto 0);
    ROM_DATA_IN   : in  std_logic_vector(7 downto 0);
    ROM_ACK       : in  std_logic;   -- single-cycle pulse when data ready

    -- RTC interface (to rtc.v)
    RTC_INDEX     : out std_logic_vector(3 downto 0);
    RTC_DATA_OUT  : out std_logic_vector(3 downto 0);
    RTC_DATA_IN   : in  std_logic_vector(3 downto 0);
    RTC_WR        : out std_logic;
    RTC_RD        : out std_logic;
    RTC_EN        : in  std_logic;   -- FEAT_SRTC enabled from featurebits

    -- DROM bank registers exposed for main.v PSRAM address mux
    DROM_BANK_D   : out std_logic_vector(2 downto 0);  -- reg_4831[2:0]
    DROM_BANK_E   : out std_logic_vector(2 downto 0);  -- reg_4832[2:0]
    DROM_BANK_F   : out std_logic_vector(2 downto 0)   -- reg_4833[2:0]
  );
end entity SPC7110;

architecture rtl of SPC7110 is

  -- -------------------------------------------------------------------------
  -- Register file ($4800-$484F)
  -- -------------------------------------------------------------------------

  -- Data ROM access registers
  signal reg_4800 : std_logic_vector(7 downto 0);   -- data port (read-only, auto)
  signal reg_4801 : std_logic_vector(7 downto 0);   -- DROM pointer [7:0]
  signal reg_4802 : std_logic_vector(7 downto 0);   -- DROM pointer [15:8]
  signal reg_4803 : std_logic_vector(7 downto 0);   -- DROM pointer [23:16]
  signal reg_4804 : std_logic_vector(7 downto 0);   -- DROM address adjust [7:0]
  signal reg_4805 : std_logic_vector(7 downto 0);   -- DROM length [7:0]
  signal reg_4806 : std_logic_vector(7 downto 0);   -- DROM length [15:8]
  signal reg_4807 : std_logic_vector(7 downto 0);   -- DROM mode/endian
  signal reg_4809 : std_logic_vector(7 downto 0);   -- DROM counter [7:0]   (R)
  signal reg_480A : std_logic_vector(7 downto 0);   -- DROM counter [15:8]  (R)
  signal reg_480B : std_logic_vector(7 downto 0);   -- DROM bank (direct read)

  -- Decompressor registers
  signal reg_4810 : std_logic_vector(7 downto 0);   -- decomp output port (read)
  signal reg_4811 : std_logic_vector(7 downto 0);   -- decomp address [7:0]
  signal reg_4812 : std_logic_vector(7 downto 0);   -- decomp address [15:8]
  signal reg_4813 : std_logic_vector(7 downto 0);   -- decomp address [23:16]
  signal reg_4814 : std_logic_vector(7 downto 0);   -- decomp adjust [7:0]
  signal reg_4815 : std_logic_vector(7 downto 0);   -- decomp adjust [15:8]
  signal reg_4816 : std_logic_vector(7 downto 0);   -- decomp length [7:0]
  signal reg_4817 : std_logic_vector(7 downto 0);   -- decomp length [15:8]
  signal reg_4818 : std_logic_vector(7 downto 0);   -- decomp control
  signal reg_481A : std_logic_vector(7 downto 0);   -- decomp length adjust

  -- Mul/div registers
  signal reg_4820 : std_logic_vector(7 downto 0);  -- multiplicand lo / dividend[7:0]
  signal reg_4821 : std_logic_vector(7 downto 0);  -- multiplicand hi / dividend[15:8]
  signal reg_4822 : std_logic_vector(7 downto 0);  -- dividend[23:16]
  signal reg_4823 : std_logic_vector(7 downto 0);  -- dividend[31:24]
  signal reg_4824 : std_logic_vector(7 downto 0);  -- multiplier lo
  signal reg_4825 : std_logic_vector(7 downto 0);  -- multiplier hi  (write triggers multiply)
  signal reg_4826 : std_logic_vector(7 downto 0);  -- divisor lo
  signal reg_4827 : std_logic_vector(7 downto 0);  -- divisor hi     (write triggers divide)
  signal reg_4828 : std_logic_vector(7 downto 0);  -- result lo lo (R)
  signal reg_4829 : std_logic_vector(7 downto 0);  -- result lo hi (R)
  signal reg_482A : std_logic_vector(7 downto 0);  -- result hi lo (R)
  signal reg_482B : std_logic_vector(7 downto 0);  -- result hi hi (R)
  signal reg_482C : std_logic_vector(7 downto 0);  -- remainder lo (R)
  signal reg_482D : std_logic_vector(7 downto 0);  -- remainder hi (R)
  signal reg_482E : std_logic_vector(7 downto 0);  -- sign mode R/W: bit[0] = 0=unsigned 1=signed
  signal reg_482F : std_logic_vector(7 downto 0);  -- busy flag    (R)

  -- Bank mapping registers
  signal reg_4830 : std_logic_vector(7 downto 0);  -- [0]=SRAM enable, [1]=PROM bank
  signal reg_4831 : std_logic_vector(7 downto 0);  -- DROM bank for $D0-$DF
  signal reg_4832 : std_logic_vector(7 downto 0);  -- DROM bank for $E0-$EF
  signal reg_4833 : std_logic_vector(7 downto 0);  -- DROM bank for $F0-$FF
  signal reg_4834 : std_logic_vector(7 downto 0);  -- DROM size [7:0]
  signal reg_4835 : std_logic_vector(7 downto 0);  -- DROM size [15:8]
  signal reg_4836 : std_logic_vector(7 downto 0);  -- DROM size [23:16]

  -- RTC registers
  signal reg_4840 : std_logic_vector(7 downto 0);  -- RTC control
  signal reg_4841 : std_logic_vector(7 downto 0);  -- RTC data
  signal reg_4842 : std_logic_vector(7 downto 0);  -- RTC index

  -- -------------------------------------------------------------------------
  -- Decompressed output buffer: 64 bytes, rolling
  -- -------------------------------------------------------------------------
  type t_dec_buf is array(0 to 63) of std_logic_vector(7 downto 0);
  signal dec_buf      : t_dec_buf;
  signal dec_wr_ptr   : unsigned(5 downto 0) := (others => '0');
  signal dec_rd_ptr   : unsigned(5 downto 0) := (others => '0');
  signal dec_buf_cnt  : unsigned(6 downto 0) := (others => '0');

  -- -------------------------------------------------------------------------
  -- Data ROM direct access state machine
  -- -------------------------------------------------------------------------
  type t_drom_state is (DS_IDLE, DS_REQ, DS_WAIT, DS_DONE);
  signal drom_state   : t_drom_state;

  -- -------------------------------------------------------------------------
  -- Decompressor state machine (feeds from PSRAM to SPC7110_DEC)
  -- -------------------------------------------------------------------------
  type t_comp_state is (CS_IDLE, CS_INIT, CS_FETCH, CS_WAIT, CS_FILL, CS_RUNNING);
  signal comp_state   : t_comp_state;
  signal comp_ptr     : unsigned(23 downto 0);

  -- SPC7110_DEC wires
  signal dec_mode     : std_logic_vector(1 downto 0);
  signal dec_start    : std_logic;
  signal dec_fifo_empty : std_logic;
  signal dec_fifo_data  : std_logic_vector(7 downto 0);
  signal dec_fifo_rd    : std_logic;
  signal dec_out_valid  : std_logic;
  signal dec_out_byte   : std_logic_vector(7 downto 0);
  signal dec_out_ack    : std_logic;
  signal dec_idle       : std_logic;

  -- FIFO control
  signal fifo_rst     : std_logic;
  signal fifo_wr_en   : std_logic;
  signal fifo_wr_data : std_logic_vector(7 downto 0);
  signal fifo_full    : std_logic;
  signal fifo_count   : unsigned(4 downto 0);

  -- -------------------------------------------------------------------------
  -- Mul/Div wires
  -- -------------------------------------------------------------------------
  signal muldiv_result_lo    : std_logic_vector(15 downto 0);
  signal muldiv_result_hi    : std_logic_vector(15 downto 0);
  signal muldiv_remainder    : std_logic_vector(15 downto 0);
  signal muldiv_is_div       : std_logic := '0';  -- 0=multiply, 1=divide
  signal muldiv_busy         : std_logic;
  signal muldiv_start        : std_logic;
  -- intermediate signals to avoid expression-as-port-actual (XST LRM 2.1.1)
  signal muldiv_multiplicand : std_logic_vector(15 downto 0);
  signal muldiv_multiplier   : std_logic_vector(15 downto 0);
  signal muldiv_dividend_hi  : std_logic_vector(15 downto 0);
  signal muldiv_dividend_lo  : std_logic_vector(15 downto 0);
  signal muldiv_divisor      : std_logic_vector(15 downto 0);

  -- -------------------------------------------------------------------------
  -- Internal decoding helpers
  -- -------------------------------------------------------------------------
  signal is_reg_write : std_logic;
  signal is_reg_read  : std_logic;
  signal reg_addr     : std_logic_vector(7 downto 0);  -- $4800-$484F → low byte

  -- Address is a register access if bank is $00/$80 and addr = $4800-$484F
  signal addr_is_reg  : std_logic;

  -- Decomp buffer read address (when SNES reads $50:xxxx)
  signal addr_is_decomp : std_logic;

  -- Bus output mux
  signal data_out_r   : std_logic_vector(7 downto 0);
  signal data_oe_r    : std_logic;

  -- RTC state
  signal rtc_index_r  : std_logic_vector(3 downto 0);
  signal rtc_mode     : std_logic;  -- 0=command, 1=data transfer

begin

  -- -------------------------------------------------------------------------
  -- Sub-module instantiations
  -- -------------------------------------------------------------------------

  dec_inst : entity work.SPC7110_DEC
    port map (
      clk          => clk,
      rst          => rst,
      mode         => dec_mode,
      start        => dec_start,
      fifo_empty   => dec_fifo_empty,
      fifo_data    => dec_fifo_data,
      fifo_rd      => dec_fifo_rd,
      dec_valid    => dec_out_valid,
      dec_byte     => dec_out_byte,
      dec_ack      => dec_out_ack,
      idle         => dec_idle
    );

  fifo_inst : entity work.SPC7110_FIFO
    port map (
      clk      => clk,
      rst      => fifo_rst,
      wr_en    => fifo_wr_en,
      wr_data  => fifo_wr_data,
      full     => fifo_full,
      rd_en    => dec_fifo_rd,
      rd_data  => dec_fifo_data,
      empty    => dec_fifo_empty,
      count    => fifo_count
    );

  muldiv_multiplicand <= reg_4821 & reg_4820;
  muldiv_multiplier   <= reg_4825 & reg_4824;
  muldiv_dividend_hi  <= reg_4823 & reg_4822;
  muldiv_dividend_lo  <= reg_4821 & reg_4820;
  muldiv_divisor      <= reg_4827 & reg_4826;

  muldiv_inst : entity work.SPC7110_MULDIV
    port map (
      clk          => clk,
      rst          => rst,
      multiplicand => muldiv_multiplicand,
      multiplier   => muldiv_multiplier,
      dividend_hi  => muldiv_dividend_hi,
      dividend_lo  => muldiv_dividend_lo,
      divisor      => muldiv_divisor,
      mode_sign    => reg_482E(0),
      mode_div     => muldiv_is_div,
      start        => muldiv_start,
      result_lo    => muldiv_result_lo,
      result_hi    => muldiv_result_hi,
      remainder    => muldiv_remainder,
      sign_flag    => open,
      busy         => muldiv_busy
    );

  -- -------------------------------------------------------------------------
  -- Address decode
  -- -------------------------------------------------------------------------
  -- Covers $4800-$487F (bank $00/$80); $4840-$484F (RTC) included. $4850+ are unused.
  addr_is_reg    <= '1' when SNES_ADDR(22) = '0' and
                             SNES_ADDR(15 downto 8) = x"48" and
                             SNES_ADDR(7) = '0'
                        else '0';
  -- Also catch $4840-$4842 (RTC)
  -- Full decode: 00/80: 4800-484F
  -- reg_addr is $4800-$484F → SNES_ADDR[6:0] indexes into the range
  reg_addr    <= SNES_ADDR(7 downto 0);  -- low byte (= $00-$4F range)

  addr_is_decomp <= '1' when SNES_ADDR(23 downto 16) = x"50" else '0';

  is_reg_write <= '1' when addr_is_reg = '1' and SNES_WR_end = '1' else '0';
  is_reg_read  <= '1' when addr_is_reg = '1' and SNES_RD_start = '1' else '0';

  dec_mode <= reg_4818(1 downto 0);

  -- -------------------------------------------------------------------------
  -- Muldiv result register aliases
  -- -------------------------------------------------------------------------
  fifo_rst  <= rst or dec_start;
  reg_4828 <= muldiv_result_lo(7 downto 0);
  reg_4829 <= muldiv_result_lo(15 downto 8);
  reg_482A <= muldiv_result_hi(7 downto 0);
  reg_482B <= muldiv_result_hi(15 downto 8);
  reg_482C <= muldiv_remainder(7 downto 0);
  reg_482D <= muldiv_remainder(15 downto 8);
  reg_482F <= (7 => muldiv_busy, others => '0');

  -- -------------------------------------------------------------------------
  -- Data bus output mux
  -- -------------------------------------------------------------------------
  SNES_DATA_OUT <= data_out_r;
  SNES_DATA_OE  <= data_oe_r;

  -- -------------------------------------------------------------------------
  -- RTC forwarding
  -- -------------------------------------------------------------------------
  RTC_INDEX    <= rtc_index_r;
  RTC_DATA_OUT <= reg_4841(3 downto 0);
  RTC_WR       <= '1' when is_reg_write = '1' and reg_addr = x"41" and RTC_EN = '1' else '0';
  RTC_RD       <= '1' when is_reg_read  = '1' and reg_addr = x"41" and RTC_EN = '1' else '0';

  -- -------------------------------------------------------------------------
  -- DROM bank outputs for main.v PSRAM address mux
  -- -------------------------------------------------------------------------
  DROM_BANK_D <= reg_4831(2 downto 0);
  DROM_BANK_E <= reg_4832(2 downto 0);
  DROM_BANK_F <= reg_4833(2 downto 0);

  -- -------------------------------------------------------------------------
  -- Main sequential logic
  -- -------------------------------------------------------------------------
  process(clk)
    variable new_drom_ptr : unsigned(23 downto 0);
  begin
    if rising_edge(clk) then
      -- defaults
      muldiv_start <= '0';
      dec_start    <= '0';
      dec_out_ack  <= '0';
      fifo_wr_en   <= '0';
      ROM_REQ      <= '0';
      data_oe_r    <= '0';

      if rst = '1' then
        reg_4830 <= (others => '0');
        reg_4831 <= (others => '0');
        reg_4832 <= x"01";
        reg_4833 <= x"02";
        reg_4834 <= (others => '0');
        reg_4835 <= (others => '0');
        reg_4836 <= (others => '0');
        reg_4818 <= (others => '0');
        reg_482E      <= (others => '0');
        reg_482F      <= (others => '0');
        muldiv_is_div <= '0';
        drom_state  <= DS_IDLE;
        comp_state  <= CS_IDLE;
        dec_wr_ptr  <= (others => '0');
        dec_rd_ptr  <= (others => '0');
        dec_buf_cnt <= (others => '0');
        rtc_index_r <= (others => '0');
        rtc_mode    <= '0';
      else

        -- ------------------------------------------------------------------
        -- Register writes
        -- ------------------------------------------------------------------
        if is_reg_write = '1' then
          case reg_addr is
            -- Data ROM pointer
            when x"01" => reg_4801 <= SNES_DATA_IN;
            when x"02" => reg_4802 <= SNES_DATA_IN;
            when x"03" => reg_4803 <= SNES_DATA_IN;
            when x"04" => reg_4804 <= SNES_DATA_IN;
            when x"05" => reg_4805 <= SNES_DATA_IN;
            when x"06" => reg_4806 <= SNES_DATA_IN;
            when x"07" => reg_4807 <= SNES_DATA_IN;
            when x"0B" => reg_480B <= SNES_DATA_IN;
            -- Decompressor address
            when x"11" => reg_4811 <= SNES_DATA_IN;
            when x"12" => reg_4812 <= SNES_DATA_IN;
            when x"13" => reg_4813 <= SNES_DATA_IN;
                          -- Write to $4813 triggers decompressor start
                          comp_ptr  <= unsigned(reg_4813) & unsigned(reg_4812) & unsigned(reg_4811);
                          dec_start <= '1';
                          dec_wr_ptr  <= (others => '0');
                          dec_rd_ptr  <= (others => '0');
                          dec_buf_cnt <= (others => '0');
            when x"14" => reg_4814 <= SNES_DATA_IN;
            when x"15" => reg_4815 <= SNES_DATA_IN;
            when x"16" => reg_4816 <= SNES_DATA_IN;
            when x"17" => reg_4817 <= SNES_DATA_IN;
            when x"18" => reg_4818 <= SNES_DATA_IN;
            when x"1A" => reg_481A <= SNES_DATA_IN;
            -- Mul/div
            when x"20" => reg_4820 <= SNES_DATA_IN;
            when x"21" => reg_4821 <= SNES_DATA_IN;
            when x"22" => reg_4822 <= SNES_DATA_IN;
            when x"23" => reg_4823 <= SNES_DATA_IN;
            when x"24" => reg_4824 <= SNES_DATA_IN;
            when x"25" => reg_4825 <= SNES_DATA_IN;
                          muldiv_start  <= '1';
                          muldiv_is_div <= '0';   -- trigger: multiply
            when x"26" => reg_4826 <= SNES_DATA_IN;
            when x"27" => reg_4827 <= SNES_DATA_IN;
                          muldiv_start  <= '1';
                          muldiv_is_div <= '1';   -- trigger: divide
            when x"2E" => reg_482E(0) <= SNES_DATA_IN(0);  -- sign mode
            -- Bank mapping
            when x"30" => reg_4830 <= SNES_DATA_IN;
            when x"31" => reg_4831 <= SNES_DATA_IN;
            when x"32" => reg_4832 <= SNES_DATA_IN;
            when x"33" => reg_4833 <= SNES_DATA_IN;
            when x"34" => reg_4834 <= SNES_DATA_IN;
            when x"35" => reg_4835 <= SNES_DATA_IN;
            when x"36" => reg_4836 <= SNES_DATA_IN;
            -- RTC
            when x"40" => reg_4840 <= SNES_DATA_IN;
                          rtc_mode <= SNES_DATA_IN(0);
            when x"41" => reg_4841 <= SNES_DATA_IN;
                          if RTC_EN = '1' then
                            RTC_WR <= '1';
                          end if;
            when x"42" => reg_4842 <= SNES_DATA_IN;
                          rtc_index_r <= SNES_DATA_IN(3 downto 0);
            when others => null;
          end case;
        end if;

        -- ------------------------------------------------------------------
        -- Register reads → output mux
        -- ------------------------------------------------------------------
        if is_reg_read = '1' or addr_is_decomp = '1' then
          data_oe_r <= '1';
          if addr_is_decomp = '1' then
            -- Read decompressed data from rolling buffer
            if dec_buf_cnt > 0 then
              data_out_r  <= dec_buf(to_integer(dec_rd_ptr));
              dec_rd_ptr  <= dec_rd_ptr + 1;
              dec_buf_cnt <= dec_buf_cnt - 1;
            else
              data_out_r <= x"00";
            end if;
          else
            case reg_addr is
              when x"00" => data_out_r <= reg_4800;        -- DROM read port
              when x"09" => data_out_r <= reg_4809;
              when x"0A" => data_out_r <= reg_480A;
              when x"10" => data_out_r <= reg_4810;        -- decomp port (legacy)
              when x"28" => data_out_r <= reg_4828;
              when x"29" => data_out_r <= reg_4829;
              when x"2A" => data_out_r <= reg_482A;
              when x"2B" => data_out_r <= reg_482B;
              when x"2C" => data_out_r <= reg_482C;
              when x"2D" => data_out_r <= reg_482D;
              when x"2E" => data_out_r <= reg_482E;
              when x"2F" => data_out_r <= reg_482F;
              when x"41" =>
                if RTC_EN = '1' then data_out_r <= "0000" & RTC_DATA_IN;
                else data_out_r <= x"FF"; end if;
              when others => data_out_r <= x"FF";
            end case;
          end if;
        end if;

        -- ------------------------------------------------------------------
        -- Data ROM read port $4800: auto-advance pointer on each read
        -- ------------------------------------------------------------------
        if is_reg_read = '1' and reg_addr = x"00" then
          -- Trigger a new DROM fetch for next time
          drom_state <= DS_REQ;
        end if;

        -- ------------------------------------------------------------------
        -- Data ROM state machine (feeds reg_4800)
        -- ------------------------------------------------------------------
        case drom_state is
          when DS_IDLE => null;
          when DS_REQ =>
            ROM_REQ <= '1';
            ROM_ADDR_OUT <= std_logic_vector(
              unsigned(std_logic_vector'(reg_4803 & reg_4802 & reg_4801)) + x"100000");
            drom_state <= DS_WAIT;
          when DS_WAIT =>
            if ROM_ACK = '1' then
              reg_4800 <= ROM_DATA_IN;
              -- Advance pointer
              new_drom_ptr := unsigned(std_logic_vector'(reg_4803 & reg_4802 & reg_4801)) + 1;
              reg_4801 <= std_logic_vector(new_drom_ptr(7 downto 0));
              reg_4802 <= std_logic_vector(new_drom_ptr(15 downto 8));
              reg_4803 <= std_logic_vector(new_drom_ptr(23 downto 16));
              drom_state <= DS_DONE;
            end if;
          when DS_DONE =>
            drom_state <= DS_IDLE;
        end case;

        -- ------------------------------------------------------------------
        -- Decompressor feeder state machine (fills FIFO from PSRAM DROM)
        -- ------------------------------------------------------------------
        case comp_state is
          when CS_IDLE => null;
          when CS_INIT =>
            comp_ptr   <= unsigned(std_logic_vector'(reg_4813 & reg_4812 & reg_4811));
            comp_state <= CS_FETCH;
          when CS_FETCH =>
            if fifo_full = '0' then
              ROM_REQ <= '1';
              ROM_ADDR_OUT <= std_logic_vector(comp_ptr + x"100000");
              comp_state   <= CS_WAIT;
            end if;
          when CS_WAIT =>
            if ROM_ACK = '1' then
              fifo_wr_en   <= '1';
              fifo_wr_data <= ROM_DATA_IN;
              comp_ptr     <= comp_ptr + 1;
              comp_state   <= CS_RUNNING;
            end if;
          when CS_RUNNING =>
            comp_state <= CS_FETCH;  -- continually refill
          when others => null;
        end case;

        -- Trigger compressor feeder on start
        if dec_start = '1' then
          comp_state <= CS_INIT;
        end if;

        -- ------------------------------------------------------------------
        -- Decompressed output → rolling buffer
        -- ------------------------------------------------------------------
        if dec_out_valid = '1' and dec_buf_cnt < 64 then
          dec_buf(to_integer(dec_wr_ptr)) <= dec_out_byte;
          dec_wr_ptr  <= dec_wr_ptr + 1;
          dec_buf_cnt <= dec_buf_cnt + 1;
          dec_out_ack <= '1';
        end if;

      end if;
    end if;
  end process;

end architecture rtl;
