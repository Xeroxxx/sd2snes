/* sd2snes debug file logger
   Uses its own FIL handle (dbg_fil) separate from the main file_handle so
   logging never disturbs the state of the main FatFS file object.

   Buffer is placed in AHBRAM (16KB bank, NOLOAD) to avoid bloating BSS.
   Callers MUST call dbglog_flush() to commit buffered lines to the card —
   logging is buffered to keep per-entry overhead low. */

#include "config.h"
#include "dbglog.h"
#include "ff.h"
#include "timer.h"

#include <stdarg.h>
#include <string.h>
#include <stdio.h>

#define DBGLOG_FILE   "/sd2snes/debug.log"
#define DBGLOG_BUFSZ  2048

/* Place the write buffer in AHBRAM so it doesn't eat main-bank BSS.
   Section is NOLOAD so it is NOT zero-initialised — dbglog_init() resets it.
   dbglog_ready lives in normal BSS (zero-initialised) and gates all access
   so that any dbglog() call before dbglog_init() is a safe no-op. */
static char IN_AHBRAM dbglog_buf[DBGLOG_BUFSZ];
static int  IN_AHBRAM dbglog_bufpos;
static const char *dbglog_ctx;
static uint8_t dbglog_ready; /* BSS: zero-initialised, safe to read at any time */

void dbglog_init(void) {
    /* clear the buffer manually (AHBRAM is not zero-initialised) */
    dbglog_bufpos = 0;
    dbglog_ctx    = NULL;
    memset(dbglog_buf, 0, sizeof(dbglog_buf));
    dbglog_ready  = 1;

    /* truncate / create the log file fresh each boot */
    FIL f;
    if(f_open(&f, DBGLOG_FILE, FA_CREATE_ALWAYS | FA_WRITE) == FR_OK) {
        const char hdr[] = "=== sd2snes debug log start ===\r\n";
        UINT bw;
        f_write(&f, hdr, sizeof(hdr)-1, &bw);
        f_close(&f);
    }
}

void dbglog_set_context(const char *ctx) {
    if(!dbglog_ready) return;
    dbglog_ctx = ctx;
}

void dbglog(const char *fmt, ...) {
    if(!dbglog_ready) return;
    char line[256];
    int len;
    va_list args;

    /* prepend tick counter */
    int pre = snprintf(line, sizeof(line), "[%8lu]", (unsigned long)getticks());
    if(dbglog_ctx) {
        pre += snprintf(line+pre, sizeof(line)-pre, "[%s] ", dbglog_ctx);
    } else {
        line[pre++] = ' ';
    }

    va_start(args, fmt);
    len = vsnprintf(line+pre, sizeof(line)-pre, fmt, args);
    va_end(args);
    if(len < 0) return;
    len += pre;
    /* ensure newline */
    if(len < (int)sizeof(line)-2 && (len == 0 || line[len-1] != '\n')) {
        line[len++] = '\r';
        line[len++] = '\n';
    }
    line[len] = '\0';

    /* append to buffer; flush first if full */
    if(dbglog_bufpos + len >= DBGLOG_BUFSZ) {
        dbglog_flush();
    }
    if(len < DBGLOG_BUFSZ) {
        memcpy(dbglog_buf + dbglog_bufpos, line, len);
        dbglog_bufpos += len;
    }
}

void dbglog_flush(void) {
    if(!dbglog_ready || dbglog_bufpos == 0) return;
    /* Static so the 536-byte FIL struct never lands on the stack; deep call
       chains inside load_rom() / yaml parsing would otherwise risk a
       stack-overflow that silently corrupts f_open() and loses log data. */
    static FIL f;
    UINT bw;
    /* FA_OPEN_ALWAYS + seek to end = append */
    if(f_open(&f, DBGLOG_FILE, FA_OPEN_ALWAYS | FA_WRITE) == FR_OK) {
        f_lseek(&f, f_size(&f));
        f_write(&f, dbglog_buf, (UINT)dbglog_bufpos, &bw);
        f_sync(&f);
        f_close(&f);
        dbglog_bufpos = 0; /* only clear buffer when write actually succeeded */
    }
    /* if f_open failed: leave bufpos intact so the next flush can retry */
}
