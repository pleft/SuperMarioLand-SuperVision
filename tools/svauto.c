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
#define PAD_B 0x10
#define PAD_L 0x02                     /* left: 3-3's brick maze needs left jumps */                     /* run: the lift-to-lift gaps of 3-3 need it */

/* port RAM (build/rom.lbl) */
#define CAM_L 0xB4
#define CAM_H 0xB5
#define SPR_X 0xA4
#define SPR_Y 0x1B
#define RESPAWN 0x39
#define DEATH 0x8A
#define RIDE 0x5D
#define GOAL_PHASE 0x5A    /* goal_phase (build/rom.lbl): != 0 once Mario is in the arch */

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
    int run = drift & 2 ? PAD_B : 0;              /* drift bit 1 = hold B (run) */
    int dir = drift & 4 ? PAD_L : PAD_R;          /* drift bit 2 = the plan moves LEFT */
    drift &= 1;
    if (i < d) return pre ? (dir | run) : 0;
    if (i < d + h) return drift ? (dir | PAD_A | run) : PAD_A;
    return dir | run;
}

static void write_script(const char *out, const uint8 *rec, int n)
{                                            /* the route so far -- also dumped at every
                                                progress print, so a stalled search still
                                                leaves a usable prefix */
    if (!out) return;
    FILE *o = fopen(out, "w");
    int i = 0;
    while (i < n) {
        int j = i;
        while (j < n && rec[j] == rec[i]) j++;
        char c = rec[i] == (PAD_R | PAD_A) ? 'J' : rec[i] == PAD_R ? 'R'
               : rec[i] == PAD_A ? 'A' : rec[i] == (PAD_R | PAD_A | PAD_B) ? 'Q'
               : rec[i] == (PAD_R | PAD_B) ? 'F' : rec[i] == PAD_L ? 'L'
               : rec[i] == (PAD_L | PAD_A) ? 'K' : rec[i] == (PAD_L | PAD_B) ? 'G'
               : rec[i] == (PAD_L | PAD_A | PAD_B) ? 'H' : '.';
        fprintf(o, "%s%c%d", i ? "," : "", c, j - i);
        i = j;
    }
    fclose(o);
    printf("  script -> %s\n", out);
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: svauto rom.sv level [frames] [out.txt]\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);          /* progress lines reach a log as they happen */
    int level = atoi(argv[2]);
    int frames = (argc > 3) ? atoi(argv[3]) : 4000;
    const char *out = (argc > 4) ? argv[4] : NULL;
    const char *prefix = (argc > 5) ? argv[5] : NULL;   /* replay this script first,
                                                           then search from its end */

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
    uint8 *snap = malloc(ssz);
    uint8 *rec = malloc(frames + 64);
    int n = 0, best = -1, stuck = 0;
    if (prefix) {                                /* hybrid: a known-good prefix */
        FILE *pf = fopen(prefix, "r");
        if (!pf) { perror("prefix"); return 2; }
        char c; int k;
        while (fscanf(pf, " %c%d", &c, &k) == 2) {
            uint8 pad = c == 'J' ? (PAD_R | PAD_A) : c == 'R' ? PAD_R : c == 'A' ? PAD_A
                      : c == 'Q' ? (PAD_R | PAD_A | PAD_B) : c == 'F' ? (PAD_R | PAD_B)
                      : c == 'L' ? PAD_L : c == 'K' ? (PAD_L | PAD_A) : c == 'G' ? (PAD_L | PAD_B)
                      : c == 'H' ? (PAD_L | PAD_A | PAD_B) : 0;
            for (int i = 0; i < k && n < frames; i++) { step1(pad); rec[n++] = pad; }
            fscanf(pf, ",");
        }
        fclose(pf);
        best = progress();
        printf("  prefix: %d frames, world x %d\n", n, best);
    }

    /* candidate fan: pre (right / nothing) x delay x hold x drift. The long
       delays (48..90, only with 'nothing' or holding right) exist for the
       Ganchan mounts of 3-2: the ride comes to Mario, so the right move is to
       WAIT for it -- a fan of immediate jumps never finds that. */
    static const int DELAY[] = {0, 3, 6, 9, 12, 18, 24, 30, 36, 48, 64, 90, 120, 150, 180, 210, 240};
    static const int HOLD[]  = {0, 4, 7, 10, 14, 18, 22, 26, 30};
    enum { ND = sizeof DELAY / sizeof *DELAY, NH = sizeof HOLD / sizeof *HOLD, NC = 2 * ND * NH * 8 };
    /* CHECKPOINT STACK (gbauto's): every committed window keeps the state it
       started from and which candidates it already tried. A death or a stall
       pops back -- one window, then two, three... -- and takes the next-best
       UNTRIED candidate there, so a pit whose only crossing needs an unlikely-
       looking first hop (or a Ganchan that must be waited for) is still found. */
    enum { HIST = 1500 };            /* 15000 frames of checkpoints */
    static uint8 *hsnap[HIST]; static int hn[HIST], hbest[HIST], hstuck[HIST];
    static uint8 htried[HIST][NC];
    int depth = 0, back = 1, backtracks = 0;
    const int MAXBACK = 150;
    int fresh = 1;                               /* this window's checkpoint is new */

    while (n < frames) {
        if (depth >= HIST) { printf("  history full at frame %d\n", n); break; }
        if (fresh) {
            if (!hsnap[depth]) hsnap[depth] = malloc(ssz);
            supervision_save_state_buf(hsnap[depth], ssz);
            hn[depth] = n; hbest[depth] = best; hstuck[depth] = stuck;
            memset(htried[depth], 0, NC);
        }
        memcpy(snap, hsnap[depth], ssz);
        int here = progress();
        int look = LOOK * (1 + stuck / 6);
        if (look > 4 * LOOK) look = 4 * LOOK;
        int bs = -1000000, bd = 0, bh = 0, bw = 1, bp = 1, bi = -1;
        int ci = 0;
        for (int pi = 0; pi < 2; pi++)
        for (int di = 0; di < ND; di++)
        for (int hi = 0; hi < NH; hi++)
        for (int w = 7; w >= 0; w--, ci++) {          /* bit0 drift, bit1 run, bit2 LEFT */
            int pre = pi ? 0 : 1, d = DELAY[di], h = HOLD[hi];
            if (htried[depth][ci]) continue;
            if (d >= 48 && ((w & 1) == 0 || hi > 3)) continue;   /* thin the long-wait fan */
            if ((w & 3) == 2) continue;                /* run without drift = pointless */
            if ((w & 4) && (d >= 48 || w == 4)) continue;   /* left plans: short waits, drift only */
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
                bs = score; bd = d; bh = h; bw = w; bp = pre; bi = ci;
            }
        }
        int fail = (bi < 0);                      /* every candidate here tried */
        if (!fail) {
            htried[depth][bi] = 1;
            supervision_load_state_buf(snap, ssz);
            n = hn[depth]; best = hbest[depth]; stuck = hstuck[depth];
            for (int i = 0; i < COMMIT && n < frames; i++) {
                uint8 pad = plan_pad(bp, bd, bh, bw, i);
                step1(pad);
                rec[n++] = pad;
                if (dead()) break;
            }
            int p = progress();
            if (ram()[GOAL_PHASE]) { printf("  GOAL reached at frame %d (x %d)\n", n, p); write_script(out, rec, n); return 0; }
            if (dead()) fail = 1;
            else if (p > best + 8) { best = p; stuck = 0; back = 1; }
            else if (++stuck > 40) fail = 2;
        }
        if (fail) {
            if (backtracks >= MAXBACK) { printf("  %s at frame %d, world x %d -- backtrack budget spent\n", fail == 2 ? "stuck" : "died", n, progress()); break; }
            backtracks++;
            depth -= back;                        /* pop: 1, then 2, 3... windows */
            if (back < 12) back++;
            if (depth < 0) depth = 0;
            fresh = 0;                            /* re-enter the old checkpoint */
            if (backtracks % 5 == 0) printf("  backtrack #%d to frame %d (x %d)\n", backtracks, hn[depth], hbest[depth]);
            continue;
        }
        depth++; fresh = 1;
        if (n % 240 < COMMIT) { printf("  f%d world x %d\n", n, progress()); write_script(out, rec, n); }
    }
    printf("port level %d: world x %d, %d frames\n", level, best, n);
    write_script(out, rec, n);
    return 0;
}
