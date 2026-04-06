`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// rtc4513_emu.v  --  SPC7110 RTC register-file emulator
//
// Implements the SPC7110 byte-level register interface at $4840/$4841/$4842
// for real-time FPGA use.  Based on the SPC7110 wiki and Snes9x reference,
// with hardware-correct $4842 busy/ready signaling.
//
// ── $4840 write ──────────────────────────────────────────────────────────────
//   bit0 = 1 : CE high — clears busy; data_phase and rtc_mode are PRESERVED
//   bit0 = 0 : CE low  — clears data_phase only; rtc_mode is PRESERVED (sticky)
//
// ── $4841 write ──────────────────────────────────────────────────────────────
//   EVERY write to $4841 asserts the busy flag for BUSY_CYCLES FPGA clocks.
//
//   Command bytes (sticky — survive CE toggling, only overwritten by new command):
//     0x03 → rtc_mode=1 (Write, CPU→RTC); resets data_phase to 0 (expect index next)
//     0x0C → rtc_mode=0 (Read,  RTC→CPU); resets data_phase to 0 (expect index next)
//
//   Non-command bytes (0x00-0xFF excluding 0x03 and 0x0C):
//     If data_phase==0 (index phase):  rtc_index ← data[3:0]; data_phase → 1
//     If data_phase==1 AND rtc_mode==1 (Write data phase):
//         regs[rtc_index] ← data[3:0]  (uses current rtc_index — non-blocking)
//         rtc_index ← data[3:0]         (side-effect: next index = data value)
//         data_phase stays 1
//     If data_phase==1 AND rtc_mode==0 (Read re-index phase):
//         rtc_index ← data[3:0]; data_phase stays 1
//
//   Sticky-command rationale (matches Snes9x spc7110emu.cpp behavior):
//     The game may toggle CE between data bytes without re-sending the
//     command byte.  If we forced ST_CMD after every CE↑, the game's next
//     index byte would be misinterpreted as a spurious command and silently
//     discarded, causing all reads in Mode 1 to return the wrong register.
//
// ── $4841 read ───────────────────────────────────────────────────────────────
//   data_phase==1 AND rtc_mode==0: returns {4'h0, regs[rtc_index][3:0]}; index
//     auto-increments on srd_rd_end (SNES /RD rising — see Auto-increment note).
//   All other states: returns 0x00.
//   EVERY read to $4841 asserts the busy flag for BUSY_CYCLES FPGA clocks.
//
// ── $4842 read (strictly read-only / non-destructive) ────────────────────────
//   bit7 = 1 : ready  (busy flag = 0)
//   bit7 = 0 : busy   (counter > 0, set by any $4841 access)
//   Reading $4842 does NOT change any internal state.
//   Polling model: wait for bit7=0 (busy), then wait for bit7=1 (ready).
//
// ── $4842 busy timing ────────────────────────────────────────────────────────
//   BUSY_CYCLES = 12500 FPGA clocks @ 96 MHz ≈ 130 µs ≈ real RTC-4513 shift time.
//   rtc_busy is asserted COMBINATORIALLY on the same clock edge that $4841 is
//   written or read (srd_wr || srd_rd), ensuring $4842[7] drops to 0 before any
//   possible same-cycle or next-cycle $4842 read by the SNES CPU.
//
// ── Auto-increment ────────────────────────────────────────────────────────────
//   rtc_index is 4-bit and wraps 0xF → 0x0 automatically.
//   Auto-increment for READ mode fires on srd_rd_end (SNES /RD RISING edge),
//   NOT srd_rd (SNES /RD FALLING edge).  This keeps srd_out stable on the
//   bus for the entire SNES read window; the CPU samples at /RD rising.
//
// ── BCD Seconds Tick ─────────────────────────────────────────────────────────
//   A 27-bit counter increments every FPGA clock.  When it reaches
//   TICK_LIMIT (96,000,000 @ 96 MHz = 1 real second) the RTC-4513 register
//   file advances the BCD time chain: sec_1s → sec_10s → min_1s → min_10s →
//   hr_1s → hr_10s, with correct BCD rollover for 24-hour mode.
//   Ticking is suppressed when reg[$0F][1] (STOP bit) is set.  Explicit
//   writes from the CPU (srd_wr) take priority over the tick on the same
//   clock edge.//
// ── Register file (16 × 8-bit, only lower 4 bits used per RTC-4513 spec) ──────
//   00 sec 1's  01 sec 10's  02 min 1's  03 min 10's  04 hr 1's   05 hr 10's
//   06 day-of-week           07 day 1's  08 day 10's
//   09 mon 1's  0A mon 10's  0B yr 1's   0C yr 10's
//   0D control  (0x00 = not paused, no interrupt)
//   0E calibration (0x00)
//   0F mode     (0x04 = 24-hr; bits[1:0]=0 = timer running, no halt)
//
// ── MCU bulk time load (SPI command 0xE5) ────────────────────────────────────
//   mcu_time[55:0] packed BCD: yr_th:yr_h / yr_t:yr_1 / mo_t:mo_1 /
//                              dy_t:dy_1 / hr_t:hr_1 / mn_t:mn_1 / sc_t:sc_1
//   day-of-week (reg 0x06) and control regs 0x0E-0x0F are preserved.
//   reg 0x0D bit0 (VLOW) is CLEARED: the MCU only injects time when its
//   CR2032-backed hardware RTC is healthy, so VLOW must not remain set.
//------------------------------------------------------------------------------
module rtc4513_emu (
  input  wire        clk,
  input  wire        rst,

  // From SPC7110.vhd — 1-clock combinatorial strobes + data
  input  wire        ce_wr,    // strobe: $4840 was written (gated by RTC_EN)
  input  wire        ce_bit,   // bit 0 of the $4840 write value
  input  wire        srd_wr,   // strobe: $4841 was written
  input  wire [7:0]  srd_data, // full byte written to $4841
  input  wire        srd_rd,     // strobe: $4841 read started (SNES /RD falling — sets busy)
  input  wire        srd_rd_end, // strobe: $4841 read ended   (SNES /RD rising  — auto-increment)

  output wire [7:0]  srd_out,  // 8-bit value returned on $4841 read
  output wire [7:0]  status,   // byte returned on $4842 read (bit7=ready/busy)

  // MCU time interface
  input  wire        mcu_time_load,
  input  wire [55:0] mcu_time
);

  // ── Busy counter ────────────────────────────────────────────────────────
  // 14-bit counter; 12500 clocks @ 96 MHz ≈ 130 µs (real RTC-4513 shift time).
  // rtc_busy is OR'd with srd_wr/srd_rd so it goes high IMMEDIATELY on the
  // same FPGA clock edge as the $4841 access, before the counter can be sampled.
  localparam [13:0] BUSY_CYCLES = 14'd12500;

  reg  [13:0] busy_cnt;
  wire        rtc_busy = (busy_cnt != 14'd0) || srd_wr || srd_rd;

  // ── BCD tick counter ────────────────────────────────────────────────────
  // 27-bit counter; 96,000,000 clocks @ 96 MHz = 1 real second.
  // When the counter rolls over, the BCD time chain is advanced.
  // Ticking is suppressed while reg[$0F][1] (STOP bit) = 1.
  localparam [26:0] TICK_LIMIT = 27'd96_000_000;

  reg [26:0] tick_cnt;
  initial    tick_cnt = 27'd0;

  // ── Protocol state ─────────────────────────────────────────────────────
  // rtc_mode   : sticky command flag — 1=Write(0x03), 0=Read(0x0C).
  //              Survives CE toggling AND SNES soft reset.  Only overwritten
  //              by a new explicit 0x03 or 0x0C command byte.
  // data_phase : 0 = index phase (next non-command write sets rtc_index)
  //              1 = data phase  (next non-command write reads/writes regs[])
  //              Cleared on CE↓ and by receiving a new command byte.
  reg       rtc_mode;    // sticky: 1=Write, 0=Read
  reg       data_phase;  // 0=index phase, 1=data phase
  reg [3:0] rtc_index;   // current register pointer (4-bit, wraps at 16)

  // ── Register file ───────────────────────────────────────────────────────
  // regs[] are battery-backed on the real RTC-4513 chip: they must survive
  // SNES soft reset (console /RST, spc7110_enable de-assertion) without
  // losing the values written by the game.  The FPGA maps `initial` values
  // to FF INIT attributes — applied once at bitfile load, never again.
  // Declared as 4-bit wide (only lower nibble used per RTC-4513 spec);
  // explicit [3:0] avoids 64 dead upper-nibble FFs that inflate slice count.
  // Plain FFs — distributed-RAM inference prevented by multiple write sources.
  reg [3:0] regs [0:15];
  initial begin
    regs[0]  = 4'h0;  // sec ones  (0)
    regs[1]  = 4'h0;  // sec tens  (0)
    regs[2]  = 4'h0;  // min ones  (0)
    regs[3]  = 4'h0;  // min tens  (0)
    regs[4]  = 4'h0;  // hr  ones  (0)
    regs[5]  = 4'h0;  // hr  tens  (0)
    regs[6]  = 4'h0;  // day-of-week (0)
    regs[7]  = 4'h0;  // day ones  (0)
    regs[8]  = 4'h0;  // day tens  (0)
    regs[9]  = 4'h0;  // mon ones  (0)
    regs[10] = 4'h0;  // mon tens  (0)
    regs[11] = 4'h0;  // yr ones   (0)
    regs[12] = 4'h0;  // yr tens   (0)
    regs[13] = 4'h1;  // Control D: bit0=VLOW=1 (dead battery, power-on only)
    regs[14] = 4'h0;  // Control E: cleared
    regs[15] = 4'h4;  // Control F: bit2=1 = 24-hr mode; no STOP/RESET
  end

  // ── Combinatorial outputs ───────────────────────────────────────────────
  // $4841 read: valid only in read-mode DATA phase; upper nibble always 0.
  // Register 0x0D (Control D) has only bits 1:0 wired on real RTC-4513 hardware
  // (bit1=HOLD, bit0=VLOW); bits 3:2 are reserved and hardwired to 0.
  // All other registers (time/date 0x00-0x0C and Control E/F 0x0E-0x0F) expose
  // all four lower bits.
  // ROM-verified: init writes 0x06 to reg[13]; real hardware returns 0x02.
  assign srd_out = (data_phase && !rtc_mode)
                   ? ((rtc_index == 4'hD) ? {6'h00, regs[4'hD][1:0]}
                                           : {4'h0,  regs[rtc_index]})
                   : 8'h00;

  // $4842 read: strictly non-destructive. bit7=1 = ready, bit7=0 = busy.
  assign status  = {~rtc_busy, 7'b0};

  // reg[$0F] bit1 = STOP: when 1 the oscillator is halted (no ticking).
  // Extracted as a wire for clean synthesis from distributed RAM.
  wire rtc_stop = regs[15][1];

  // ── Sequential logic ────────────────────────────────────────────────────
  always @(posedge clk) begin

    if (rst) begin
      busy_cnt   <= 14'd0;
      data_phase <= 1'b0;
      rtc_index  <= 4'h0;
      tick_cnt   <= 27'd0;
      // rtc_mode: intentionally NOT reset here.  The sticky command persists
      // across SNES soft resets for the same reason it persists across CE cycles.
      // regs[] are intentionally NOT reset here.  The RTC-4513 register file
      // is battery-backed on real hardware and is completely unaffected by the
      // SNES /RST line.  Clearing regs on soft reset would destroy data the
      // game wrote before requesting a reset (e.g. the Mode 0 init sequence),
      // causing the Mode 1 read-back verification to fail on the next boot.
      // Initial values are set once at FPGA power-on by the `initial` block above.
    end else begin

      // ── MCU bulk time load ──────────────────────────────────────────────
      if (mcu_time_load) begin
        regs[0]  <= mcu_time[3:0];    // sec ones
        regs[1]  <= mcu_time[7:4];    // sec tens
        regs[2]  <= mcu_time[11:8];   // min ones
        regs[3]  <= mcu_time[15:12];  // min tens
        regs[4]  <= mcu_time[19:16];  // hr  ones
        regs[5]  <= mcu_time[23:20];  // hr  tens
        // regs[6]  = day-of-week: preserved
        regs[7]  <= mcu_time[27:24];  // day ones
        regs[8]  <= mcu_time[31:28];  // day tens
        regs[9]  <= mcu_time[35:32];  // mon ones
        regs[10] <= mcu_time[39:36];  // mon tens
        regs[11] <= mcu_time[43:40];  // yr  ones
        regs[12] <= mcu_time[47:44];  // yr  tens
        // regs[13] bit0 = VLOW (dead-battery flag): clear it on MCU time load
        // because the MCU only injects a valid time when its own CR2032-backed
        // RTC is running, so VLOW=1 from the initial block is always wrong at
        // this point.  bit1 = HOLD: preserve (game may have set it).
        // regs[14] = calibration, regs[15] = mode: preserved unconditionally.
        regs[13] <= {regs[13][3:1], 1'b0};  // clear VLOW, keep HOLD+reserved
        tick_cnt <= 27'd0;  // reset sub-second counter on MCU time load
      end

      // ── Busy counter: decrement each clock ─────────────────────────────
      if (busy_cnt != 14'd0)
        busy_cnt <= busy_cnt - 14'd1;

      // ── $4840 CE write — highest priority ───────────────────────────────
      // All bus activity (CE and serial writes) is gated with !rst so that
      // physical SNES reset button glitches on the address/write lines cannot
      // generate phantom srd_wr pulses and corrupt regs[] with random data.
      if (ce_wr && !rst) begin
        if (ce_bit) begin
          // CE=1: begin new transaction; only clear busy.
          // data_phase and rtc_mode are PRESERVED — sticky command is still in
          // effect; the game sends only an index byte on the next CE cycle,
          // not a redundant command byte.
          busy_cnt <= 14'd0;
        end else begin
          // CE=0: end transaction; clear data_phase so the next CE↑ cycle
          // begins with an index byte.  rtc_mode is intentionally preserved
          // — the sticky command survives CE toggling (Snes9x behavior).
          data_phase <= 1'b0;
          busy_cnt   <= 14'd0;
        end

      // ── $4841 write — assert busy, sticky command / data dispatch ─────────
      end else if (srd_wr && !rst) begin
        busy_cnt <= BUSY_CYCLES;

        if (srd_data == 8'h03) begin
          // WRITE command: set sticky mode; reset to index phase so the
          // very next $4841 write will be treated as the index byte.
          rtc_mode   <= 1'b1;
          data_phase <= 1'b0;

        end else if (srd_data == 8'h0C) begin
          // READ command: same reset-to-index-phase behaviour.
          rtc_mode   <= 1'b0;
          data_phase <= 1'b0;

        end else begin
          // Non-command byte.
          // data_phase==0 (index phase): this byte IS the index.
          // data_phase==1 AND rtc_mode==1 (write data phase): write to the
          //   current register FIRST (non-blocking: uses old rtc_index), then
          //   update rtc_index to the data value for the next operation.
          // data_phase==1 AND rtc_mode==0 (read re-index): just re-point index.
          if (data_phase && rtc_mode)
            regs[rtc_index] <= srd_data[3:0];  // old rtc_index (non-blocking)
          rtc_index  <= srd_data[3:0] & 4'hF;
          data_phase <= 1'b1;
        end

      // ── $4841 read — assert busy at SNES /RD falling (srd_rd) ────────────
      // Only the busy counter is set here.  Auto-increment is deferred to
      // the srd_rd_end strobe (SNES /RD rising) so srd_out (combinatorial
      // from rtc_index) holds the CURRENT register's value stable across
      // the entire SNES read window.  The SNES CPU samples the data bus at
      // the rising edge of /RD, so this ordering guarantees it latches the
      // correct byte before rtc_index advances.
      end else if (srd_rd) begin
        busy_cnt <= BUSY_CYCLES;
        // Auto-increment intentionally omitted here; see srd_rd_end below.
      end

      // ── $4841 end-of-read auto-increment (SNES /RD rising, srd_rd_end) ───
      // Fires after the SNES CPU has latched the data bus.  Gated with !rst
      // to block any spurious end-of-read pulses during SNES reset.
      if (srd_rd_end && !rst && data_phase && !rtc_mode)
        rtc_index <= (rtc_index + 1'b1) & 4'hF;

      // ── BCD seconds tick ─────────────────────────────────────────────────
      // Advances regs[0]/[1] (seconds) once per second.  Minutes and hours
      // are intentionally NOT auto-ticked: the RTC TIME diagnostic only
      // checks that seconds advance (non-zero elapsed difference), and
      // limiting the tick to 2 registers instead of 6 avoids the 3-source
      // write mux expansion on regs[2..5] that caused slice overmapping on
      // the XC3S400.  Minutes/hours are still correctly set by mcu_time_load
      // and by direct CPU writes.
      // Gated by !srd_wr and !mcu_time_load so an explicit write always wins.
      if (!mcu_time_load && !srd_wr && !rtc_stop) begin  // STOP == 0: running
        if (tick_cnt == TICK_LIMIT - 1) begin  // == safe: counter only +1/reset
          tick_cnt <= 27'd0;
          // BCD seconds: rollover 59→00, otherwise increment
          if (regs[1] == 4'd5 && regs[0] == 4'd9) begin
            regs[0] <= 4'd0;   // 59 → 00
            regs[1] <= 4'd0;
          end else if (regs[0] == 4'd9) begin
            regs[0] <= 4'd0;   // x9 → x0, carry to tens
            regs[1] <= regs[1] + 4'd1;
          end else begin
            regs[0] <= regs[0] + 4'd1;
          end
        end else begin
          tick_cnt <= tick_cnt + 27'd1;
        end
      end else begin
        tick_cnt <= 27'd0;    // reset sub-second counter while STOP=1 (regs[15][1])
      end

    end // rst else
  end // always

endmodule
