/* svauto -- the PORT's own auto-player: drive the real Potator core through a
   level with the same greedy save-state search tools/gbauto.py runs on the GB,
   and report how far it gets.

   Why this and not "replay the GB's script on the port": an open-loop script
   drifts. Ten pixels of phase and the scripted jump lands on the wrong side of
   an obstacle, so every later frame differs and the differential drowns in
   noise. Closed-loop on BOTH sides asks the question that actually matters --
   can the port do what the GB can, at this spot? -- and a place where the GB's
   search sails through and the port's search cannot is a PORT BUG, with its
   world x printed.

   Build: cc -O2 -I ~/Dev/potator/common -I ~/Dev/potator/common/m6502 \
              -o /tmp/svauto tools/svauto.c ~/Dev/potator/common/*.c \
              ~/Dev/potator/common/m6502/m6502.c
   Run:   /tmp/svauto rom.sv <level> [frames] [out-script.txt]
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "supervision.h"
#include "controls.h"
#include "memorymap.h"

#define START 0x80
#define SELECT 0x40
#define PAD_R 0x01
#define PAD_A 0x20

/* port RAM (build/rom.lbl) */
#define CAM_L 0xB4
#define CAM_H 0xB5
#define SPR_X 0xA4
#define SPR_Y 0x1B
#define RESPAWN 0x39
#define DEATH 0x8A
#define RIDE 0x5D

#define COMMIT 10
#define NEAR 60
#define LOOK 180

static uint16 fb[160 * 160];
static uint8 *ram(void) { return memorymap_getLowerRamPointer(); }

static void step1(uint8 pad)
{
    controls_state_write(pad);
    supervision_exec_ex(fb, 160, FALSE);
}

static int progress(void)
{
    uint8 *r = ram();
    return (r[CAM_L] | (r[CAM_H] << 8)) + r[SPR_X];
}

static int dead(void)
{
    uint8 *r = ram();
    return r[RESPAWN] || r[DEATH] || r[SPR_Y] >= 160;
}

/* pad for frame i of a plan: `pre` until delay, A for hold (RIGHT too if drift),
   then RIGHT */
static uint8 plan_pad(int pre, int d, int h, int drift, int i)
{
    if (i < d) return pre ? PAD_R : 0;
    if (i < d + h) return drift ? (PAD_R | PAD_A) : PAD_A;
    return PAD_R;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: svauto rom.sv level [frames] [out.txt]\n"); return 2; }
    int level = atoi(argv[2]);
    int frames = (argc > 3) ? atoi(argv[3]) : 4000;
    const char *out = (argc > 4) ? argv[4] : NULL;

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("rom"); return 2; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *rom = malloc(sz);
    if (fread(rom, 1, sz, f) != (size_t)sz) return 2;
    fclose(f);
    supervision_init();
    if (!supervision_load(rom, (unsigned)sz)) { fprintf(stderr, "load failed\n"); return 2; }
    supervision_reset();
    for (int i = 0; i < 300; i++) step1(0);
    for (int i = 0; i < level; i++) {
        for (int j = 0; j < 3; j++) step1(SELECT);
        for (int j = 0; j < 10; j++) step1(0);
    }
    for (int j = 0; j < 4; j++) step1(START);
    for (int j = 0; j < 70; j++) step1(0);

    uint32 ssz = supervision_save_state_buf_size();
    uint8 *snap = malloc(ssz), *tmp = malloc(ssz);
    uint8 *rec = malloc(frames + 64);
    int n = 0, best = -1, stuck = 0;

    static const int DELAY[] = {0, 6, 12, 18, 24, 30, 36};
    static const int HOLD[]  = {0, 10, 14, 18, 22, 26, 30};

    while (n < frames) {
        supervision_save_state_buf(snap, ssz);
        int here = progress();
        /* ADAPTIVE HORIZON: riding a moving platform means standing still for a
           hundred frames before any ground is gained, so a fixed lookahead sees
           only "no progress" and the search refuses to step on. Every stalled
           window widens the view (up to 4x) until the ride's payoff is inside
           it. */
        int look = LOOK * (1 + stuck / 6);
        if (look > 4 * LOOK) look = 4 * LOOK;
        int bs = -1000000, bd = 0, bh = 0, bw = 1, bp = 1;
        for (int pi = 0; pi < 2; pi++)
        for (int di = 0; di < (int)(sizeof DELAY / sizeof *DELAY); di++)
        for (int hi = 0; hi < (int)(sizeof HOLD / sizeof *HOLD); hi++)
        for (int w = 1; w >= 0; w--) {
            int pre = pi ? 0 : 1, d = DELAY[di], h = HOLD[hi];
            supervision_load_state_buf(snap, ssz);
            int p60 = -1, score;
            int i;
            for (i = 0; i < look; i++) {
                step1(plan_pad(pre, d, h, w, i));
                if (i + 1 == NEAR) p60 = progress();
                if (dead()) break;
            }
            if (i < look)                          /* died inside the horizon */
                score = (p60 >= 0) ? 10000 + p60 : progress();
            else if (progress() <= here + 4 && !ram()[RIDE])
                score = progress();            /* alive but going nowhere -- and
                                                  NOT riding: standing on a lift
                                                  gains no x for ~100 frames and
                                                  must not be scored as a stall */
            else
                score = 20000 + progress();
            if (score > bs || (score == bs && (d < bd || (d == bd && h < bh)))) {
                bs = score; bd = d; bh = h; bw = w; bp = pre;
            }
        }
        supervision_load_state_buf(snap, ssz);
        for (int i = 0; i < COMMIT && n < frames; i++) {
            uint8 pad = plan_pad(bp, bd, bh, bw, i);
            step1(pad);
            rec[n++] = pad;
            if (dead()) break;
        }
        if (dead()) { printf("  died at frame %d, world x %d\n", n, progress()); break; }
        int p = progress();
        if (p > best + 8) { best = p; stuck = 0; }
        else if (++stuck > 40) { printf("  stuck at world x %d (frame %d)\n", p, n); break; }
        if (n % 240 < COMMIT) printf("  f%d world x %d\n", n, p);
    }
    printf("port level %d: world x %d, %d frames\n", level, best, n);
    if (out) {
        FILE *o = fopen(out, "w");
        int i = 0;
        while (i < n) {
            int j = i;
            while (j < n && rec[j] == rec[i]) j++;
            char c = rec[i] == (PAD_R | PAD_A) ? 'J' : rec[i] == PAD_R ? 'R'
                   : rec[i] == PAD_A ? 'A' : '.';
            fprintf(o, "%s%c%d", i ? "," : "", c, j - i);
            i = j;
        }
        fclose(o);
        printf("  script -> %s\n", out);
    }
    return 0;
}
