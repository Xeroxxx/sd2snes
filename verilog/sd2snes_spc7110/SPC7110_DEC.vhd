----------------------------------------------------------------------------------
-- SPC7110_DEC.vhd
-- SPC7110 Graphics Decompressor
--
-- Implements the context-based binary arithmetic (range) coder used by the
-- SPC7110 chip.  Three decompression modes are supported:
--   Mode 0: 1 bpp graphics
--   Mode 1: 2 bpp graphics
--   Mode 2: 4 bpp graphics
--
-- Architecture:
--   * An SPC7110_FIFO supplies compressed bytes from PSRAM.
--   * The arithmetic coder processes one bit at a time from the bitstream,
--     using an 8-entry context register file (C0-C7).  Each context register
--     holds an evolution-table state index and an MPS bit.
--   * Decoded pixels are accumulated into a byte output register (dec_byte)
--     and signalled via dec_valid/dec_ack.
--   * Graphics mode determines how decoded bits are assembled into pixels and
--     how context indices are selected per bit position.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.SPC7110_DEC_PKG.all;

entity SPC7110_DEC is
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- Decompressor control
    mode         : in  std_logic_vector(1 downto 0); -- 00=1bpp, 01=2bpp, 10=4bpp
    start        : in  std_logic;  -- pulse: reset all contexts & begin
    -- Compressed input byte stream from FIFO
    fifo_empty   : in  std_logic;
    fifo_data    : in  std_logic_vector(7 downto 0);
    fifo_rd      : out std_logic;
    -- Decompressed byte output
    dec_valid    : out std_logic;
    dec_byte     : out std_logic_vector(7 downto 0);
    dec_ack      : in  std_logic;
    -- Status
    idle         : out std_logic
  );
end entity SPC7110_DEC;

architecture rtl of SPC7110_DEC is

  -- Context register file
  signal ctx_state : t_ctx_state;
  signal ctx_mps   : t_ctx_mps;

  -- Range coder state (16-bit range, 16-bit code value)
  signal range_r   : unsigned(15 downto 0);
  signal code_c    : unsigned(15 downto 0);

  -- Bit input registers
  signal bit_buf   : std_logic_vector(7 downto 0);
  signal bit_cnt   : unsigned(2 downto 0);  -- bits remaining in bit_buf (0=empty)
  signal load_cnt  : unsigned(1 downto 0) := (others => '0');  -- counts bytes loaded during S_LOAD (need 2)

  -- Decoded output accumulator
  signal acc_byte  : std_logic_vector(7 downto 0);
  signal acc_cnt   : unsigned(3 downto 0);  -- number of bits accumulated (0-7)

  -- Decode state machine
  type t_dec_state is (S_INIT, S_LOAD, S_DECODE, S_OUTPUT, S_IDLE);
  signal dec_state : t_dec_state;

  signal dec_valid_r : std_logic;
  signal dec_byte_r  : std_logic_vector(7 downto 0);

  -- Arithmetic coder context lookup (combinational)
  signal evo         : t_evo_entry;
  signal ctx_idx     : unsigned(2 downto 0);

  -- Context index selection function:
  -- For 1bpp: context = bit_pos[2:0] (use 8 contexts for 8 bit positions)
  -- For 2bpp: context = {bitplane[0], bit_pos[1:0]}
  -- For 4bpp: context = {bitplane[1:0], bit_pos[0]}
  signal bit_pos     : unsigned(2 downto 0);  -- bit position within decoded byte (0-7)

  function get_ctx(mode_in : std_logic_vector(1 downto 0);
                   bit_p   : unsigned(2 downto 0)) return unsigned is
  begin
    case mode_in is
      when "00"   => return bit_p;                          -- 1bpp: 8 contexts
      when "01"   => return "0" & bit_p(1 downto 0);        -- 2bpp: 4 contexts per plane
      when "10"   => return "00" & bit_p(0);                -- 4bpp: 2 contexts per plane
      when others => return bit_p;
    end case;
  end function;

begin

  dec_valid <= dec_valid_r;
  dec_byte  <= dec_byte_r;
  idle      <= '1' when dec_state = S_IDLE else '0';

  -- Context index for current bit position (combinational)
  ctx_idx <= get_ctx(mode, bit_pos);

  -- Evolution table lookup (combinational)
  evo <= EVOL_TBL(to_integer(ctx_state(to_integer(ctx_idx))));

  process(clk)
    variable decoded_bit : std_logic;
    variable is_lps      : std_logic;
    variable new_state   : unsigned(5 downto 0);
    variable new_mps     : std_logic;
    variable p_thresh    : unsigned(15 downto 0);
    variable new_range   : unsigned(15 downto 0);
    variable new_code    : unsigned(15 downto 0);
    -- Renorm variables (all variables so they can be updated in the loop)
    variable rn_range    : unsigned(15 downto 0);
    variable rn_code     : unsigned(15 downto 0);
    variable rn_buf      : std_logic_vector(7 downto 0);
    variable rn_cnt      : unsigned(2 downto 0);
  begin
    if rising_edge(clk) then
      -- default pulse deassert
      fifo_rd <= '0';
      dec_valid_r <= '0';

      if rst = '1' or start = '1' then
        -- Reset context file
        for i in 0 to 7 loop
          ctx_state(i) <= (others => '0');
          ctx_mps(i)   <= '0';
        end loop;
        range_r     <= x"8000";
        code_c      <= (others => '0');
        bit_buf     <= (others => '0');
        bit_cnt     <= (others => '0');
        acc_byte    <= (others => '0');
        acc_cnt     <= (others => '0');
        bit_pos     <= (others => '0');
        load_cnt    <= (others => '0');
        dec_state   <= S_LOAD;
        dec_valid_r <= '0';
      else
        case dec_state is

          -- Load two bytes to prime the 16-bit code register (MSB first).
          -- The SPC7110 range coder initialises code_c from the first two
          -- compressed bytes: code_c = {byte0, byte1}.
          when S_LOAD =>
            if fifo_empty = '0' then
              fifo_rd <= '1';
              case load_cnt is
                when "00" =>
                  code_c(15 downto 8) <= unsigned(fifo_data);
                  load_cnt <= "01";
                when "01" =>
                  code_c(7 downto 0) <= unsigned(fifo_data);
                  load_cnt  <= "00";
                  -- Initial range is 0x8000 (standard binary arithmetic coder)
                  range_r   <= x"8000";
                  dec_state <= S_DECODE;
                when others =>
                  load_cnt <= "00";
                  dec_state <= S_DECODE;
              end case;
            end if;

          when S_DECODE =>
            -- Refill input byte if needed; stall for one cycle
            if bit_cnt = 0 then
              if fifo_empty = '0' then
                fifo_rd <= '1';
                bit_buf <= fifo_data;
                bit_cnt <= to_unsigned(8, 3);
              end if;
              -- stall: no bits available yet
            else
              -- Arithmetic coder: one-bit decode step
              -- p_thresh = (range[15:8] * p_lps) >> 8  (8-bit approximation)
              p_thresh := resize(range_r(15 downto 8) * evo.p_lps, 16);

              if code_c < p_thresh then
                is_lps := '1';
              else
                is_lps := '0';
              end if;

              -- symbol value: XOR with MPS
              if is_lps = '0' then
                decoded_bit := ctx_mps(to_integer(ctx_idx));
              else
                decoded_bit := not ctx_mps(to_integer(ctx_idx));
              end if;

              -- Update range and code value
              if is_lps = '0' then
                new_range := range_r - p_thresh;
                new_code  := code_c - p_thresh;
              else
                new_range := p_thresh;
                new_code  := code_c;
              end if;

              -- Renormalize (using variables so shifts accumulate in loop)
              rn_range := new_range;
              rn_code  := new_code;
              rn_buf   := bit_buf;
              rn_cnt   := bit_cnt;
              for sh in 0 to 15 loop
                if rn_range(15) = '0' then
                  rn_range := rn_range(14 downto 0) & '0';
                  if rn_cnt > 0 then
                    rn_code := rn_code(14 downto 0) & rn_buf(7);
                    rn_buf  := rn_buf(6 downto 0) & '0';
                    rn_cnt  := rn_cnt - 1;
                  else
                    -- No bits left — shift in 0 as placeholder; will stall next cycle
                    rn_code := rn_code(14 downto 0) & '0';
                  end if;
                end if;
              end loop;
              range_r <= rn_range;
              code_c  <= rn_code;
              bit_buf <= rn_buf;
              bit_cnt <= rn_cnt;

              -- Update context: state + MPS
              if is_lps = '0' then
                new_state := evo.next_mps;
                new_mps   := ctx_mps(to_integer(ctx_idx));
              else
                new_state := evo.next_lps;
                if evo.lps_xchg = '1' then
                  new_mps := not ctx_mps(to_integer(ctx_idx));
                else
                  new_mps := ctx_mps(to_integer(ctx_idx));
                end if;
              end if;
              ctx_state(to_integer(ctx_idx)) <= new_state;
              ctx_mps(to_integer(ctx_idx))   <= new_mps;

              -- Accumulate decoded bit into output byte (MSB first)
              acc_byte <= acc_byte(6 downto 0) & decoded_bit;
              if acc_cnt = 7 then
                acc_cnt     <= (others => '0');
                dec_state   <= S_OUTPUT;
                dec_byte_r  <= acc_byte(6 downto 0) & decoded_bit;
                dec_valid_r <= '1';
                bit_pos     <= bit_pos + 1;
              else
                acc_cnt   <= acc_cnt + 1;
                dec_state <= S_DECODE;
              end if;
            end if;

          when S_OUTPUT =>
            -- Hold valid until consumer acknowledges
            dec_valid_r <= '1';
            if dec_ack = '1' then
              dec_valid_r <= '0';
              dec_state   <= S_DECODE;
            end if;

          when S_IDLE =>
            null;

          when others =>
            dec_state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
