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
#include <ctype.h>
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

/* FNV-1a 32-bit hash of the filename basename (up to the last dot), lowercased.
 * Used to match .ips sidecars without per-file f_stat() calls.              */
static uint32_t hash_basename(const TCHAR *fn) {
  const char *dot = strrchr((const char*)fn, '.');
  uint32_t h = 2166136261u;
  for(const TCHAR *c = fn; *c && (const char*)c != dot; c++) {
    h ^= (uint8_t)tolower((unsigned char)*c);
    h *= 16777619u;
  }
  return h;
}

/* Hash table for IPS basenames collected during the single readdir pass.
 * Placed in AHB RAM (separate 16KB bank) to avoid exhausting the 16KB main
 * RAM.  The table is explicitly reset (n_ips_hashes = 0) before each use so
 * the missing BSS zero-init of .ahbram sections is not an issue.            */
#define IPS_HASH_TABLE_SIZE 1024
static uint32_t ips_hash_table[IPS_HASH_TABLE_SIZE] IN_AHBRAM;
static uint16_t n_ips_hashes;

/* Check if fn (read back from SRAM, possibly with hide_extensions '\x01')
 * matches any collected IPS basename hash.                                  */
static uint8_t ips_basename_in_table(const uint8_t *fn) {
  /* find the last '.' or '\x01' (hide_extensions replaces '.' with '\x01') */
  const uint8_t *ext = NULL;
  for(const uint8_t *p = fn; *p; p++) {
    if(*p == '.' || *p == 1) ext = p;
  }
  if(ext == NULL) return 0;
  uint32_t h = 2166136261u;
  for(const uint8_t *c = fn; c != ext; c++) {
    h ^= (uint8_t)tolower((unsigned char)*c);
    h *= 16777619u;
  }
  for(uint16_t i = 0; i < n_ips_hashes; i++) {
    if(ips_hash_table[i] == h) return 1;
  }
  return 0;
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

  n_ips_hashes = 0;

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
      /* collect IPS basenames in-line (all non-hidden, non-dir files)        */
      if(!(fno.fattrib & (AM_DIR | AM_HID | AM_SYS)) && fn[0] != '.') {
        const char *ips_ext = strrchr((const char*)fn, '.');
        if(ips_ext && !strcasecmp(ips_ext + 1, "ips")
           && n_ips_hashes < IPS_HASH_TABLE_SIZE) {
          ips_hash_table[n_ips_hashes++] = hash_basename(fn);
        }
      }
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
  /* Post-pass: mark TYPE_ROM entries whose IPS sidecar was seen above.
   * Operates on already-written SRAM (FPGA SPI, not SD card) so it is fast
   * regardless of directory size. Handles both normal filenames and the
   * hide_extensions case where '.' is replaced with '\x01' in SRAM.        */
  if(n_ips_hashes > 0) {
    uint32_t scan_off = base_addr;
    for(uint16_t i = 0; i < numentries; i++, scan_off += 4) {
      uint32_t entry = sram_readlong(scan_off);
      uint8_t  type  = (uint8_t)(entry >> 24);
      if(type == TYPE_ROM) {
        uint32_t fn_addr = SRAM_MENU_ADDR + (entry & 0x00ffffffu) + 6;
        sram_readstrn(file_lfn, fn_addr, sizeof(file_lfn) - 1);
        if(ips_basename_in_table(file_lfn)) {
          sram_writebyte(TYPE_ROM | TYPE_FLAG_PATCHED, scan_off + 3);
        }
      }
    }
  }
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
