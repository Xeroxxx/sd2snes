----------------------------------------------------------------------------------
-- SPC7110.vhd
-- SPC7110 Chip Emulation Core — faithful port of MiSTer SNES (srg320).
--
-- Register map (corrected):
--   $4800      Decompressor byte output (advances read pointer on read)
--   $4801-$480B Decompressor control (POINTER, INDEX, OFFSET, COUNTER, MODE)
--   $480C      Decompressor status (bit7 = DEC_DONE)
--   $4810      Direct data ROM output port (advances pointer on read)
--   $4811-$481A Direct data ROM control (POINTER, ADJUST, INCREMENT, MODE)
--   $4820-$482F Multiply/divide
--   $4830-$4836 Bank mapping; $4830[7]=SRAM_EN
--   $4840-$4842 RTC-4513 interface
--
-- PSRAM address mapping: $4831=0 → first DROM block → PSRAM segment 1 (0x100000).
--   SNES bank $Dx → PSRAM {($4831+1), addr[19:0]}, same for $Ex/$Fx.
-- Defaults: BANKD=0, BANKE=1, BANKF=2 (boots with each window on successive segments).
-- Decompressor: LOAD_RUN reads 4 bytes from DROM table to get DEC_MODE+DEC_ADDR.
--   DEC_START fires on $4806 write; decompressor runs continuously into DEC_BUF.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library work;
use work.SPC7110_DEC_PKG.all;

entity SPC7110 is
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;

    SNES_ADDR     : in  std_logic_vector(23 downto 0);
    SNES_WR       : in  std_logic;
    SNES_RD       : in  std_logic;
    SNES_WR_end   : in  std_logic;
    SNES_RD_start : in  std_logic;
    SNES_RD_end   : in  std_logic;  -- rising edge of SNES /RD (end of read cycle)
    SNES_DATA_IN  : in  std_logic_vector(7 downto 0);
    SNES_DATA_OUT : out std_logic_vector(7 downto 0);
    SNES_DATA_OE  : out std_logic;

    ROM_REQ       : out std_logic;
    ROM_ADDR_OUT  : out std_logic_vector(23 downto 0);
    ROM_DATA_IN   : in  std_logic_vector(7 downto 0);
    ROM_ACK       : in  std_logic;

    -- RTC register-file interface ($4840/$4841/$4842)
    RTC_CE_WR     : out std_logic;  -- strobe: $4840 was written
    RTC_CE_BIT    : out std_logic;  -- bit 0 of $4840 write value
    RTC_SER_WR    : out std_logic;  -- strobe: $4841 was written
    RTC_SER_DATA  : out std_logic_vector(7 downto 0);  -- full byte written to $4841
    RTC_SER_RD    : out std_logic;  -- strobe: $4841 read start (SNES /RD falling — sets busy)
    RTC_SER_RD_END : out std_logic;  -- strobe: $4841 read end   (SNES /RD rising  — auto-increment)
    RTC_SER_IN    : in  std_logic_vector(7 downto 0);  -- register value on $4841 read
    RTC_STATUS    : in  std_logic_vector(7 downto 0);  -- byte for $4842 read
    RTC_EN        : in  std_logic;

    DROM_BANK_D   : out std_logic_vector(2 downto 0);
    DROM_BANK_E   : out std_logic_vector(2 downto 0);
    DROM_BANK_F   : out std_logic_vector(2 downto 0)
  );
end entity SPC7110;

architecture rtl of SPC7110 is

  -- -------------------------------------------------------------------------
  -- Decompressor control registers ($4801-$480B)
  -- -------------------------------------------------------------------------
  signal DEC_POINTER  : std_logic_vector(23 downto 0);  -- $4801-$4803
  signal DEC_INDEX    : std_logic_vector(7 downto 0);   -- $4804
  signal DEC_OFFSET   : std_logic_vector(15 downto 0);  -- $4805-$4806
  signal DEC_COUNTER  : std_logic_vector(15 downto 0);  -- $4809-$480A
  signal DEC_MODE_REG : std_logic_vector(1 downto 0);   -- $480B read-back

  -- -------------------------------------------------------------------------
  -- Direct data ROM control registers ($4811-$481A)
  -- -------------------------------------------------------------------------
  signal DAT_POINTER  : std_logic_vector(23 downto 0);  -- $4811-$4813
  signal DAT_ADJUST   : std_logic_vector(15 downto 0);  -- $4814-$4815
  signal DAT_INCR     : std_logic_vector(15 downto 0);  -- $4816-$4817
  signal DAT_MODE     : std_logic_vector(6 downto 0);   -- $4818

  -- -------------------------------------------------------------------------
  -- Bank mapping registers ($4830-$4836)
  -- -------------------------------------------------------------------------
  signal BANKD        : std_logic_vector(3 downto 0);   -- $4831
  signal BANKE        : std_logic_vector(3 downto 0);   -- $4832
  signal BANKF        : std_logic_vector(3 downto 0);   -- $4833
  signal SRAM_EN      : std_logic;                      -- $4830[7]

  -- -------------------------------------------------------------------------
  -- Mul/div registers ($4820-$482F)
  -- -------------------------------------------------------------------------
  signal MULTIPLICAND : std_logic_vector(15 downto 0);
  signal MULTIPLIER   : std_logic_vector(15 downto 0);
  signal DIVIDEND     : std_logic_vector(31 downto 0);
  signal DIVISOR      : std_logic_vector(15 downto 0);
  signal SIGN         : std_logic;
  signal MUL_RUN      : std_logic;
  signal DIV_RUN      : std_logic;
  signal ALU_CNT      : unsigned(5 downto 0);
  signal MULDIV_RES   : std_logic_vector(31 downto 0);
  signal REM_RES      : std_logic_vector(15 downto 0);

  -- MUL/DIV combinational results from SPC7110_MULDIV
  signal muldiv_result_lo  : std_logic_vector(15 downto 0);
  signal muldiv_result_hi  : std_logic_vector(15 downto 0);
  signal muldiv_remainder  : std_logic_vector(15 downto 0);
  signal muldiv_busy       : std_logic;
  signal muldiv_start      : std_logic;
  signal muldiv_is_div     : std_logic;
  -- XST LRM 2.1.1: no expressions as port actuals
  signal muldiv_multiplicand : std_logic_vector(15 downto 0);
  signal muldiv_multiplier   : std_logic_vector(15 downto 0);
  signal muldiv_dividend_hi  : std_logic_vector(15 downto 0);
  signal muldiv_dividend_lo  : std_logic_vector(15 downto 0);
  signal muldiv_divisor      : std_logic_vector(15 downto 0);

  -- RTC ($4840-$4842): all protocol state lives in rtc4513_emu.v;
  -- SPC7110.vhd only routes the raw write/read strobes and data bits.

  -- -------------------------------------------------------------------------
  -- Work state machine: arbitrates PSRAM access (LOAD_ADDR / LOAD_FIFO / DP_READ)
  -- -------------------------------------------------------------------------
  type WorkStates_t is (WS_IDLE,
                        WS_LOAD_ADDR1, WS_LOAD_ADDR2, WS_LOAD_ADDR3,
                        WS_LOAD_FIFO1, WS_LOAD_FIFO2, WS_LOAD_FIFO3,
                        WS_DP_READ1,   WS_DP_READ2);
  signal WS             : WorkStates_t;
  signal LOAD_RUN       : std_logic;     -- $4804 write triggers 4-byte table read
  signal DP_READ        : std_logic;     -- trigger data ROM read into DP_DATA_OUT
  signal LOAD_ADDR_POS  : unsigned(1 downto 0);
  signal DEC_ADDR       : std_logic_vector(23 downto 0);  -- loaded from DROM table
  signal DEC_MODE       : std_logic_vector(1 downto 0);   -- loaded from DROM table byte 0
  signal FIFO_D         : std_logic_vector(7 downto 0);
  signal FIFO_WR        : std_logic;
  signal FIFO_Q         : std_logic_vector(7 downto 0);
  signal FIFO_FULL      : std_logic;
  signal DP_DATA_OUT    : std_logic_vector(7 downto 0);

  -- -------------------------------------------------------------------------
  -- Decompression state machine
  -- -------------------------------------------------------------------------
  type DecStates_t is (DS_IDLE, DS_PRELOAD, DS_INIT, DS_DECODING);
  signal DS             : DecStates_t;
  signal DEC_START      : std_logic;    -- $4806 write triggers
  signal DEC_RUN        : std_logic;
  signal DEC_RUN_OLD    : std_logic;
  signal DEC_INIT_PULSE : std_logic;    -- one-cycle pulse to SPC7110_DEC INIT
  signal DEC_DONE       : std_logic;

  -- 64-byte decompressor output buffer
  type DecBuf_t is array(0 to 63) of std_logic_vector(7 downto 0);
  signal DEC_BUF        : DecBuf_t;
  signal DEC_BUF_WR_ADDR : unsigned(5 downto 0);
  signal DEC_BUF_RD_ADDR : unsigned(5 downto 0);
  signal DEC_BUF_OUT    : std_logic_vector(7 downto 0);

  -- SPC7110_DEC output wires
  signal DEC_DAT_OUT    : std_logic_vector(31 downto 0);
  signal DEC_OUT_WR     : std_logic;
  signal DEC_IN_RD      : std_logic;

  signal fifo_rst       : std_logic;

  -- DEC_BUF write serializer (one write/cycle enables XST LUT-RAM inference)
  signal DEC_DAT_LATCH  : std_logic_vector(31 downto 0);
  signal DEC_WR_BUSY    : std_logic;
  signal DEC_WR_PHASE   : unsigned(1 downto 0);
  signal DEC_WR_BASE    : unsigned(5 downto 0);
  signal DEC_WR_MODE    : std_logic_vector(1 downto 0);
  -- Captured at DEC_OUT_WR time (pre-OFFSET-decrement), mirroring MiSTer's
  -- same-cycle stop check.  Used by DEC_WR_BUSY phases 1-3 so they don't
  -- see the already-decremented OFFSET value.
  signal DEC_WR_CAN_STOP : std_logic;

  -- -------------------------------------------------------------------------
  -- Address decode
  -- -------------------------------------------------------------------------
  signal addr_is_reg    : std_logic;
  signal addr_is_decomp : std_logic;
  signal is_reg_write   : std_logic;
  signal is_reg_read    : std_logic;
  signal reg_addr       : std_logic_vector(7 downto 0);

  -- Output bus
  signal data_out_r     : std_logic_vector(7 downto 0);
  signal data_oe_r      : std_logic;

  -- -------------------------------------------------------------------------
  -- DROM address (24-bit SNES bank) to PSRAM address (24-bit physical)
  -- Used ONLY for SNES-bus direct DROM access via banks $D0/$E0/$F0.
  -- $4831=0 → first DROM block → PSRAM segment 1; formula: {(bk+1), addr[19:0]}
  -- Mirrors main.v's snes_drom_psram = {0, (drom_bank_sel + 3'd1), addr[19:0]}
  -- -------------------------------------------------------------------------
  function drom_psram(addr : std_logic_vector(23 downto 0);
                      bd : std_logic_vector(3 downto 0);
                      be : std_logic_vector(3 downto 0);
                      bf : std_logic_vector(3 downto 0))
                      return std_logic_vector is
    variable bk  : std_logic_vector(3 downto 0);
    variable seg : std_logic_vector(3 downto 0);
    variable res : std_logic_vector(23 downto 0);
  begin
    case addr(23 downto 20) is
      when x"D"   => bk := bd;
      when x"E"   => bk := be;
      when x"F"   => bk := bf;
      when others => bk := bd;
    end case;
    -- +1: PSRAM segment 0 is PROM; DROM block 0 ($4831=0) lives in segment 1
    seg := std_logic_vector(unsigned(bk) + 1);
    res := seg & addr(19 downto 0);
    return res;
  end function;

  -- -------------------------------------------------------------------------
  -- Linear DROM address (24-bit offset) to PSRAM address (24-bit physical)
  -- Used for the data port ($4810) and decompressor (DEC_ADDR / DEC_POINTER).
  -- These use a flat 24-bit linear offset into the Data ROM, independent of
  -- the SNES bank registers ($4831-$4833).  The Data ROM begins at PSRAM
  -- segment 1 (physical 0x100000), so:
  --   PSRAM_addr = 0x100000 + linear_drom_offset
  -- This correctly reaches all 4 MB of DROM (offsets 0x000000-0x3FFFFF →
  -- PSRAM 0x100000-0x4FFFFF), unlike drom_psram() which only covers segment 1.
  -- -------------------------------------------------------------------------
  function drom_psram_linear(addr : std_logic_vector(23 downto 0))
                             return std_logic_vector is
  begin
    return std_logic_vector(unsigned(addr) + x"100000");
  end function;

begin

  -- -------------------------------------------------------------------------
  -- Sub-module instantiations
  -- -------------------------------------------------------------------------

  dec_inst : entity work.SPC7110_DEC
    port map (
      rst     => rst,
      clk     => clk,
      DI      => FIFO_Q,
      RD      => DEC_IN_RD,
      INIT    => DEC_INIT_PULSE,
      RUN     => DEC_RUN,
      MODE    => DEC_MODE,
      DAT_OUT => DEC_DAT_OUT,
      WR      => DEC_OUT_WR
    );

  fifo_inst : entity work.SPC7110_FIFO
    port map (
      clk     => clk,
      rst     => fifo_rst,
      wr_en   => FIFO_WR,
      wr_data => FIFO_D,
      full    => FIFO_FULL,
      rd_en   => DEC_IN_RD,
      rd_data => FIFO_Q,
      empty   => open,
      count   => open
    );

  fifo_rst <= rst or DEC_START;

  muldiv_multiplicand <= MULTIPLICAND;
  muldiv_multiplier   <= MULTIPLIER;
  muldiv_dividend_hi  <= DIVIDEND(31 downto 16);
  muldiv_dividend_lo  <= DIVIDEND(15 downto 0);
  muldiv_divisor      <= DIVISOR;

  muldiv_inst : entity work.SPC7110_MULDIV
    port map (
      clk          => clk,
      rst          => rst,
      multiplicand => muldiv_multiplicand,
      multiplier   => muldiv_multiplier,
      dividend_hi  => muldiv_dividend_hi,
      dividend_lo  => muldiv_dividend_lo,
      divisor      => muldiv_divisor,
      mode_sign    => SIGN,
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
  addr_is_reg    <= '1' when SNES_ADDR(22) = '0' and
                             SNES_ADDR(15 downto 8) = x"48" and
                             SNES_ADDR(7) = '0' else '0';
  addr_is_decomp <= '1' when SNES_ADDR(23 downto 16) = x"50" else '0';
  reg_addr       <= SNES_ADDR(7 downto 0);
  is_reg_write   <= '1' when addr_is_reg = '1' and SNES_WR_end   = '1' else '0';
  is_reg_read    <= '1' when addr_is_reg = '1' and SNES_RD_start = '1' else '0';

  -- -------------------------------------------------------------------------
  -- Combinational outputs
  -- -------------------------------------------------------------------------
  SNES_DATA_OUT <= data_out_r;
  SNES_DATA_OE  <= data_oe_r;

  DEC_BUF_OUT   <= DEC_BUF(to_integer(DEC_BUF_RD_ADDR));

  DROM_BANK_D <= BANKD(2 downto 0);
  DROM_BANK_E <= BANKE(2 downto 0);
  DROM_BANK_F <= BANKF(2 downto 0);

  -- RTC register-file strobes (all gated by RTC_EN)
  RTC_CE_WR     <= '1' when is_reg_write = '1' and reg_addr = x"40" and RTC_EN = '1' else '0';
  RTC_CE_BIT    <= SNES_DATA_IN(0);
  RTC_SER_WR    <= '1' when is_reg_write = '1' and reg_addr = x"41" and RTC_EN = '1' else '0';
  RTC_SER_DATA  <= SNES_DATA_IN;  -- full byte to $4841
  RTC_SER_RD    <= '1' when is_reg_read  = '1' and reg_addr = x"41" and RTC_EN = '1' else '0';
  -- End-of-read strobe: fires on SNES /RD rising edge; used only for rtc_index auto-increment.
  RTC_SER_RD_END <= '1' when addr_is_reg = '1' and SNES_RD_end = '1' and reg_addr = x"41" and RTC_EN = '1' else '0';

  -- -------------------------------------------------------------------------
  -- Main sequential process
  -- -------------------------------------------------------------------------
  process(clk)
    variable INC_V      : std_logic_vector(23 downto 0);
    variable ADDR_V     : std_logic_vector(23 downto 0);
    variable PTR_V      : std_logic_vector(23 downto 0);
    variable v_buf_we   : std_logic;
    variable v_buf_addr : unsigned(5 downto 0);
    variable v_buf_dat  : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      v_buf_we   := '0';
      v_buf_addr := (others => '0');
      v_buf_dat  := (others => '0');
      -- pulse defaults
      muldiv_start  <= '0';
      DEC_START     <= '0';
      -- NOTE: DP_READ and LOAD_RUN are NOT reset here; they are sticky flags cleared
      -- only when WS_IDLE services them (WS_IDLE -> WS_DP_READ1 / WS_LOAD_ADDR1).
      -- This prevents either flag from being silently dropped if the WS machine is
      -- momentarily busy on the same clock.  Without sticky LOAD_RUN, a $4804 write
      -- during active FIFO loading loses the flag, causing the decompressor to re-use
      -- the previous DEC_ADDR/DEC_MODE and decode garbage tiles (-> black screen).
      -- MiSTer uses the same sticky pattern for both flags.
      FIFO_WR       <= '0';
      ROM_REQ       <= '0';
      -- data_oe_r: NOT in pulse defaults; it is now a level signal driven by
      -- the SNES_RD port at the bottom of this process (see end of else block).
      DEC_INIT_PULSE<= '0';

      if rst = '1' then
        DEC_POINTER   <= (others => '0');
        DEC_INDEX     <= (others => '0');
        DEC_OFFSET    <= (others => '0');
        DEC_COUNTER   <= (others => '0');
        DEC_MODE_REG  <= (others => '0');
        DAT_POINTER   <= (others => '0');
        DAT_ADJUST    <= (others => '0');
        DAT_INCR      <= (others => '0');
        DAT_MODE      <= (others => '0');
        BANKD         <= x"0";  -- default: $4831=0 → first DROM block
        BANKE         <= x"1";
        BANKF         <= x"2";
        SRAM_EN       <= '0';
        MULTIPLICAND  <= (others => '0');
        MULTIPLIER    <= (others => '0');
        DIVIDEND      <= (others => '0');
        DIVISOR       <= (others => '0');
        SIGN          <= '0';
        MULDIV_RES    <= (others => '0');
        REM_RES       <= (others => '0');
        MUL_RUN       <= '0';
        DIV_RUN       <= '0';
        ALU_CNT       <= (others => '0');
        muldiv_is_div <= '0';
        -- RTC protocol state lives entirely in rtc4513_emu.v; nothing to reset here.
        DEC_RUN       <= '0';
        DEC_RUN_OLD   <= '0';
        DEC_DONE      <= '0';  -- chip starts idle: $480C bit7 = 0 at power-on (real SPC7110 behaviour)
        DEC_BUF_WR_ADDR <= (others => '0');
        DEC_BUF_RD_ADDR <= (others => '0');
        DP_DATA_OUT   <= (others => '0');
        data_out_r    <= (others => '0');
        LOAD_ADDR_POS <= (others => '0');
        DEC_ADDR      <= (others => '0');
        DEC_MODE      <= (others => '0');
        DEC_WR_BUSY     <= '0';
        DEC_WR_PHASE    <= (others => '0');
        DEC_WR_BASE     <= (others => '0');
        DEC_WR_MODE     <= (others => '0');
        DEC_WR_CAN_STOP <= '0';
        DP_READ         <= '0';
        LOAD_RUN        <= '0';
        WS            <= WS_IDLE;
        DS            <= DS_IDLE;
      else

        -- ------------------------------------------------------------------
        -- Register writes
        -- ------------------------------------------------------------------
        if is_reg_write = '1' then
          case reg_addr is
            -- Decompressor control ($4801-$480B)
            when x"01" => DEC_POINTER(7  downto  0) <= SNES_DATA_IN;
            when x"02" => DEC_POINTER(15 downto  8) <= SNES_DATA_IN;
            when x"03" => DEC_POINTER(23 downto 16) <= SNES_DATA_IN;
            when x"04" => DEC_INDEX <= SNES_DATA_IN;
                          LOAD_RUN  <= '1';
            when x"05" => DEC_OFFSET(7  downto 0) <= SNES_DATA_IN;
            when x"06" => DEC_OFFSET(15 downto 8) <= SNES_DATA_IN;
                          DEC_BUF_RD_ADDR <= (others => '0');
                          DEC_BUF_WR_ADDR <= (others => '0');
                          DEC_START       <= '1';
                          DEC_DONE        <= '0';
            when x"09" => DEC_COUNTER(7  downto 0) <= SNES_DATA_IN;
                          DEC_DONE <= '0';
            when x"0A" => DEC_COUNTER(15 downto 8) <= SNES_DATA_IN;
                          DEC_DONE <= '0';
            when x"0B" => DEC_MODE_REG <= SNES_DATA_IN(1 downto 0);
            -- Direct data ROM ($4811-$481A)
            when x"11" => DAT_POINTER(7  downto  0) <= SNES_DATA_IN;
            when x"12" => DAT_POINTER(15 downto  8) <= SNES_DATA_IN;
            when x"13" => DAT_POINTER(23 downto 16) <= SNES_DATA_IN;
                          DP_READ <= '1';
            when x"14" => -- ADJUST low byte; may auto-advance pointer
                          DAT_ADJUST(7 downto 0) <= SNES_DATA_IN;
                          if DAT_MODE(6 downto 5) = "01" then
                            PTR_V(23 downto 16) := (others => SNES_DATA_IN(7) and DAT_MODE(3));
                            PTR_V(15 downto  8) := DAT_ADJUST(15 downto 8);
                            PTR_V( 7 downto  0) := SNES_DATA_IN;
                            DAT_POINTER <= std_logic_vector(
                              unsigned(DAT_POINTER) + unsigned(PTR_V));
                            DP_READ <= '1';
                          end if;
            when x"15" => -- ADJUST high byte; may auto-advance pointer
                          DAT_ADJUST(15 downto 8) <= SNES_DATA_IN;
                          if DAT_MODE(1) = '1' then
                            DP_READ <= '1';
                          end if;
                          if DAT_MODE(6 downto 5) = "10" then
                            PTR_V(23 downto 16) := (others => SNES_DATA_IN(7) and DAT_MODE(3));
                            PTR_V(15 downto  8) := SNES_DATA_IN;
                            PTR_V( 7 downto  0) := DAT_ADJUST(7 downto 0);
                            DAT_POINTER <= std_logic_vector(
                              unsigned(DAT_POINTER) + unsigned(PTR_V));
                            DP_READ <= '1';
                          end if;
            when x"16" => DAT_INCR(7  downto 0) <= SNES_DATA_IN;
            when x"17" => DAT_INCR(15 downto 8) <= SNES_DATA_IN;
            when x"18" => DAT_MODE <= SNES_DATA_IN(6 downto 0);
                          DP_READ  <= '1';
            -- Mul/div ($4820-$482E)
            when x"20" => MULTIPLICAND(7  downto 0) <= SNES_DATA_IN;
                          DIVIDEND(7  downto 0)     <= SNES_DATA_IN;
            when x"21" => MULTIPLICAND(15 downto 8) <= SNES_DATA_IN;
                          DIVIDEND(15 downto 8)     <= SNES_DATA_IN;
            when x"22" => DIVIDEND(23 downto 16)    <= SNES_DATA_IN;
            when x"23" => DIVIDEND(31 downto 24)    <= SNES_DATA_IN;
            when x"24" => MULTIPLIER(7  downto 0)   <= SNES_DATA_IN;
            when x"25" => MULTIPLIER(15 downto 8)   <= SNES_DATA_IN;
                          muldiv_start  <= '1';
                          muldiv_is_div <= '0';
                          MUL_RUN       <= '1';
                          ALU_CNT       <= (others => '0');
            when x"26" => DIVISOR(7  downto 0) <= SNES_DATA_IN;
            when x"27" => DIVISOR(15 downto 8) <= SNES_DATA_IN;
                          muldiv_start  <= '1';
                          muldiv_is_div <= '1';
                          DIV_RUN       <= '1';
                          ALU_CNT       <= (others => '0');
            when x"2E" => SIGN <= SNES_DATA_IN(0);
            -- Bank mapping ($4830-$4836)
            when x"30" => SRAM_EN <= SNES_DATA_IN(7);
            when x"31" => BANKD <= SNES_DATA_IN(3 downto 0);
            when x"32" => BANKE <= SNES_DATA_IN(3 downto 0);
            when x"33" => BANKF <= SNES_DATA_IN(3 downto 0);
            -- RTC ($4840-$4842): CE and data handled combinatorially via
            -- RTC_CE_WR/BIT, RTC_SER_WR/DATA, RTC_SER_RD; nothing to latch.
            when x"40" => null;
            when x"41" => null;
            when x"42" => null;  -- status is read-only
            when others => null;
          end case;
        end if;

        -- ------------------------------------------------------------------
        -- Register reads
        -- ------------------------------------------------------------------
        if is_reg_read = '1' then
          case reg_addr is
            -- $4800: decompressor byte output
            when x"00" =>
              data_out_r <= DEC_BUF_OUT;
              DEC_BUF_RD_ADDR <= DEC_BUF_RD_ADDR + 1;
              DEC_COUNTER <= std_logic_vector(unsigned(DEC_COUNTER) - 1);
            -- Decomp pointer read-back
            when x"01" => data_out_r <= DEC_POINTER(7  downto  0);
            when x"02" => data_out_r <= DEC_POINTER(15 downto  8);
            when x"03" => data_out_r <= DEC_POINTER(23 downto 16);
            when x"04" => data_out_r <= DEC_INDEX;
            when x"05" => data_out_r <= DEC_OFFSET(7  downto 0);
            when x"06" => data_out_r <= DEC_OFFSET(15 downto 8);
            when x"07" | x"08" => data_out_r <= x"00";
            when x"09" => data_out_r <= DEC_COUNTER(7  downto 0);
            when x"0A" => data_out_r <= DEC_COUNTER(15 downto 8);
            when x"0B" => data_out_r <= "000000" & DEC_MODE_REG;
            when x"0C" => data_out_r <= DEC_DONE & "0000000";  -- status
            -- $4810/$481A: direct data ROM output port; also triggers auto-increment
            when x"10" =>
              data_out_r <= DP_DATA_OUT;
              if DAT_MODE(0) = '0' then
                INC_V := x"000001";
              else
                INC_V(23 downto 16) := (others => DAT_INCR(15) and DAT_MODE(2));
                INC_V(15 downto  0) := DAT_INCR;
              end if;
              if DAT_MODE(4) = '0' then
                DAT_POINTER <= std_logic_vector(unsigned(DAT_POINTER) + unsigned(INC_V));
              else
                DAT_ADJUST <= std_logic_vector(unsigned(DAT_ADJUST) + unsigned(INC_V(15 downto 0)));
              end if;
              DP_READ <= '1';
            when x"11" => data_out_r <= DAT_POINTER(7  downto  0);
            when x"12" => data_out_r <= DAT_POINTER(15 downto  8);
            when x"13" => data_out_r <= DAT_POINTER(23 downto 16);
            when x"14" => data_out_r <= DAT_ADJUST(7  downto 0);
            when x"15" => data_out_r <= DAT_ADJUST(15 downto 8);
            when x"16" => data_out_r <= DAT_INCR(7  downto 0);
            when x"17" => data_out_r <= DAT_INCR(15 downto 8);
            when x"18" => data_out_r <= "0" & DAT_MODE;
            when x"19" => data_out_r <= x"00";
            when x"1A" =>
              -- adjust-based read
              data_out_r <= DP_DATA_OUT;
              if DAT_MODE(6 downto 5) = "11" then
                PTR_V(23 downto 16) := (others => DAT_ADJUST(15) and DAT_MODE(3));
                PTR_V(15 downto  0) := DAT_ADJUST;
                DAT_POINTER <= std_logic_vector(
                  unsigned(DAT_POINTER) + unsigned(PTR_V));
                DP_READ <= '1';
              end if;
            -- Mul/div results
            when x"28" => data_out_r <= MULDIV_RES(7  downto  0);
            when x"29" => data_out_r <= MULDIV_RES(15 downto  8);
            when x"2A" => data_out_r <= MULDIV_RES(23 downto 16);
            when x"2B" => data_out_r <= MULDIV_RES(31 downto 24);
            when x"2C" => data_out_r <= REM_RES(7  downto 0);
            when x"2D" => data_out_r <= REM_RES(15 downto 8);
            when x"2E" => data_out_r <= "0000000" & SIGN;
            when x"2F" => data_out_r <= (MUL_RUN or DIV_RUN) & "0000000";
            when x"30" => data_out_r <= SRAM_EN & "0000000";
            when x"31" => data_out_r <= "0000" & BANKD;
            when x"32" => data_out_r <= "0000" & BANKE;
            when x"33" => data_out_r <= "0000" & BANKF;
            when x"41" =>
              -- Return full 8-bit register value from RTC emulator.
              if RTC_EN = '1' then data_out_r <= RTC_SER_IN;
              else                 data_out_r <= x"FF";
              end if;
            when x"42" =>
              -- Bit 7 = ready flag from emulator (always 1 for zero-latency emu).
              if RTC_EN = '1' then data_out_r <= RTC_STATUS;
              else                 data_out_r <= x"FF";
              end if;
            -- Unimplemented registers return 0x00 (open-bus / powered-off behaviour).
            -- Returning 0xFF caused the hardware self-test REG INIT check to fail
            -- when it reads optional bank-mapping regs $4834-$4836 expecting 0x00.
            when others => data_out_r <= x"00";
          end case;
        end if;

        -- $50:xxxx reads: advance decompressor read pointer
        if addr_is_decomp = '1' and SNES_RD_start = '1' then
          data_out_r <= DEC_BUF_OUT;
          DEC_BUF_RD_ADDR <= DEC_BUF_RD_ADDR + 1;
        end if;

        -- ------------------------------------------------------------------
        -- Mul/div countdown
        -- ------------------------------------------------------------------
        if MUL_RUN = '1' then
          if ALU_CNT = 29 then
            ALU_CNT   <= (others => '0');
            MUL_RUN   <= '0';
            MULDIV_RES <= (muldiv_result_hi & muldiv_result_lo);
            REM_RES    <= (others => '0');
          else
            ALU_CNT <= ALU_CNT + 1;
          end if;
        elsif DIV_RUN = '1' then
          if ALU_CNT = 39 then
            ALU_CNT   <= (others => '0');
            DIV_RUN   <= '0';
            MULDIV_RES <= (muldiv_result_hi & muldiv_result_lo);
            REM_RES    <= muldiv_remainder;
          else
            ALU_CNT <= ALU_CNT + 1;
          end if;
        end if;

        -- ------------------------------------------------------------------
        -- Work state machine (PSRAM access arbitration)
        -- ------------------------------------------------------------------
        case WS is
          when WS_IDLE =>
            if LOAD_RUN = '1' then
              LOAD_ADDR_POS <= (others => '0');
              WS            <= WS_LOAD_ADDR1;
            elsif DP_READ = '1' then
              DP_READ <= '0';   -- clear the sticky flag now that WS is servicing it
              WS      <= WS_DP_READ1;
            elsif FIFO_FULL = '0' and
                  (DS = DS_DECODING or DS = DS_PRELOAD) then
              WS <= WS_LOAD_FIFO1;
            end if;

          -- LOAD_ADDR: read 4 bytes from DROM[POINTER + INDEX*4 + pos]
          when WS_LOAD_ADDR1 =>
            LOAD_RUN <= '0';   -- acknowledge sticky flag (mirrors MiSTer's clear-on-enter)
            WS <= WS_LOAD_ADDR2;

          when WS_LOAD_ADDR2 =>
            ADDR_V := std_logic_vector(
              unsigned(DEC_POINTER) +
              (unsigned(DEC_INDEX) & LOAD_ADDR_POS));
            ROM_ADDR_OUT <= drom_psram_linear(ADDR_V);
            ROM_REQ  <= '1';
            WS       <= WS_LOAD_ADDR3;

          when WS_LOAD_ADDR3 =>
            if ROM_ACK = '1' then
              case LOAD_ADDR_POS is
                when "00"   => DEC_MODE <= ROM_DATA_IN(1 downto 0);
                when "01"   => DEC_ADDR(23 downto 16) <= ROM_DATA_IN;
                when "10"   => DEC_ADDR(15 downto  8) <= ROM_DATA_IN;
                when others => DEC_ADDR(7  downto  0) <= ROM_DATA_IN;
              end case;
              LOAD_ADDR_POS <= LOAD_ADDR_POS + 1;
              if LOAD_ADDR_POS = 3 then
                WS <= WS_IDLE;
                -- ROM_REQ falls back to '0' via pulse default on last byte
              else
                WS <= WS_LOAD_ADDR2;
                -- WS_LOAD_ADDR2 will reassert ROM_REQ on the very next cycle
              end if;
            else
              ROM_REQ <= '1';  -- hold request while waiting for ACK
            end if;

          -- LOAD_FIFO: push one compressed byte into the decompressor FIFO
          when WS_LOAD_FIFO1 =>
            ROM_ADDR_OUT <= drom_psram_linear(DEC_ADDR);
            ROM_REQ      <= '1';
            WS           <= WS_LOAD_FIFO2;

          when WS_LOAD_FIFO2 =>
            if ROM_ACK = '1' then
              FIFO_D   <= ROM_DATA_IN;
              FIFO_WR  <= '1';
              DEC_ADDR <= std_logic_vector(unsigned(DEC_ADDR) + 1);
              WS       <= WS_LOAD_FIFO3;
              -- ROM_REQ falls back to '0' via pulse default
            else
              ROM_REQ <= '1';  -- hold request while waiting for ACK
            end if;

          when WS_LOAD_FIFO3 =>
            WS <= WS_IDLE;

          -- DP_READ: read one byte into DP_DATA_OUT
          when WS_DP_READ1 =>
            if DAT_MODE(1) = '0' then
              INC_V := (others => '0');
            else
              INC_V(23 downto 16) := (others => DAT_ADJUST(15) and DAT_MODE(3));
              INC_V(15 downto  0) := DAT_ADJUST;
            end if;
            ADDR_V := std_logic_vector(unsigned(DAT_POINTER) + unsigned(INC_V));
            ROM_ADDR_OUT <= drom_psram_linear(ADDR_V);
            ROM_REQ <= '1';
            WS      <= WS_DP_READ2;

          when WS_DP_READ2 =>
            if ROM_ACK = '1' then
              DP_DATA_OUT <= ROM_DATA_IN;
              WS          <= WS_IDLE;
              -- ROM_REQ falls back to '0' via pulse default; do NOT override
              -- here so the SPC FSM does not see a spurious re-request on the
              -- very next cycle after it returns to SPC_IDLE.
            else
              ROM_REQ <= '1';  -- hold request while waiting for ACK
            end if;

          when others => null;
        end case;

        -- ------------------------------------------------------------------
        -- Decompression state machine (manages DEC_RUN / FIFO preload)
        -- ------------------------------------------------------------------
        DEC_RUN_OLD <= DEC_RUN;
        if DEC_RUN = '0' and DEC_RUN_OLD = '1' and DEC_DONE = '0' then
          DEC_DONE <= '1';
        end if;

        case DS is
          when DS_IDLE =>
            if DEC_START = '1' then
              DEC_RUN <= '0';
              DS      <= DS_PRELOAD;
            end if;

          when DS_PRELOAD =>
            if FIFO_FULL = '1' then
              DEC_INIT_PULSE <= '1';
              DS             <= DS_INIT;
            end if;

          when DS_INIT =>
            DEC_INIT_PULSE <= '0';
            DEC_RUN        <= '1';
            DEC_BUF_WR_ADDR<= (others => '0');
            DS             <= DS_DECODING;

          when DS_DECODING =>
            if LOAD_RUN = '1' or DP_READ = '1' then
              DEC_RUN     <= '0';
              DEC_WR_BUSY <= '0';
              DS          <= DS_IDLE;
            elsif DEC_WR_BUSY = '1' then
              -- Serialize remaining bytes (one write/clock for XST LUT-RAM inference)
              case DEC_WR_MODE is
                when "01" =>  -- 2bpp: second byte
                  v_buf_we   := '1';
                  v_buf_addr := DEC_WR_BASE + 1;
                  v_buf_dat  := DEC_DAT_LATCH(14) & DEC_DAT_LATCH(12) & DEC_DAT_LATCH(10) & DEC_DAT_LATCH(8) &
                                DEC_DAT_LATCH(6)  & DEC_DAT_LATCH(4)  & DEC_DAT_LATCH(2)  & DEC_DAT_LATCH(0);
                  DEC_BUF_WR_ADDR <= DEC_WR_BASE + 2;
                  -- Use pre-decrement stop flag captured at DEC_OUT_WR time
                  -- (matches MiSTer's same-cycle OFFSET check).
                  if DEC_WR_BASE(4 downto 0) = 30 then
                    if DEC_WR_CAN_STOP = '1' then
                      DEC_RUN <= '0';
                    end if;
                  end if;
                  DEC_WR_BUSY <= '0';
                when others =>  -- 4bpp: phases 1, 2, 3
                  case DEC_WR_PHASE is
                    when "01" =>
                      v_buf_we   := '1';
                      v_buf_addr := DEC_WR_BASE + 1;
                      v_buf_dat  := DEC_DAT_LATCH(30) & DEC_DAT_LATCH(26) & DEC_DAT_LATCH(22) & DEC_DAT_LATCH(18) &
                                    DEC_DAT_LATCH(14) & DEC_DAT_LATCH(10) & DEC_DAT_LATCH(6)  & DEC_DAT_LATCH(2);
                      DEC_WR_PHASE <= "10";
                    when "10" =>
                      v_buf_we   := '1';
                      v_buf_addr := DEC_WR_BASE + 16;
                      v_buf_dat  := DEC_DAT_LATCH(29) & DEC_DAT_LATCH(25) & DEC_DAT_LATCH(21) & DEC_DAT_LATCH(17) &
                                    DEC_DAT_LATCH(13) & DEC_DAT_LATCH(9)  & DEC_DAT_LATCH(5)  & DEC_DAT_LATCH(1);
                      DEC_WR_PHASE <= "11";
                    when "11" =>
                      v_buf_we   := '1';
                      v_buf_addr := DEC_WR_BASE + 17;
                      v_buf_dat  := DEC_DAT_LATCH(28) & DEC_DAT_LATCH(24) & DEC_DAT_LATCH(20) & DEC_DAT_LATCH(16) &
                                    DEC_DAT_LATCH(12) & DEC_DAT_LATCH(8)  & DEC_DAT_LATCH(4)  & DEC_DAT_LATCH(0);
                      if DEC_WR_BASE(3 downto 0) = 14 then
                        DEC_BUF_WR_ADDR <= DEC_WR_BASE + 18;
                        -- Use pre-decrement stop flag captured at DEC_OUT_WR time
                        -- (matches MiSTer's same-cycle OFFSET check).
                        if DEC_WR_CAN_STOP = '1' then
                          DEC_RUN <= '0';
                        end if;
                      else
                        DEC_BUF_WR_ADDR <= DEC_WR_BASE + 2;
                      end if;
                      DEC_WR_BUSY <= '0';
                    when others => null;
                  end case;
              end case;
            elsif DEC_OUT_WR = '1' then
              -- Latch and start writing (byte 0 always emitted this cycle).
              -- Capture stop eligibility NOW (pre-OFFSET-decrement) so that
              -- delayed DEC_WR_BUSY phases use the same OFFSET value MiSTer
              -- would see at this cycle.  Mirrors MiSTer's single-process
              -- same-cycle stop check in DS_DECODING/DEC_OUT_WR.
              DEC_DAT_LATCH <= DEC_DAT_OUT;
              DEC_WR_BASE   <= DEC_BUF_WR_ADDR;
              DEC_WR_MODE   <= DEC_MODE;
              if DEC_MODE_REG = "00" or DEC_OFFSET = x"0000" then
                DEC_WR_CAN_STOP <= '1';
              else
                DEC_WR_CAN_STOP <= '0';
              end if;
              case DEC_MODE is
                when "00" =>
                  -- 1bpp: single byte, complete in one cycle
                  v_buf_we   := '1';
                  v_buf_addr := DEC_BUF_WR_ADDR;
                  v_buf_dat  := DEC_DAT_OUT(7 downto 0);
                  DEC_BUF_WR_ADDR <= DEC_BUF_WR_ADDR + 1;
                  if DEC_BUF_WR_ADDR(4 downto 0) = 31 then
                    if DEC_MODE_REG = "00" or DEC_OFFSET = x"0000" then
                      DEC_RUN <= '0';
                    end if;
                  end if;
                when "01" =>
                  -- 2bpp: byte 0 now, byte 1 next cycle
                  v_buf_we   := '1';
                  v_buf_addr := DEC_BUF_WR_ADDR;
                  v_buf_dat  := DEC_DAT_OUT(15) & DEC_DAT_OUT(13) & DEC_DAT_OUT(11) & DEC_DAT_OUT(9) &
                                DEC_DAT_OUT(7)  & DEC_DAT_OUT(5)  & DEC_DAT_OUT(3)  & DEC_DAT_OUT(1);
                  DEC_WR_PHASE <= "01";
                  DEC_WR_BUSY  <= '1';
                when others =>
                  -- 4bpp: byte 0 now, bytes 1/2/3 over next 3 cycles
                  v_buf_we   := '1';
                  v_buf_addr := DEC_BUF_WR_ADDR;
                  v_buf_dat  := DEC_DAT_OUT(31) & DEC_DAT_OUT(27) & DEC_DAT_OUT(23) & DEC_DAT_OUT(19) &
                                DEC_DAT_OUT(15) & DEC_DAT_OUT(11) & DEC_DAT_OUT(7)  & DEC_DAT_OUT(3);
                  DEC_WR_PHASE <= "01";
                  DEC_WR_BUSY  <= '1';
              end case;
            elsif DEC_RUN = '0' and
                  DEC_BUF_RD_ADDR(5) /= DEC_BUF_WR_ADDR(5) then
              DEC_RUN <= '1';
            end if;

          when others => null;
        end case;

        -- DEC_START: reset buffer pointers and go to PRELOAD
        if DEC_START = '1' then
          DS          <= DS_PRELOAD;
          DEC_RUN     <= '0';
          DEC_WR_BUSY <= '0';
        end if;

        -- DEC_OUT_WR: if auto-offset mode and OFFSET active, advance rd ptr by 4
        if DEC_OUT_WR = '1' then
          if DEC_MODE_REG = "10" and DEC_OFFSET /= x"0000" then
            DEC_BUF_RD_ADDR <= DEC_BUF_RD_ADDR + 4;
            DEC_OFFSET       <= std_logic_vector(unsigned(DEC_OFFSET) - 1);
          end if;
        end if;

        -- DEC_BUF single-port write (one per clock; enables XST LUT-RAM inference)
        if v_buf_we = '1' then
          DEC_BUF(to_integer(v_buf_addr)) <= v_buf_dat;
        end if;

        -- ----------------------------------------------------------------
        -- Bus output-enable: level signal active for the FULL /RD pulse.
        -- SNES_RD is the 2-cycle-delayed, active-low /RD from main.v.
        -- Keeping OE high throughout the cycle prevents any glitch on the
        -- SNES data bus between the RD_start strobe and actual /RD release.
        -- ----------------------------------------------------------------
        data_oe_r <= (addr_is_reg or addr_is_decomp) and not SNES_RD;

      end if;  -- rst
    end if;  -- rising_edge
  end process;

end architecture rtl;
