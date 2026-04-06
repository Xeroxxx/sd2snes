/* sd2snes - SD card based universal cartridge for the SNES
   Copyright (C) 2009-2010 Maximilian Rehkopf <otakon@gmx.net>
   AVR firmware portion

   Inspired by and based on code from sd2iec, written by Ingo Korb et al.
   See sdcard.c|h, config.h.

   FAT file system access based on code by ChaN, Jim Brain, Ingo Korb,
   see ff.c|h.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; version 2 of the License only.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

   fpga.c: FPGA (re)configuration
*/


#include "bits.h"

#include "fpga.h"
#include "fpga_spi.h"
#include "config.h"
#include "uart.h"
#include "diskio.h"
#include "integer.h"
#include "ff.h"
#include "fileops.h"
#include "spi.h"
#include "led.h"
#include "timer.h"
#include "rle.h"
#include "cfgware.h"
#include "dbglog.h"

uint8_t SPI_OFFLOAD;

const uint8_t *fpga_config;
void fpga_set_prog_b(uint8_t val) {
  OUT_BIT(FPGA_PROGBREG, FPGA_PROGBBIT, val);
}

void fpga_set_cclk(uint8_t val) {
  OUT_BIT(FPGA_CCLKREG, FPGA_CCLKBIT, val);
}

int fpga_get_initb() {
  return BITBAND(FPGA_INITBREG->GPIO_I, FPGA_INITBBIT);
}

void fpga_init() {
/* mainly GPIO directions */
  GPIO_MODE_OUT(FPGA_CCLKREG, FPGA_CCLKBIT);   /* CCLK */
  GPIO_MODE_IN(FPGA_DONEREG, FPGA_DONEBIT);    /* DONE */
  GPIO_MODE_OUT(FPGA_PROGBREG, FPGA_PROGBBIT); /* PROG_B */
  GPIO_MODE_OUT(FPGA_DINREG, FPGA_DINBIT);     /* DIN */
  GPIO_MODE_IN(FPGA_INITBREG, FPGA_INITBBIT);  /* INIT_B */

/* pullup inputs */
  GPIO_PULLUP(FPGA_DONEREG, FPGA_DONEBIT);
  GPIO_PULLUP(FPGA_INITBREG, FPGA_INITBBIT);

  SPI_OFFLOAD=0;
  fpga_set_cclk(0);    /* initial clk=0 */
}

int fpga_get_done(void) {
  return BITBAND(FPGA_DONEREG->GPIO_I, FPGA_DONEBIT);
}

void fpga_postinit() {
  GPIO_MODE_IN(FPGA_DINREG, FPGA_DINBIT); /* DATA0 -> MCU_RDY */
}

void fpga_pgm(uint8_t* filename) {
  int MAXRETRIES = 10;
  int retries = MAXRETRIES;
  int attempt = 0;
  uint8_t data;
  int i;
  tick_t timeout;

  dbglog("fpga_pgm: trying %s", filename);
  dbglog_flush();

  /* Test that the bitstream file exists before starting FPGA init.
     Also log the file size — a raw unencoded .bit file is ~1 MB while an
     RLE-encoded one is ~200 KB.  If you see a large size here the file
     has NOT been encoded with utils/rle and will take many minutes. */
  file_open(filename, FA_READ);
  if(file_res) {
    dbglog("fpga_pgm: file open failed res=%d — bitstream missing!", (int)file_res);
    dbglog_flush();
    uart_putc('?');
    uart_putc(0x30+file_res);
    return;
  }
  DWORD bitfile_size = file_handle.fsize;
  file_close();
  dbglog("fpga_pgm: file size=%lu bytes (expected ~100-250KB RLE; if ~1MB+ file is NOT rle-encoded!)",
         (unsigned long)bitfile_size);
  dbglog_flush();

  fpga_init();
  do {
    attempt++;
    printf("fpga_pgm: configuring FPGA, attempts left: %d\n", retries);

    /* ── Phase 1: FPGA reset/init  ─────────────────────────────────────────
       file_handle is CLOSED here so every dbglog_flush() is fully safe.
       We do the entire PROG_B/INIT_B handshake before opening the file so
       that each step can be individually confirmed in the log. */

    dbglog("fpga_pgm: attempt %d/%d — asserting PROG_B low", attempt, MAXRETRIES);
    dbglog_flush(); /* safe: no file open */

    i=0;
    timeout = getticks() + 1;
    fpga_set_prog_b(0);
    while(BITBAND(FPGA_PROGBREG->GPIO_I, FPGA_PROGBBIT)) {
      if(getticks() > timeout) {
        printf("fpga_pgm: PROGB is stuck high!\n");
        dbglog("fpga_pgm: PROGB stuck high on attempt %d — aborting", attempt);
        dbglog_flush(); /* safe: no file open */
        led_panic(LED_PANIC_FPGA_PROGB_STUCK);
      }
    }

    dbglog("fpga_pgm: PROG_B low OK, releasing (waiting for INIT_B high)");
    dbglog_flush(); /* safe */

    timeout = getticks() + 100;
    uart_putc('P');
    fpga_set_prog_b(1);
    while(!fpga_get_initb()){
      if(getticks() > timeout) {
        printf("fpga_pgm: no response from FPGA trying to initiate configuration!\n");
        dbglog("fpga_pgm: no INITB on attempt %d (DONE=%d) — aborting", attempt, (int)fpga_get_done());
        dbglog_flush(); /* safe */
        led_panic(LED_PANIC_FPGA_NO_INITB);
      }
    };

    dbglog("fpga_pgm: INIT_B high OK, waiting for DONE low");
    dbglog_flush(); /* safe */

    timeout = getticks() + 100;
    while(fpga_get_done()) {
      if(getticks() > timeout) {
        printf("fpga_pgm: DONE is stuck high!\n");
        dbglog("fpga_pgm: DONE stuck high at start of attempt %d — aborting", attempt);
        dbglog_flush(); /* safe */
        led_panic(LED_PANIC_FPGA_DONE_STUCK);
      }
    }

    dbglog("fpga_pgm: FPGA ready (PROG_B/INIT_B/DONE OK). Opening bitstream file...");
    dbglog_flush(); /* safe: still no file open — last safe flush before file_open */

    /* ── Re-init SD card before opening bitstream ───────────────────────────
       When the base FPGA is reconfigured (PROG_B above), it may have been in
       the middle of an SD DMA offload read (CMD18 issued by the FPGA logic).
       The MCU's during_blocktrans is TRANS_NONE (the MCU didn't issue that
       command), so it would never send STOP_TRANSMISSION first.  The SD card
       left in an active multi-block-read replies to the MCU's subsequent
       CMD18 with nothing useful, and stream_datablock's start-bit wait
       (which has NO timeout) then hangs forever.
       Sending CMD0 via disk_initialize terminates any pending transfer and
       puts the card back into a known-clean TRANSFER state. */
    dbglog("fpga_pgm: re-initializing SD (FPGA reset may leave SD mid-DMA-transfer)...");
    dbglog_flush(); /* safe: no file open */
    {
      DSTATUS dstat = disk_initialize(0);
      dbglog("fpga_pgm: disk_initialize = 0x%02x (%s)", (unsigned)dstat,
             dstat ? "FAIL — SD not ready" : "OK");
      /* Do NOT call dbglog_flush() here: the first write_block after a fresh
         disk_initialize re-init can trigger the CRC-status turnaround bug
         (fixed in sdnative.c) but we want belt-and-suspenders safety.
         The disk_initialize message is buffered and will be flushed with the
         next safe flush (after file_close of the bitstream). */
      uart_putc('I');  /* raw marker so UART confirms we got past disk_init */
    }

    /* ── Phase 2: open bitstream file and stream ────────────────────────────
       file_handle is OPEN from here until file_close() below.
       Do NOT call dbglog_flush() while file_handle is open — it opens
       debug.log using FatFS which shares fs->win with file_handle and       
       will corrupt the bitstream read state.  Accumulate into buffer only. */

    uart_putc('p');
    file_open(filename, FA_READ);
    if(file_res) {
      dbglog("fpga_pgm: bitstream re-open failed on attempt %d res=%d", attempt, (int)file_res);
      dbglog_flush(); /* safe: f_open failed so file_handle is not valid */
      break;
    }

    dbglog("fpga_pgm: sending bitstream (attempt %d), filesize=%lu...",
           attempt, (unsigned long)file_handle.fsize);
    /* (buffer only — no flush until after file_close) */

    uart_putc('C');
    FPGA_DIN_MASK();
    for (;;) {
      data = rle_file_getc();
      i++;
      if (file_status || file_res) break;   /* error or eof */
      FPGA_SEND_BYTE_SERIAL(data);
      /* accumulate progress every 50000 bytes — no flush, file is open */
      if((i % 50000) == 0) {
        dbglog("fpga_pgm: ...%d bytes sent (DONE=%d)", i, (int)fpga_get_done());
      }
    }
    FPGA_DIN_UNMASK();
    uart_putc('c');

    file_close();
    if(file_res) {
      /* f_close on EOF handle; not a real error */
      dbglog("fpga_pgm: file_close res=%d after attempt %d (ignored)", (int)file_res, attempt);
      file_res = 0;
    }
    printf("fpga_pgm: %d bytes programmed\n", i);
    dbglog("fpga_pgm: attempt %d sent %d bytes, DONE=%d", attempt, i, (int)fpga_get_done());
    dbglog_flush(); /* ── safe: file_handle now closed ── */

    timeout = getticks() + 100;
    while(!fpga_get_done()) {
      if(getticks() > timeout) {
        printf("fpga_pgm: no DONE from FPGA! Retrying\n");
        dbglog("fpga_pgm: no DONE after attempt %d (%d bytes) — retrying", attempt, i);
        dbglog_flush(); /* safe: file closed */
        break;
      }
    }
    CCLK(); CCLK(); CCLK();
    delay_ms(1);
  } while (!fpga_get_done() && retries--);
  if(!fpga_get_done()) {
    printf("fpga_pgm: FPGA failed to configure after %d tries.\n", MAXRETRIES);
    dbglog("fpga_pgm: FAILED to configure after %d attempts", attempt);
    dbglog_flush();
    led_panic(LED_PANIC_FPGA_NOCONF);
  }

  dbglog("fpga_pgm: SUCCESS after %d attempt(s), DONE=1", attempt);
  dbglog_flush();
  printf("FPGA configured\n");
  fpga_config = filename;
  fpga_postinit();
}

void fpga_rompgm() {
  int MAXRETRIES = 10;
  int retries = MAXRETRIES;
  uint8_t data;
  int i;
  tick_t timeout;
  fpga_init();
  do {
    i=0;
    timeout = getticks() + 100;
    fpga_set_prog_b(0);
    uart_putc('P');
    fpga_set_prog_b(1);
    while(!fpga_get_initb()){
      if(getticks() > timeout) {
        printf("no response from FPGA trying to initiate configuration!\n");
        led_panic(LED_PANIC_FPGA_NO_INITB);
      }
    };
    timeout = getticks() + 100;
    while(fpga_get_done()) {
      if(getticks() > timeout) {
        printf("DONE is stuck high!\n");
        led_panic(LED_PANIC_FPGA_DONE_STUCK);
      }
    }
    uart_putc('p');

    /* open configware file */
    rle_mem_init(cfgware, sizeof(cfgware));
    printf("sizeof(cfgware) = %d\n", sizeof(cfgware));
    FPGA_DIN_MASK();
    for (;;) {
      data = rle_mem_getc();
      if(rle_state) break;
      i++;
      FPGA_SEND_BYTE_SERIAL(data);
    }
    FPGA_DIN_UNMASK();
    uart_putc('c');
    printf("fpga_rompgm: %d bytes programmed\n", i);
    delay_ms(1);
  } while (!fpga_get_done() && retries--);
  if(!fpga_get_done()) {
    printf("FPGA failed to configure after %d tries.\n", MAXRETRIES);
    led_panic(LED_PANIC_FPGA_NOCONF);
  }
  printf("FPGA configured\n");
  fpga_config = FPGA_ROM;
  fpga_postinit();
}

