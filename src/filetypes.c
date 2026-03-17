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

   filetypes.c: directory scanning and file type detection
*/

#include <string.h>
#include "config.h"
#include "uart.h"
#include "filetypes.h"
#include "ff.h"
#include "smc.h"
#include "fileops.h"
#include "crc.h"
#include "memory.h"
#include "led.h"
#include "sort.h"
#include "cfg.h"

#include "timer.h"

extern cfg_t CFG;

static uint8_t build_sidecar_filename(char *dst, size_t dstsize, const uint8_t *path, const TCHAR *filename, const char *extension) {
  int written;
  char *dot;

  written = snprintf(dst, dstsize, "%s%s%s", path, strcmp((const char*)path, "/") ? "/" : "", filename);
  if(written < 0 || (size_t)written >= dstsize) {
    return 0;
  }
  dot = strrchr(dst, '.');
  if(dot == NULL) {
    return 0;
  }
  written = snprintf(dot, dstsize - (size_t)(dot - dst), "%s", extension);
  return written > 0 && (size_t)written < (dstsize - (size_t)(dot - dst));
}

static uint8_t rom_supports_ips_patch(const TCHAR *filename) {
  const char *ext = strrchr((const char*)filename, '.');

  if(ext == NULL) {
    return 0;
  }
  ext++;
  return !strcasecmp(ext, "SMC")
      || !strcasecmp(ext, "SFC")
      || !strcasecmp(ext, "FIG")
      || !strcasecmp(ext, "SWC");
}

static uint8_t rom_has_ips_patch(const uint8_t *path, const TCHAR *filename) {
  FILINFO patch_info;
  char ipsfile[256];

  if(!rom_supports_ips_patch(filename)) {
    return 0;
  }
  if(!build_sidecar_filename(ipsfile, sizeof(ipsfile), path, filename, ".ips")) {
    return 0;
  }
  patch_info.lfname = NULL;
  return f_stat((TCHAR*)ipsfile, &patch_info) == FR_OK && !(patch_info.fattrib & AM_DIR);
}

/*
 * directory format:
 *  I. Pointer tables
 *      3 bytes   pointer to file entry
 *      1 byte    type of entry
 *                (see enum SNES_FTYPE in filetypes.h)
 *
 * II. File entries
 *      6 bytes   size string (e.g. " 1024k")
 *      n bytes   file/dir name
 */

uint16_t scan_dir(const uint8_t *path, const uint32_t base_addr, const SNES_FTYPE *filetypes) {
  DIR dir;
  FRESULT res;
  FILINFO fno;
  TCHAR *fn;
  uint32_t ptr_tbl_off = base_addr;
  uint32_t file_tbl_off = base_addr + 0x10000;
  char buf[7];
  size_t fnlen;

  fno.lfsize = 255;
  fno.lfname = (TCHAR*)file_lfn;
  res = f_opendir(&dir, (TCHAR*)path);
printf("opendir res=%d\n", res);
  uint16_t numentries = 0;
  int ticks=getticks();
  SNES_FTYPE type;
  uint8_t entry_type;
printf("start\n");
  if (res == FR_OK) {
    for (;;) {
      res = f_readdir(&dir, &fno);
      if(res != FR_OK || fno.fname[0] == 0 || numentries >= 16000)break;
      fn = *fno.lfname ? fno.lfname : fno.fname;
      type = determine_filetype(fno);
      if(is_requested_filetype(type, filetypes)) {
        switch(type) {
          case TYPE_ROM:
          case TYPE_SPC:
          case TYPE_SUBDIR:
          case TYPE_PARENT:
            /* omit entries with hidden or system attribute */
            if(fno.fattrib & (AM_HID | AM_SYS)) continue;
            entry_type = type;
            if(fno.fattrib & AM_DIR) {
              /* omit dot directories except '..' */
              if(fn[0]=='.' && fn[1]!='.') continue;
              /* omit sd2snes directory specifically */
              if(strstr(fn, "sd2snes")) continue;
              snprintf(buf, sizeof(buf), " <dir>");
            } else {
              if(fn[0]=='.') continue; /* omit dot files */
              if(type == TYPE_ROM && rom_has_ips_patch(path, fn)) {
                entry_type |= TYPE_FLAG_PATCHED;
              }
              make_filesize_string(buf, fno.fsize);
              if(CFG.hide_extensions) {
                *(strrchr(fn, '.')) = 1;
              }
            }
            fnlen = strlen(fn);
            if(fno.fattrib & AM_DIR) {
              fn[fnlen] = '/';
              fn[fnlen+1] = 0;
              fnlen++;
            }
            /* write file size string */
            sram_writeblock(buf, file_tbl_off, 6);
            /* write file name string (leaf) */
            sram_writeblock(fn, file_tbl_off+6, fnlen+1);
            /* link file string entry in directory table */
            sram_writelong((file_tbl_off-SRAM_MENU_ADDR) | ((uint32_t)entry_type << 24), ptr_tbl_off);
            file_tbl_off += fnlen+7;
            ptr_tbl_off += 4;
            numentries++;
            break;
          case TYPE_UNKNOWN:
          default:
            break;
        }
      }
    }
  }
  /* write directory termination */
  sram_writelong(0, ptr_tbl_off);
  if(CFG.sort_directories) {
    sort_dir(SRAM_DIR_ADDR, numentries);
  }
printf("end\n");
printf("%d entries, time: %d\n", numentries, getticks()-ticks);
  f_closedir(&dir);
  return numentries;
}

SNES_FTYPE determine_filetype(FILINFO fno) {
  char* ext;
  if(fno.fattrib & AM_DIR) {
    if(!strcmp(fno.fname, "..")) {
      return TYPE_PARENT;
    }
    return TYPE_SUBDIR;
  }
  ext = strrchr(fno.fname, '.');
  if(ext == NULL)
    return TYPE_UNKNOWN;
  if(  (!strcasecmp(ext+1, "SMC"))
     ||(!strcasecmp(ext+1, "SFC"))
     ||(!strcasecmp(ext+1, "FIG"))
     ||(!strcasecmp(ext+1, "SWC"))
     ||(!strcasecmp(ext+1, "BS"))
     ||(!strcasecmp(ext+1, "GB"))
     ||(!strcasecmp(ext+1, "GBC"))
     ||(!strcasecmp(ext+1, "SGB"))
    ) {
    return TYPE_ROM;
  }
/*  if(  (!strcasecmp(ext+1, "IPS"))
     ||(!strcasecmp(ext+1, "UPS"))
    ) {
    return TYPE_IPS;
  }*/
  if(!strcasecmp(ext+1, "SPC")) {
    return TYPE_SPC;
  }
  if(!strcasecmp(ext+1, "CHT")) {
    return TYPE_CHT;
  }
  if(!strcasecmp(ext+1, "SKIN")) {
    return TYPE_SKIN;
  }
  return TYPE_UNKNOWN;
}

int get_num_dirent(uint32_t addr) {
  int result = 0;
  while(sram_readlong(addr+result*4)) {
    result++;
  }
  return result;
}

void sort_all_dir(uint32_t endaddr) {
  uint32_t entries = 0;
  uint32_t current_base = SRAM_DIR_ADDR;
  while(current_base<(endaddr)) {
    while(sram_readlong(current_base+entries*4)) {
      entries++;
    }
    int ticks=getticks();
    printf("sorting dir @%lx, entries: %ld, time: ", current_base, entries);
    sort_dir(current_base, entries);
    printf("%d\n", getticks()-ticks);
    current_base += 4*entries + 4;
    entries = 0;
  }
}

void make_filesize_string(char *buf, uint32_t size) {
  char *size_units[3] = {" ", "k", "M"};
  uint32_t fsize = size;
  uint8_t unit_idx = 0;
  while(fsize > 9999) {
    fsize >>= 10;
    unit_idx++;
  }
  snprintf(buf, 6, "% 5ld", fsize);
  strncat(buf, size_units[unit_idx], 1);
}

int is_requested_filetype(SNES_FTYPE type, const SNES_FTYPE *filetypes) {
  return strchr((const char*)filetypes, (int)type) != NULL;
}