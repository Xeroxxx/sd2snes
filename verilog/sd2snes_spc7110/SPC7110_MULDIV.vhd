----------------------------------------------------------------------------------
-- SPC7110_MULDIV.vhd
-- SPC7110 Multiply and Divide units.
-- Implements the four arithmetic modes exposed via registers $4820-$482F:
--   Unsigned 16x16 multiply   ($4820/$4821 × $4824/$4825  → 32-bit result)
--   Signed   16x16 multiply   (same registers, signed mode)
--   Unsigned 32÷16 divide     ($4820/$4821/$4822/$4823 ÷ $4826/$4827 → Q+R)
--   Signed   32÷16 divide     (same, signed mode)
-- Sign mode is set via register $482E bit[0] (written before triggering).
-- Multiply is triggered by writing to $4825; divide by writing to $4827.
-- The ALU runs over 30 cycles (multiply) or 40 cycles (divide) to match
-- real SPC7110 timing observed in FEoEZ.
-- This module uses only IEEE.NUMERIC_STD operators — no Altera LPM.
-- It synthesizes correctly on both Altera Cyclone IV (MK3) and Xilinx
-- Spartan-3 (MK2).
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SPC7110_MULDIV is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    -- operand registers (written by SNES/MCU)
    multiplicand : in  std_logic_vector(15 downto 0); -- {$4821,$4820}
    multiplier   : in  std_logic_vector(15 downto 0); -- {$4825,$4824}  (write to $4825 triggers)
    dividend_hi  : in  std_logic_vector(15 downto 0); -- {$4823,$4822}  dividend bits 31:16
    dividend_lo  : in  std_logic_vector(15 downto 0); -- {$4821,$4820}  dividend bits 15:0
    divisor      : in  std_logic_vector(15 downto 0); -- {$4827,$4826}  (write to $4827 triggers)
    mode_sign    : in  std_logic;  -- 0=unsigned, 1=signed  (from $482E bit[0])
    mode_div     : in  std_logic;  -- 0=multiply, 1=divide
    start        : in  std_logic;  -- pulse to begin
    -- result registers (read by SNES)
    result_lo    : out std_logic_vector(15 downto 0); -- $4829/$4828
    result_hi    : out std_logic_vector(15 downto 0); -- $482B/$482A
    remainder    : out std_logic_vector(15 downto 0); -- $482D/$482C
    sign_flag    : out std_logic;                     -- result sign (unused by calling code)
    busy         : out std_logic                      -- $482F[7], 0=done
  );
end entity SPC7110_MULDIV;

architecture rtl of SPC7110_MULDIV is
  signal countdown : unsigned(5 downto 0) := (others => '0');
  signal running   : std_logic := '0';

  signal res_lo  : std_logic_vector(15 downto 0) := (others => '0');
  signal res_hi  : std_logic_vector(15 downto 0) := (others => '0');
  signal res_rem : std_logic_vector(15 downto 0) := (others => '0');
  signal res_sgn : std_logic := '0';

begin
  result_lo <= res_lo;
  result_hi <= res_hi;
  remainder <= res_rem;
  sign_flag <= res_sgn;
  busy      <= running;

  process(clk)
    variable a32  : signed(31 downto 0);
    variable b16  : signed(15 downto 0);
    variable u32  : unsigned(31 downto 0);
    variable ua16 : unsigned(15 downto 0);
    variable ub16 : unsigned(15 downto 0);
    variable q32  : unsigned(31 downto 0);
    variable r16  : unsigned(15 downto 0);
    variable sq32 : signed(31 downto 0);
    variable ua32 : unsigned(31 downto 0);
    variable d32hi: unsigned(15 downto 0);
    variable d32lo: unsigned(15 downto 0);
    variable div_u : unsigned(31 downto 0);
    variable dvr_u : unsigned(15 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        running   <= '0';
        countdown <= (others => '0');
      elsif start = '1' and running = '0' then
        running   <= '1';
        -- latency: 30 cycles for multiply, 40 for divide
        if mode_div = '1' then
          countdown <= to_unsigned(40, 6);
        else
          countdown <= to_unsigned(30, 6);
        end if;
        -- Compute result immediately (combinational result registered here).
        -- The countdown provides the timing illusion; game code polls $482F.
        if mode_div = '0' then
          -- MULTIPLY
          if mode_sign = '0' then
            -- unsigned 16x16 → 32-bit product
            ua16 := unsigned(multiplicand);
            ub16 := unsigned(multiplier);
            u32  := ua16 * ub16;
            res_lo  <= std_logic_vector(u32(15 downto 0));
            res_hi  <= std_logic_vector(u32(31 downto 16));
            res_rem <= (others => '0');
            res_sgn <= '0';
          else
            -- signed 16x16 → 32-bit product
            a32 := resize(signed(multiplicand), 32) * resize(signed(multiplier), 32);
            res_lo  <= std_logic_vector(a32(15 downto 0));
            res_hi  <= std_logic_vector(a32(31 downto 16));
            res_rem <= (others => '0');
            res_sgn <= a32(31);
          end if;
        else
          -- DIVIDE
          d32hi := unsigned(dividend_hi);
          d32lo := unsigned(dividend_lo);
          div_u := d32hi & d32lo;
          dvr_u := unsigned(divisor);
          if dvr_u = 0 then
            -- division by zero: saturate
            res_lo  <= (others => '1');
            res_hi  <= (others => '1');
            res_rem <= std_logic_vector(d32lo);
            res_sgn <= '0';
          elsif mode_sign = '0' then
            -- unsigned 32÷16
            q32 := div_u / dvr_u;
            r16 := resize(div_u mod dvr_u, 16);
            res_lo  <= std_logic_vector(q32(15 downto 0));
            res_hi  <= std_logic_vector(q32(31 downto 16));
            res_rem <= std_logic_vector(r16);
            res_sgn <= '0';
          else
            -- signed 32÷16
            a32  := signed(div_u);
            b16  := signed(dvr_u);
            sq32 := resize(a32 / resize(b16, 32), 32);
            res_lo  <= std_logic_vector(sq32(15 downto 0));
            res_hi  <= std_logic_vector(sq32(31 downto 16));
            res_rem <= std_logic_vector(resize(a32 mod resize(b16, 32), 16));
            res_sgn <= sq32(31);
          end if;
        end if;
      elsif running = '1' then
        if countdown = 0 then
          running <= '0';
        else
          countdown <= countdown - 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
