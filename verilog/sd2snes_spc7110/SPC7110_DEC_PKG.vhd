----------------------------------------------------------------------------------
-- SPC7110_DEC_PKG.vhd
-- Faithful port of MiSTer SNES SPC7110 decompressor support package.
-- Types, tables, and helper functions used by SPC7110_DEC.vhd.
-- All values verified against srg320's MiSTer SNES implementation.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package SPC7110_DEC_PKG is

  -- ---------------------------------------------------------------------------
  -- Probability evolution table (53 states, indices 0-52)
  -- MPS/LPS inversion is decided at runtime: when LPS fires and PROB > 0x55,
  -- the context INV flag is toggled (PROB_BIG_HALF logic in SPC7110_DEC).
  -- ---------------------------------------------------------------------------
  type Evol_r is record
    PROB     : unsigned(7 downto 0);
    NEXT_MPS : integer range 0 to 52;
    NEXT_LPS : integer range 0 to 52;
  end record;

  type EvolTbl_t is array(0 to 52) of Evol_r;

  constant EVOL_TBL : EvolTbl_t := (
    (x"5a",  1,  1),  --  0
    (x"25",  2,  6),  --  1
    (x"11",  3,  8),  --  2
    (x"08",  4, 10),  --  3
    (x"03",  5, 12),  --  4
    (x"01",  5, 15),  --  5
    (x"5a",  7,  7),  --  6
    (x"3f",  8, 19),  --  7
    (x"2c",  9, 21),  --  8
    (x"20", 10, 22),  --  9
    (x"17", 11, 23),  -- 10
    (x"11", 12, 25),  -- 11
    (x"0c", 13, 26),  -- 12
    (x"09", 14, 28),  -- 13
    (x"07", 15, 29),  -- 14
    (x"05", 16, 31),  -- 15
    (x"04", 17, 32),  -- 16
    (x"03", 18, 34),  -- 17
    (x"02",  5, 35),  -- 18
    (x"5a", 20, 20),  -- 19
    (x"48", 21, 39),  -- 20
    (x"3a", 22, 40),  -- 21
    (x"2e", 23, 42),  -- 22
    (x"26", 24, 44),  -- 23
    (x"1f", 25, 45),  -- 24
    (x"19", 26, 46),  -- 25
    (x"15", 27, 25),  -- 26
    (x"11", 28, 26),  -- 27
    (x"0e", 29, 26),  -- 28
    (x"0b", 30, 27),  -- 29
    (x"09", 31, 28),  -- 30
    (x"08", 32, 29),  -- 31
    (x"07", 33, 30),  -- 32
    (x"05", 34, 31),  -- 33
    (x"04", 35, 33),  -- 34
    (x"04", 36, 33),  -- 35
    (x"03", 37, 34),  -- 36
    (x"02", 38, 35),  -- 37
    (x"02",  5, 36),  -- 38
    (x"58", 40, 39),  -- 39
    (x"4d", 41, 47),  -- 40
    (x"43", 42, 48),  -- 41
    (x"3b", 43, 49),  -- 42
    (x"34", 44, 50),  -- 43
    (x"2e", 45, 51),  -- 44
    (x"29", 46, 44),  -- 45
    (x"25", 24, 45),  -- 46
    (x"56", 48, 47),  -- 47
    (x"4f", 49, 47),  -- 48
    (x"47", 50, 48),  -- 49
    (x"41", 51, 49),  -- 50
    (x"3c", 52, 50),  -- 51
    (x"37", 43, 51)   -- 52
  );

  -- ---------------------------------------------------------------------------
  -- Mode-2 (4bpp) context transition table (32 entries)
  -- ---------------------------------------------------------------------------
  type Mode2Context_r is record
    NEXT0 : unsigned(4 downto 0);
    NEXT1 : unsigned(4 downto 0);
  end record;

  type Mode2ContextTbl_t is array(0 to 31) of Mode2Context_r;

  constant M2C_TBL : Mode2ContextTbl_t := (
    ("00001", "00010"),  --  0
    ("00011", "01000"),  --  1
    ("01101", "01110"),  --  2
    ("01111", "10000"),  --  3
    ("10001", "10010"),  --  4
    ("10011", "10100"),  --  5
    ("10101", "10110"),  --  6
    ("10111", "11000"),  --  7
    ("11001", "11010"),  --  8
    ("11001", "11010"),  --  9
    ("11001", "11010"),  -- 10
    ("11001", "11010"),  -- 11
    ("11001", "11010"),  -- 12
    ("11011", "11100"),  -- 13
    ("11101", "11110"),  -- 14
    ("11111", "11111"),  -- 15
    ("11111", "11111"),  -- 16
    ("11111", "11111"),  -- 17
    ("11111", "11111"),  -- 18
    ("11111", "11111"),  -- 19
    ("11111", "11111"),  -- 20
    ("11111", "11111"),  -- 21
    ("11111", "11111"),  -- 22
    ("11111", "11111"),  -- 23
    ("11111", "11111"),  -- 24
    ("11111", "11111"),  -- 25
    ("11111", "11111"),  -- 26
    ("11111", "11111"),  -- 27
    ("11111", "11111"),  -- 28
    ("11111", "11111"),  -- 29
    ("11111", "11111"),  -- 30
    ("11111", "11111")   -- 31
  );

  -- ---------------------------------------------------------------------------
  -- Context model: 32 contexts, 5-bit CON index
  -- ---------------------------------------------------------------------------
  type Context_r is record
    INDEX : integer range 0 to 52;  -- evolution table state index
    INV   : std_logic;              -- MPS/LPS inversion flag
  end record;

  type ContextTbl_t is array(0 to 31) of Context_r;

  -- Pixel value reorder table (tracks most-probable pixel ordering)
  type PixelOrder_t is array(0 to 15) of unsigned(3 downto 0);

  -- ---------------------------------------------------------------------------
  -- Helper functions
  -- ---------------------------------------------------------------------------
  function GetProb       (con : unsigned(4 downto 0); conTbl : ContextTbl_t) return unsigned;
  function GetNextLPS    (con : unsigned(4 downto 0); conTbl : ContextTbl_t) return integer;
  function GetNextMPS    (con : unsigned(4 downto 0); conTbl : ContextTbl_t) return integer;
  function GetBitMask    (mode : std_logic_vector(1 downto 0)) return unsigned;
  function GetZeroBitCnt (top  : unsigned(7 downto 0)) return unsigned;
  function GetDiff       (a, b, c : unsigned(3 downto 0)) return unsigned;
  function Reorder       (o : PixelOrder_t; p : unsigned(3 downto 0)) return PixelOrder_t;

end package SPC7110_DEC_PKG;

package body SPC7110_DEC_PKG is

  function GetProb(con : unsigned(4 downto 0); conTbl : ContextTbl_t) return unsigned is
    variable evol : integer range 0 to 52;
  begin
    evol := conTbl(to_integer(con)).INDEX;
    return EVOL_TBL(evol).PROB;
  end function;

  function GetNextLPS(con : unsigned(4 downto 0); conTbl : ContextTbl_t) return integer is
    variable evol : integer range 0 to 52;
  begin
    evol := conTbl(to_integer(con)).INDEX;
    return EVOL_TBL(evol).NEXT_LPS;
  end function;

  function GetNextMPS(con : unsigned(4 downto 0); conTbl : ContextTbl_t) return integer is
    variable evol : integer range 0 to 52;
  begin
    evol := conTbl(to_integer(con)).INDEX;
    return EVOL_TBL(evol).NEXT_MPS;
  end function;

  function GetBitMask(mode : std_logic_vector(1 downto 0)) return unsigned is
    variable res : unsigned(1 downto 0);
  begin
    if    mode = "01" then res := "01";
    elsif mode = "10" then res := "11";
    else                   res := "00";
    end if;
    return res;
  end function;

  function GetZeroBitCnt(top : unsigned(7 downto 0)) return unsigned is
    variable res : unsigned(2 downto 0);
  begin
    if    top(7) = '1' then res := "000";
    elsif top(6) = '1' then res := "001";
    elsif top(5) = '1' then res := "010";
    elsif top(4) = '1' then res := "011";
    elsif top(3) = '1' then res := "100";
    elsif top(2) = '1' then res := "101";
    elsif top(1) = '1' then res := "110";
    else                     res := "111";
    end if;
    return res;
  end function;

  function GetDiff(a, b, c : unsigned(3 downto 0)) return unsigned is
    variable res : unsigned(2 downto 0);
  begin
    if    a = b and b = c  then res := "000";
    elsif a = b and b /= c then res := "001";
    elsif a /= b and b = c then res := "010";
    elsif a = c and b /= c then res := "011";
    else                        res := "100";
    end if;
    return res;
  end function;

  function Reorder(o : PixelOrder_t; p : unsigned(3 downto 0)) return PixelOrder_t is
    variable res : PixelOrder_t;
    variable n   : integer range 0 to 15;
  begin
    n := 0;
    for i in 1 to 15 loop
      if o(i) = p then n := i; end if;
    end loop;
    for i in 1 to 15 loop
      if n >= i then res(i) := o(i-1);
      else           res(i) := o(i);
      end if;
    end loop;
    res(0) := o(n);
    return res;
  end function;

end package body SPC7110_DEC_PKG;
