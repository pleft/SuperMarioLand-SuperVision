#!/usr/bin/env python3
"""gbauto -- drive the GB through a whole level and emit the INPUT SCRIPT.

Greedy lookahead with save states: every COMMIT frames it rolls the emulator
back and tries a fan of candidate (delay, hold) jump timings, scores each by how
far right Mario gets in the next LOOK frames (death = -inf), then commits the
winner's first COMMIT frames. That crosses pits and stone bridges the reactive
heuristic could never time.

The point is the script it writes: tools/svshot replays the SAME letters on the
port, so both sides play the level identically and their per-frame positions can
be differenced (RULE 0 -- the GB is the reference, not my memory of it).

Usage:  python3 tools/gbauto.py <level-select-index> [frames] [out.txt]
        level index: 0 = 1-1, 5 = 2-3, 6 = 3-1 ...
Needs an invincibility build (deaths by contact would derail the search); it is
the scratchpad's sml_iddqd3.gb -- see the iddqd-ROM-trap memory: never ask this
run about DAMAGE, only about geometry.
"""
import sys, io, os

def _gb_rom():
    """the measurement rom: an explicit SML_GB, else a scratch copy, else make one
    (tools/make_iddqd.py -- the old scratchpad copy evaporated with its temp dir)"""
    import subprocess
    p = os.environ.get("SML_GB")
    if p and os.path.exists(p):
        return p
    cand = os.path.join(os.environ.get("CLAUDE_JOB_DIR", "/tmp"), "tmp", "sml_iddqd3.gb")
    if not os.path.exists(cand):
        subprocess.run([sys.executable, "tools/make_iddqd.py", cand], check=True)
    return cand
ROM = _gb_rom()

PLAY = (0x00, 0x0D)              # $FFB3: walker / submarine play states
COMMIT = 10                      # frames locked in per search step
NEAR = 60                        # short horizon (see run_plan)
LOOK = 180                       # lookahead horizon (long enough to see the far
                                 # side of a pit; the winner is picked among the
                                 # candidates still ALIVE at the horizon, so a long
                                 # view no longer collapses every score to the
                                 # death penalty)
# (delay before the jump, how long A is held). delay 0 = jump at once.
# (pre, delay, hold, drift): pre = hold RIGHT (1) or STAND STILL (0) before the
# jump -- standing is what lets the search WAIT for a moving platform to come
# to it instead of walking off the lip every time.
CAND = [(pre, d, h, w) for pre in (1, 0) for d in range(0, 42, 6)
        for h in (0, 10, 14, 18, 22, 26, 30) for w in (1, 0)]


def cam_of(m):
    return (m[0xC0AB] | (m[0xC0AC] << 8)) * 16 - 192


def apply(p, pad):
    """pad: bit0 = RIGHT, bit1 = A. Releasing RIGHT during a jump is not a
    nicety -- 3-1 has landings (the row-9 slab over the second gap) that a
    right-held arc always overshoots."""
    for b in ("right", "a"):
        p.button_release(b)
    if pad & 1:
        p.button_press("right")
    if pad & 2:
        p.button_press("a")
    p.tick(1, True)


def run_plan(p, m, plan, n, near, now):
    """Play n frames of plan (list of 0/1 = A pressed) and score it.

    TWO horizons, because one is never right for both shapes of hazard: a pit
    needs the LONG view (the jump has to start before the lip) and 3-1's sinking
    stone bridge needs the SHORT one (no candidate survives 132 frames on it, so
    a long-only score makes standing still the best move and the search stalls at
    the bridge -- measured, twice). Rank: alive at the long horizon beats alive at
    the short one beats the furthest corpse."""
    p60 = None
    for i in range(n):
        apply(p, plan[i] if i < len(plan) else 0)
        if i + 1 == near:
            p60 = cam_of(m) + m[0xC202]
        if m[0xFFB3] not in PLAY:
            prog = cam_of(m) + m[0xC202]
            return (10000 + p60) if p60 is not None else prog
    prog = cam_of(m) + m[0xC202]
    if prog <= now + 4:                        # alive but going nowhere (standing
        return prog                            # against a wall) -- do NOT let that
                                               # outrank a move that gets somewhere
    return 20000 + prog


def plan_of(pre, delay, hold, n, drift=1):
    """`pre` (right or nothing) until `delay`, then A for `hold` frames -- with
    RIGHT only if `drift` -- then right again"""
    out = []
    for i in range(n):
        if i < delay:
            out.append(pre)
        elif i < delay + hold:
            out.append(3 if drift else 2)
        else:
            out.append(1)
    return out


def main():
    from pyboy import PyBoy
    level = int(sys.argv[1])
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    out = sys.argv[3] if len(sys.argv) > 3 else f"/tmp/gbscript_{level}.txt"

    p = PyBoy(ROM, window="null", sound_emulated=False)
    p.set_emulation_speed(0)
    m = p.memory
    for _ in range(400):
        p.tick(1, True)
    for _ in range(level):                    # level select: N taps of A, then START
        p.button_press("a"); p.tick(1, True); p.tick(1, True); p.button_release("a")
        for _ in range(8):
            p.tick(1, True)
    p.button_press("start")
    for _ in range(4):
        p.tick(1, True)
    p.button_release("start")
    for f in range(900):
        p.tick(1, True)
        if f > 200 and m[0xC202]:
            break

    # Checkpoint stack: one entry per committed window, each holding the state
    # BEFORE the window, the candidates ranked by lookahead score, and how many
    # of them have been tried. A death (or a stall) pops back and takes the next
    # candidate down the ranking -- without that the search cannot get past a pit
    # whose only crossing needs an unlikely-looking first hop.
    rec, f, best_progress, stuck, deaths = [], 0, -1, 0, 0
    stack = []
    while f < frames:
        snap = io.BytesIO(); p.save_state(snap)
        here = cam_of(m) + m[0xC202]
        ranked = []
        for (pre, d, h, w) in CAND:
            snap.seek(0); p.load_state(snap)
            plan = plan_of(pre, d, h, LOOK, w)
            ranked.append((run_plan(p, m, plan, LOOK, NEAR, here), d, h, w, pre))
        # score DESC, but ties go to the EARLIEST jump: a tie usually means
        # 'both clear it', and the later jump is the one that walks to the
        # lip of the pit first (measured: sorting ties the other way lost
        # 3-1's first pit every time)
        ranked.sort(key=lambda r: (-r[0], -r[4], r[1], r[2], -r[3]))
        # the winner is the best-scoring candidate that is STILL ALIVE at the end
        # of its lookahead (score >= 0); if every one of them dies, take the one
        # that got furthest and let the next window try to save it
        _, d, h, w, pre = ranked[0]
        if ranked[0][0] < 20000:
            deaths += 1
        snap.seek(0); p.load_state(snap)
        plan = plan_of(pre, d, h, COMMIT, w)
        for i in range(COMMIT):
            apply(p, plan[i]); rec.append(plan[i]); f += 1
            if m[0xFFB3] not in PLAY:
                break
        if m[0xFFB3] not in PLAY:
            print(f"  died at frame {f}, cam {cam_of(m)}")
            break
        prog = cam_of(m) + m[0xC202]
        if prog > best_progress + 8:
            best_progress, stuck = prog, 0
        else:
            stuck += 1
            if stuck > 24:
                print(f"  stuck at world x {prog} (frame {f})")
                break
        if f % 240 < COMMIT:
            print(f"  f{f} world x {prog} ({deaths} deaths)")

    LET = {1: "R", 3: "J", 2: "A", 0: "."}   # svshot letters (J = right+A)
    segs, cur, n = [], rec[0] if rec else 1, 0
    for b in rec:
        if b == cur:
            n += 1
        else:
            segs.append((LET[cur], n)); cur = b; n = 1
    segs.append((LET[cur], n))
    open(out, "w").write(",".join(f"{c}{k}" for c, k in segs))
    print(f"level {level}: world x {best_progress}, {len(rec)} frames -> {out}")


if __name__ == "__main__":
    main()
