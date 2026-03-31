----------------------------------------------------------------------------------
-- SPC7110_DEC_PKG.vhd
-- SPC7110 Decompressor Support Package: probability evolution table and helpers
-- Ported for sd2snes from the MiSTer SPC7110 core reference.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package SPC7110_DEC_PKG is

  -- Evolution table entry type
  -- p_lps:    8-bit LPS probability (range 0x01..0x5A)
  -- next_mps: 6-bit next state on MPS (most probable symbol)
  -- next_lps: 6-bit next state on LPS (least probable symbol)
  -- lps_xchg: swap MPS/LPS when an LPS event occurs at this state
  type t_evo_entry is record
    p_lps    : unsigned(7 downto 0);
    next_mps : unsigned(5 downto 0);
    next_lps : unsigned(5 downto 0);
    lps_xchg : std_logic;
  end record;

  type t_evol_table is array(0 to 52) of t_evo_entry;

  -- Probability evolution table (53 entries, indices 0-52).
  -- Values match the SPC7110 ASIC as documented by byuu/BSNES and verified
  -- against FEoEZ, Momotarou Densetsu Happy, and Super Power League 4.
  -- Format: (p_lps, next_mps, next_lps, lps_xchg)
  constant EVOL_TBL : t_evol_table := (
    --  idx  p_lps  nmps nlps xchg
    0  => (x"5A", to_unsigned( 1,6), to_unsigned( 1,6), '1'),
    1  => (x"25", to_unsigned( 6,6), to_unsigned( 2,6), '0'),
    2  => (x"11", to_unsigned( 8,6), to_unsigned( 3,6), '0'),
    3  => (x"08", to_unsigned(10,6), to_unsigned( 4,6), '0'),
    4  => (x"03", to_unsigned(12,6), to_unsigned( 5,6), '0'),
    5  => (x"01", to_unsigned(15,6), to_unsigned( 6,6), '0'),
    6  => (x"5A", to_unsigned( 7,6), to_unsigned( 7,6), '0'),
    7  => (x"3F", to_unsigned(19,6), to_unsigned( 8,6), '0'),
    8  => (x"2C", to_unsigned(21,6), to_unsigned( 9,6), '0'),
    9  => (x"20", to_unsigned(22,6), to_unsigned(10,6), '0'),
    10 => (x"17", to_unsigned(24,6), to_unsigned(11,6), '0'),
    11 => (x"11", to_unsigned(25,6), to_unsigned(12,6), '0'),
    12 => (x"0C", to_unsigned(26,6), to_unsigned(13,6), '0'),
    13 => (x"09", to_unsigned(28,6), to_unsigned(14,6), '0'),
    14 => (x"07", to_unsigned(29,6), to_unsigned(15,6), '0'),
    15 => (x"05", to_unsigned(31,6), to_unsigned(16,6), '0'),
    16 => (x"04", to_unsigned(32,6), to_unsigned(17,6), '0'),
    17 => (x"03", to_unsigned(34,6), to_unsigned(18,6), '0'),
    18 => (x"02", to_unsigned(35,6), to_unsigned(44,6), '0'),
    19 => (x"5A", to_unsigned(20,6), to_unsigned(20,6), '1'),
    20 => (x"3F", to_unsigned(39,6), to_unsigned(21,6), '0'),
    21 => (x"2C", to_unsigned(40,6), to_unsigned(22,6), '0'),
    22 => (x"20", to_unsigned(42,6), to_unsigned(23,6), '0'),
    23 => (x"17", to_unsigned(44,6), to_unsigned(24,6), '0'),
    24 => (x"11", to_unsigned(45,6), to_unsigned(25,6), '0'),
    25 => (x"0C", to_unsigned(46,6), to_unsigned(26,6), '0'),
    26 => (x"09", to_unsigned(25,6), to_unsigned(27,6), '0'),
    27 => (x"07", to_unsigned(26,6), to_unsigned(28,6), '0'),
    28 => (x"05", to_unsigned(27,6), to_unsigned(29,6), '0'),
    29 => (x"04", to_unsigned(28,6), to_unsigned(30,6), '0'),
    30 => (x"03", to_unsigned(29,6), to_unsigned(31,6), '0'),
    31 => (x"02", to_unsigned(30,6), to_unsigned(32,6), '0'),
    32 => (x"5A", to_unsigned(33,6), to_unsigned(33,6), '1'),
    33 => (x"25", to_unsigned(37,6), to_unsigned(34,6), '0'),
    34 => (x"17", to_unsigned(38,6), to_unsigned(35,6), '0'),
    35 => (x"0C", to_unsigned(40,6), to_unsigned(36,6), '0'),
    36 => (x"07", to_unsigned(41,6), to_unsigned(37,6), '0'),
    37 => (x"03", to_unsigned(43,6), to_unsigned(38,6), '0'),
    38 => (x"01", to_unsigned(44,6), to_unsigned(39,6), '0'),
    39 => (x"5A", to_unsigned(40,6), to_unsigned(40,6), '0'),
    40 => (x"3F", to_unsigned(52,6), to_unsigned(41,6), '0'),
    41 => (x"2C", to_unsigned(52,6), to_unsigned(42,6), '0'),
    42 => (x"20", to_unsigned(52,6), to_unsigned(43,6), '0'),
    43 => (x"17", to_unsigned(52,6), to_unsigned(44,6), '0'),
    44 => (x"11", to_unsigned(52,6), to_unsigned(45,6), '0'),
    45 => (x"0C", to_unsigned(52,6), to_unsigned(45,6), '0'),
    46 => (x"09", to_unsigned(52,6), to_unsigned(46,6), '0'),
    47 => (x"07", to_unsigned(52,6), to_unsigned(47,6), '0'),
    48 => (x"05", to_unsigned(52,6), to_unsigned(48,6), '0'),
    49 => (x"04", to_unsigned(52,6), to_unsigned(49,6), '0'),
    50 => (x"03", to_unsigned(52,6), to_unsigned(50,6), '0'),
    51 => (x"02", to_unsigned(52,6), to_unsigned(51,6), '0'),
    52 => (x"01", to_unsigned(52,6), to_unsigned(52,6), '0')
  );

  -- Context register file type: 8 registers of 8 bits, plus 8 MPS bits
  type t_ctx_state is array(0 to 7) of unsigned(5 downto 0);
  type t_ctx_mps   is array(0 to 7) of std_logic;

end package SPC7110_DEC_PKG;
