/* sd2snes debug file logger
   Logs all file_open/file_close calls and file_res transitions to
   /sd2snes/debug.log for post-mortem analysis. */

#ifndef _DBGLOG_H
#define _DBGLOG_H

#include <stdint.h>

void dbglog_init(void);
void dbglog(const char *fmt, ...) __attribute__((format(printf,1,2)));
void dbglog_flush(void);

/* Set a short context string (caller name) printed with each entry.
   Pass NULL to clear. The pointer is kept by reference — must be a
   string literal or a static/stack buffer that outlives the log call. */
void dbglog_set_context(const char *ctx);

#endif /* _DBGLOG_H */
