/* svrun -- headless Potator. Runs the REAL emulator core (the same C sources
   the user's RetroArch core is built from), not our py65 model, and hashes the
   framebuffer. Use it to check anything the py65 harness cannot be the
   authority on -- the mapper, register semantics, LCD behaviour.

   Build:  cc -O1 -I ~/Dev/potator/common -I ~/Dev/potator/common/m6502 \
               -o /tmp/svrun tools/svrun.c ~/Dev/potator/common/*.c \
               ~/Dev/potator/common/m6502/m6502.c
   Run:    /tmp/svrun build/super-mario-land.sv 300

   It boots, runs N frames, presses START (bit7; controls_state_write is
   ACTIVE-HIGH, controls_read inverts) and plays 400 more, so the hash covers
   load_level's bank switch and a level's own bank -- not just the boot.

   Proved the 512K MAGNUM conversion pixel-identical to the 128K build:
   both hash 88328a5a. RULE 5: the ROM it reads is gitignored; this file is not. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "supervision.h"
#include "memorymap.h"
#include "controls.h"

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: svrun rom.sv frames\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("rom"); return 2; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *rom = malloc(sz);
    if (fread(rom, 1, sz, f) != (size_t)sz) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);
    printf("rom %ld bytes (MAGNUM expected: %s)\n", sz, sz > 131072 ? "YES" : "no");
    supervision_init();
    if (!supervision_load(rom, (unsigned)sz)) { fprintf(stderr, "load failed\n"); return 2; }
    supervision_reset();
    static uint16 fb[160*160];
    int frames = atoi(argv[2]);
    /* title -> press START -> play: exercises load_level's bank switch and a
       level's own bank, not just the boot */
    for (int i = 0; i < frames; i++) supervision_exec_ex(fb, 160, FALSE);
    for (int i = 0; i < 20; i++) { controls_state_write(0x80); supervision_exec_ex(fb,160,FALSE); }
    for (int i = 0; i < 8; i++) { controls_state_write(0x00); supervision_exec_ex(fb,160,FALSE); }
    for (int i = 0; i < 400; i++) { controls_state_write(0x00); supervision_exec_ex(fb,160,FALSE); }
    unsigned long h = 5381; int nonzero = 0;
    for (int i = 0; i < 160*160; i++) { h = h*33 ^ fb[i]; if (fb[i]) nonzero++; }
    printf("after %d + START + 400 frames: fb hash %08lx, non-blank %d/%d\n",
           frames, h & 0xffffffff, nonzero, 160*160);
    return 0;
}
