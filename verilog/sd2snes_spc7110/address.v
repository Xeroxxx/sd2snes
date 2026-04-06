`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// address.v - SPC7110 Address Decoder
//
// Handles the SPC7110 memory map for sd2snes:
//
// PROM ($C0-$CF:$0000-$FFFF, $80-$BF:$8000-$FFFF, $00-$3F:$8000-$FFFF mirror):
//     PSRAM {1'b0, ~SNES_ADDR[23], SNES_ADDR[21:0]} & ROM_MASK
//
//   DROM ($D0-$DF/$E0-$EF/$F0-$FF, bank-mapped via $4831-$4833):
//     Decoded in SPC7110.vhd / SPC7110Map.vhd; this module marks access as ROM_HIT.
//
//   SRAM ($00-$3F:$6000-$7FFF,  $80-$BF:$6000-$7FFF):
//     PSRAM $E00000 + (SNES_ADDR & SAVERAM_MASK)
//     Enabled only when reg_$4830[0] is asserted (SRAM_ENABLE).
//
//   SPC7110 Registers ($00|$80 bank, $4800-$484F):
//     Intercepted by SPC7110.vhd — NOT a PSRAM access.
//
//   Decompressed data ($50:$0000-$FFFF):
//     Intercepted by SPC7110.vhd — NOT a PSRAM access.
//
// SAVERAM lives at PSRAM $E00000 (matching all other sd2snes cores).
//////////////////////////////////////////////////////////////////////////////////
module address(
  input  [15:0] featurebits,    // peripheral enable/disable
  input  [23:0] SNES_ADDR,      // requested address from SNES
  input   [7:0] SNES_PA,        // peripheral address ($4200-$43FF range)
  input         SNES_ROMSEL,    // active-low ROM select from SNES
  output [23:0] ROM_ADDR,       // Address to request from PSRAM
  output        ROM_HIT,        // enable PSRAM
  output        IS_SAVERAM,     // address mapped as SRAM?
  output        IS_ROM,         // address mapped as ROM?
  output        IS_WRITABLE,    // address mapped as writable?
  input  [23:0] SAVERAM_MASK,
  input  [23:0] ROM_MASK,
  output        msu_enable,
  output        r213f_enable,
  output        r2100_hit,
  output        snescmd_enable,
  output        nmicmd_enable,
  output        return_vector_enable,
  output        branch1_enable,
  output        branch2_enable,
  output        branch3_enable
);

/* SPC7110 feature bit position in featurebits (see fpga_spi.h FEAT_SPC7110 = bit 14) */
parameter [2:0]
  FEAT_MSU1 = 3,
  FEAT_213F = 4
;

//--------------------------------------------------------------------
// Classification of each region
//--------------------------------------------------------------------

// PROM: $C0-$CF full 64KB each; $80-$BF upper 32KB ($8000-$FFFF);
//       and standard HiROM mirror $00-$3F:$8000-$FFFF.
//       Bit 22 is 0 for both $00-$3F and $80-$BF, 1 for $40-$7F and $C0-$FF.
wire is_prom_full  = (SNES_ADDR[23:20] == 4'hC);
wire is_prom_hi    = (SNES_ADDR[22] == 1'b0) && SNES_ADDR[15];  // $00-$3F + $80-$BF, $8000-$FFFF

// DROM: $D0-$FF (three 16-bank windows, bank-mapped by $4831-$4833)
wire is_drom       = (SNES_ADDR[23:20] == 4'hD) ||
                     (SNES_ADDR[23:20] == 4'hE) ||
                     (SNES_ADDR[23:20] == 4'hF);

// SPC7110 registers: $00 bank + $80 mirror, address $4800-$487F
// (matches spc7110_reg_enable in main.v)
wire is_spc_reg    = (SNES_ADDR[22]   == 1'b0)  &&  // bank $00-$3F or $80-$BF (bit22=0)
                     (SNES_ADDR[15:8] == 8'h48) &&  // $4800-$48FF
                     (SNES_ADDR[7]    == 1'b0);      // limit to $4800-$487F

// Decompressed data: bank $50
wire is_decomp     = (SNES_ADDR[23:16] == 8'h50);

// SRAM: $00-$3F:$6000-$7FFF  and  $80-$BF:$6000-$7FFF
// Pattern: SNES_ADDR[22]=0 (not $40-$7F or $C0-$FF), A[15:13]=011 ($6000-$7FFF)
wire is_sram       = (SNES_ADDR[22] == 1'b0) && (SNES_ADDR[15:13] == 3'b011);

//--------------------------------------------------------------------
// IS_ROM: any PROM or DROM access requires PSRAM bus
//--------------------------------------------------------------------
assign IS_ROM     = is_prom_full | is_prom_hi | is_drom;

//--------------------------------------------------------------------
// IS_SAVERAM / IS_WRITABLE
//--------------------------------------------------------------------
assign IS_SAVERAM = is_sram;
assign IS_WRITABLE = is_sram;

//--------------------------------------------------------------------
// ROM_HIT: PSRAM needed for PROM/DROM/SRAM (SPC7110 regs handled inside chip)
//--------------------------------------------------------------------
assign ROM_HIT    = IS_ROM | IS_SAVERAM;

//--------------------------------------------------------------------
// ROM_ADDR computation
// PROM: {1'b0, ~SNES_ADDR[23], SNES_ADDR[21:0]} & ROM_MASK
//       (folds $00-$3F mirrors to same locations as $80-$BF)
// DROM: bank-mapped in SPC7110Map.vhd; expose raw SNES addr here,
//       SPC7110Map will override with {bank, SNES_A[19:0]}.
// SRAM: PSRAM $E00000 + (offset & SAVERAM_MASK)
//--------------------------------------------------------------------
wire [23:0] sram_psram_addr = 24'hE00000 + (SNES_ADDR[20:0] & SAVERAM_MASK[20:0]);
// SPC7110 HiROM PROM is exactly 1MB ($C0-$CF × 64KB).
// All three mirror groups ($C0-$CF, $80-$8F, $00-$0F) share the same bits[19:0]:
//   bits[19:16] = bank index within PROM (0-15), bits[15:0] = offset within bank.
// Using bits[19:0] directly maps all mirrors to the same PSRAM[0-1MB] range.
wire [23:0] prom_psram_addr = ({4'b0000, SNES_ADDR[19:0]}) & ROM_MASK;

assign ROM_ADDR = IS_SAVERAM  ? sram_psram_addr :
                  IS_ROM      ? prom_psram_addr  :
                                SNES_ADDR;

//--------------------------------------------------------------------
// Peripheral / special-purpose signals (same pattern as SDD1 core)
//--------------------------------------------------------------------
assign msu_enable = featurebits[FEAT_MSU1] && ({SNES_ADDR[23], SNES_ADDR[22:0]} == 24'h002000);

assign r213f_enable = featurebits[FEAT_213F] && (SNES_PA == 8'h3f);

assign r2100_hit = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h02100);

// snescmd buffer: $002A00-$002AFF (NMI hook area)
assign snescmd_enable = ({SNES_ADDR[22], SNES_ADDR[15:8]} == 10'h02A);

assign nmicmd_enable  = (SNES_ADDR == 24'h002BFE);

assign return_vector_enable = (SNES_ADDR == 24'h002BFF);

assign branch1_enable = (SNES_ADDR == 24'h002BFD);
assign branch2_enable = (SNES_ADDR == 24'h002BFC);
assign branch3_enable = (SNES_ADDR == 24'h002BFB);

endmodule
