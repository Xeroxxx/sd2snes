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
--
-- Division uses a sequential shift-and-subtract (restoring) state machine:
-- one step per clock, 32 steps total, result available after ~33 clocks.
-- This replaces the former fully-unrolled for-loop that synthesised to
-- ~1400 LUTs and exceeded the XC3S400 resource limit (3584 slices).
-- The shift-register form needs only ~50 combinational LUTs + ~100 FFs,
-- and is accepted by both Xilinx XST (Spartan-3/MK2) and Quartus (Cyclone
-- IV/MK3).  The 32-step divide completes inside the 40-cycle busy window.
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
  -- timing / busy control
  signal countdown   : unsigned(6 downto 0) := (others => '0');
  signal running     : std_logic := '0';
  signal mode_div_r  : std_logic := '0';

  -- result registers
  signal res_lo  : std_logic_vector(15 downto 0) := (others => '0');
  signal res_hi  : std_logic_vector(15 downto 0) := (others => '0');
  signal res_rem : std_logic_vector(15 downto 0) := (others => '0');
  signal res_sgn : std_logic := '0';

  -- Sequential divide state machine registers.
  -- div_step encoding:
  --   33..63 : idle (no operation)
  --   32..1  : active iteration (processing bit div_step-1 of quotient)
  --   0      : finalize (apply sign correction, write results)
  signal div_step  : unsigned(5 downto 0)  := to_unsigned(33, 6);
  signal div_reg   : unsigned(31 downto 0) := (others => '0'); -- dividend shift reg
  signal dvr17_reg : unsigned(16 downto 0) := (others => '0'); -- 17-bit extended divisor
  signal acc_reg   : unsigned(16 downto 0) := (others => '0'); -- partial remainder
  signal q32v_reg  : unsigned(31 downto 0) := (others => '0'); -- quotient shift reg
  signal neg_dd_r  : std_logic := '0';  -- latched: dividend was negative
  signal neg_dr_r  : std_logic := '0';  -- latched: divisor was negative

begin
  result_lo <= res_lo;
  result_hi <= res_hi;
  remainder <= res_rem;
  sign_flag <= res_sgn;
  busy      <= running;

  process(clk)
    variable ua16    : unsigned(15 downto 0);
    variable ub16    : unsigned(15 downto 0);
    variable u32     : unsigned(31 downto 0);
    variable a32     : signed(31 downto 0);
    variable div_u   : unsigned(31 downto 0);
    variable dvr_u   : unsigned(15 downto 0);
    variable new_acc : unsigned(16 downto 0);
    variable sq32v   : signed(31 downto 0);
    variable srem16v : signed(15 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        running   <= '0';
        countdown <= (others => '0');
        div_step  <= to_unsigned(33, 6);

      elsif start = '1' and running = '0' then
        running    <= '1';
        mode_div_r <= mode_div;
        if mode_div = '1' then
          countdown <= to_unsigned(40, 7);
        else
          countdown <= to_unsigned(30, 7);
        end if;

        if mode_div = '0' then
          -- ----------------------------------------------------------------
          -- MULTIPLY (16×16 → 32; XST infers MULT18X18 primitive)
          -- ----------------------------------------------------------------
          if mode_sign = '0' then
            ua16 := unsigned(multiplicand);
            ub16 := unsigned(multiplier);
            u32  := ua16 * ub16;
            res_lo  <= std_logic_vector(u32(15 downto 0));
            res_hi  <= std_logic_vector(u32(31 downto 16));
            res_rem <= (others => '0');
            res_sgn <= '0';
          else
            a32 := signed(multiplicand) * signed(multiplier);
            res_lo  <= std_logic_vector(a32(15 downto 0));
            res_hi  <= std_logic_vector(a32(31 downto 16));
            res_rem <= (others => '0');
            res_sgn <= a32(31);
          end if;
          div_step <= to_unsigned(33, 6);  -- idle

        else
          -- ----------------------------------------------------------------
          -- DIVIDE: preload shift-register pipeline.
          --   acc_reg and q32v_reg shift left each clock in the running
          --   branch, MSB of div_reg feeding into the partial remainder.
          --   After 32 steps the quotient appears in q32v_reg and the
          --   final remainder in acc_reg(15:0).  One extra cycle (step=0)
          --   applies sign correction and commits the result registers.
          -- ----------------------------------------------------------------
          div_u := unsigned(dividend_hi) & unsigned(dividend_lo);
          dvr_u := unsigned(divisor);

          if dvr_u = 0 then
            -- Division by zero: saturate quotient, remainder = dividend_lo
            res_lo   <= (others => '1');
            res_hi   <= (others => '1');
            res_rem  <= dividend_lo;
            res_sgn  <= '0';
            div_step <= to_unsigned(33, 6);  -- skip all iterate/finalize steps
          else
            -- Latch sign flags before taking absolute values
            neg_dd_r <= mode_sign and div_u(31);
            neg_dr_r <= mode_sign and divisor(15);
            -- Compute |dividend| and |divisor| for the iterate phase
            if mode_sign = '1' and div_u(31) = '1' then
              div_reg <= unsigned(-signed(div_u));
            else
              div_reg <= div_u;
            end if;
            if mode_sign = '1' and divisor(15) = '1' then
              dvr17_reg <= '0' & unsigned(-signed(dvr_u));
            else
              dvr17_reg <= '0' & dvr_u;
            end if;
            acc_reg  <= (others => '0');
            q32v_reg <= (others => '0');
            div_step <= to_unsigned(32, 6);  -- start 32 iterations
          end if;
        end if;

      elsif running = '1' then
        -- ----------------------------------------------------------------
        -- Sequential divide state machine (one step per clock)
        -- ----------------------------------------------------------------
        if mode_div_r = '1' then
          if div_step > 0 and div_step <= 32 then
            -- Shift MSB of dividend into the 17-bit partial remainder
            new_acc := acc_reg(15 downto 0) & div_reg(31);
            if new_acc >= dvr17_reg then
              acc_reg  <= new_acc - dvr17_reg;
              q32v_reg <= q32v_reg(30 downto 0) & '1';
            else
              acc_reg  <= new_acc;
              q32v_reg <= q32v_reg(30 downto 0) & '0';
            end if;
            div_reg  <= div_reg(30 downto 0) & '0';  -- shift dividend
            div_step <= div_step - 1;

          elsif div_step = 0 then
            -- All 32 bits processed; apply sign correction and commit
            if neg_dd_r /= neg_dr_r then
              sq32v := -signed(q32v_reg);
            else
              sq32v := signed(q32v_reg);
            end if;
            if neg_dd_r = '1' then
              srem16v := -signed(acc_reg(15 downto 0));
            else
              srem16v := signed(acc_reg(15 downto 0));
            end if;
            res_lo  <= std_logic_vector(sq32v(15 downto 0));
            res_hi  <= std_logic_vector(sq32v(31 downto 16));
            res_rem <= std_logic_vector(srem16v);
            res_sgn <= sq32v(31);
            div_step <= to_unsigned(33, 6);  -- idle sentinel, won't re-enter
          end if;
        end if;

        -- Countdown / busy management (runs every running cycle)
        if countdown = 0 then
          running <= '0';
        else
          countdown <= countdown - 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
