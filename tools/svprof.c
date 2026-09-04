/* svshot -- drive the REAL Potator core into a level via the port's own title
   level select, then dump sampled frames. Unlike the py65 harness this runs the
   NMI and the IRQ, so it can show artifacts born of their race with the
   renderer (docs/35 E9) -- exactly the class the py65 sweep is blind to.

   Build: cc -O1 -I ~/Dev/potator/common -I ~/Dev/potator/common/m6502 \
              -o /tmp/svshot tools/svshot.c ~/Dev/potator/common/*.c \
              ~/Dev/potator/common/m6502/m6502.c
   Run:   /tmp/svshot rom.sv <selects> <frames> <every> out.bin [ram.bin]
          selects = how many times to tap SELECT at the title (cur_level), then
          START. 5 selects -> level 5 = 2-3.
   Out:   raw uint16 frames, 160*160 each, one per sample. With ram.bin, also
          8192 bytes of $0000-$1FFF per sample, so engine state can be read off
          the REAL core (build/rom.lbl gives the addresses). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "supervision.h"
#include "controls.h"
#include "memorymap.h"

#define START 0x80
#define SELECT 0x40
/* SV pad: RIGHT $01 LEFT $02 DOWN $04 UP $08 B $10 A $20 (src/supervision.inc) */
static uint8 pad_of(char c) {
    switch (c) {
    case 'R': return 0x01; case 'L': return 0x02; case 'D': return 0x04;
    case 'U': return 0x08; case 'B': return 0x10; case 'A': return 0x20;
    /* combinations: you cannot play a walker level one button at a time --
       'J' = run right + jump, 'K' = left + jump, 'F' = right + fire */
    case 'J': return 0x21; case 'K': return 0x22; case 'F': return 0x11; case 'Q': return 0x31; case 'G': return 0x12; case 'H': return 0x32; /* Q=R+A+B G=L+B H=L+A+B */
    default:  return 0x00;
    }
}


/* --- PC profiler (tools/svprof): sample the CPU's PC every IPeriod (256) cycles
   between env PROF_FROM..PROF_TO frames; histogram -> env PROF_OUT ------------ */
#include "m6502.h"
extern byte orig_Loop6502(register M6502 *R);
static unsigned prof_hist[65536]; static int prof_on = 0;
static int prof_alive = -1;
byte Loop6502(register M6502 *R) { if (prof_on) { const uint8 *lr = memorymap_getLowerRamPointer(); if (prof_alive < 0 || (lr[prof_alive] == 0 && lr[0x1B] < 150)) prof_hist[R->PC.W]++; } return orig_Loop6502(R); }
static uint16 fb[160*160];
static void step(int n, uint8 pad) {
    for (int i = 0; i < n; i++) { controls_state_write(pad); supervision_exec_ex(fb, 160, FALSE); }
}
int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: svshot rom sel frames every out.bin [ram.bin] [script]\n"); return 2; }
    int sel = atoi(argv[2]), frames = atoi(argv[3]), every = atoi(argv[4]);
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("rom"); return 2; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *rom = malloc(sz);
    if (fread(rom, 1, sz, f) != (size_t)sz) return 2;
    fclose(f);
    supervision_init();
    if (!supervision_load(rom, (unsigned)sz)) { fprintf(stderr, "load failed\n"); return 2; }
    supervision_reset();
    step(300, 0);                                  /* to the title */
    for (int i = 0; i < sel; i++) { step(3, SELECT); step(10, 0); }
    step(4, START); step(10, 0);
    step(60, 0);                                   /* let the level load */
    FILE *o = fopen(argv[5], "wb");
    FILE *rf = (argc > 6) ? fopen(argv[6], "wb") : NULL;
    int n = 0;
    fwrite(fb, sizeof(uint16), 160*160, o); n++;   /* sample 0 */
    if (rf) fwrite(memorymap_getLowerRamPointer(), 1, 0x2000, rf);
    /* optional input script, e.g. "R120,U60,.40,R200": letter + frame count,
       applied from sample 0 on. The port and the GB are driven by the SAME
       script so the hull's path can be compared directly. */
    const char *script = (argc > 7) ? argv[7] : "";
    const char *sp = script;
    /* optional RAM pokes, argv[8] = "addr:val@frame,addr:val@frame,...": lets a
       scene that normal input cannot reach in a reasonable run (the 2-3 rescue
       is 6000+ frames and a boss fight past the level) be forced directly. */
    const char *pk = (argc > 8) ? argv[8] : "";
    int seg_left = 0; uint8 seg_pad = 0;
    if (getenv("PROF_ALIVE")) prof_alive = (int)strtol(getenv("PROF_ALIVE"), NULL, 0);
    int pf0 = getenv("PROF_FROM") ? atoi(getenv("PROF_FROM")) : 0, pf1 = getenv("PROF_TO") ? atoi(getenv("PROF_TO")) : 1<<30;
    for (int i = 1; i <= frames; i++) {
        prof_on = (i >= pf0 && i <= pf1);
        { const char *q = pk;
          while (*q) {
              int ad = (int)strtol(q, (char **)&q, 0);
              if (*q == ':') q++;
              int vl = (int)strtol(q, (char **)&q, 0);
              int fr = 0;
              if (*q == '@') { q++; fr = (int)strtol(q, (char **)&q, 0); }
              if (fr == i) memorymap_getLowerRamPointer()[ad & 0x1FFF] = (uint8)vl;
              if (*q == ',') q++; else break;
          } }
        while (seg_left == 0 && *sp) {
            seg_pad = pad_of(*sp++);
            seg_left = atoi(sp);
            while (*sp && *sp != ',') sp++;
            if (*sp == ',') sp++;
        }
        if (seg_left > 0) seg_left--; else seg_pad = 0;
        step(1, seg_pad);
        if (i % every == 0) {
            fwrite(fb, sizeof(uint16), 160*160, o); n++;
            if (rf) fwrite(memorymap_getLowerRamPointer(), 1, 0x2000, rf);
        }
    }
    fclose(o);
    if (rf) fclose(rf);
    if (getenv("PROF_OUT")) { FILE *pf = fopen(getenv("PROF_OUT"), "wb"); fwrite(prof_hist, sizeof(unsigned), 65536, pf); fclose(pf); }
    printf("svshot: %d samples of %d frames -> %s\n", n, frames, argv[5]);
    return 0;
}
