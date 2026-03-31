----------------------------------------------------------------------------------
-- SPC7110_FIFO.vhd
-- Small synchronous FIFO used to buffer compressed input bytes read from PSRAM
-- before they are consumed by the SPC7110 decompressor arithmetic coder.
-- Depth: 16 bytes (sufficient margin at 96 MHz vs SNES bus rate).
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SPC7110_FIFO is
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    -- write side (from PSRAM DMA)
    wr_en    : in  std_logic;
    wr_data  : in  std_logic_vector(7 downto 0);
    full     : out std_logic;
    -- read side (to arithmetic coder)
    rd_en    : in  std_logic;
    rd_data  : out std_logic_vector(7 downto 0);
    empty    : out std_logic;
    count    : out unsigned(4 downto 0)
  );
end entity SPC7110_FIFO;

architecture rtl of SPC7110_FIFO is
  type t_fifo_mem is array(0 to 15) of std_logic_vector(7 downto 0);
  signal mem   : t_fifo_mem;
  signal rptr  : unsigned(3 downto 0) := (others => '0');
  signal wptr  : unsigned(3 downto 0) := (others => '0');
  signal cnt   : unsigned(4 downto 0) := (others => '0');
begin

  full   <= '1' when cnt = 16 else '0';
  empty  <= '1' when cnt = 0  else '0';
  count  <= cnt;

  rd_data <= mem(to_integer(rptr));

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        rptr <= (others => '0');
        wptr <= (others => '0');
        cnt  <= (others => '0');
      else
        if wr_en = '1' and cnt < 16 then
          mem(to_integer(wptr)) <= wr_data;
          wptr <= wptr + 1;
          cnt  <= cnt + 1;
        end if;
        if rd_en = '1' and cnt > 0 then
          rptr <= rptr + 1;
          if wr_en = '1' and cnt < 16 then
            null; -- write already counted above
          else
            cnt <= cnt - 1;
          end if;
        end if;
        -- simultaneous read+write: cnt stays the same (already handled above)
        if wr_en = '1' and rd_en = '1' and cnt > 0 and cnt < 16 then
          cnt <= cnt;  -- no net change
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
