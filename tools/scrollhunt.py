#!/usr/bin/env python3
"""scrollhunt: auto-detect a game's scroll shadow variable(s) from a cart-bus
capture, so the generic mirror (docs/30) can scroll instead of drawing at
origin (0,0).

Why this is needed (HW-proven, cart-bus-snoop memory / docs/28): register
WRITES are ADDRESS-ONLY on the SuperPico bus, so the value the game writes to
the scroll registers $2002 (X) / $2003 (Y) is NOT visible. BUT every WRAM
write is data-visible -- INCLUDING zero page. Games hold the camera position
in a WRAM shadow var and write it every frame as it moves. And we can read the
joypad ($2020, the one readable register). So the scroll var is found by
correlation: the WRAM address whose per-frame value-DELTA tracks the D-pad
(X delta <-> Left/Right, Y delta <-> Up/Down). Works for zp vars too.

Capture format (one line per WRAM write the Pico snooped, grouped by frame;
frame boundary = the $2002 register-write address event, or an explicit F):
    F <frame> <joy_hex>            # start of frame, joypad byte ($2020, low=pressed)
    W <addr_hex> <val_hex>         # a WRAM write seen this frame
Unknown lines are ignored. Stdlib only.

The joypad bit map ($2020, active LOW): bit0=Right 1=Left 2=Down 3=Up
4=B 5=A 6=Select 7=Start.
"""
import sys

BIT_RIGHT, BIT_LEFT, BIT_DOWN, BIT_UP = 0, 1, 2, 3


def _signed_delta(a, b):
    """(b - a) as a signed byte in [-128,127] -- handles the $2002 8-bit wrap."""
    d = (b - a) & 0xFF
    return d - 256 if d >= 128 else d


def parse_capture(text):
    """-> list of frames; each = {'joy': int, 'writes': {addr: last_val}}."""
    frames = []
    cur = None
    for line in text.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "F":
            cur = {"joy": int(p[2], 16), "writes": {}}
            frames.append(cur)
        elif p[0] == "W" and cur is not None:
            cur["writes"][int(p[1], 16)] = int(p[2], 16)
    return frames


def _pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return 0.0
    mx = sum(xs) / n
    my = sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return 0.0
    return sxy / (sxx * syy) ** 0.5


def hunt(frames, min_coverage=0.5):
    """Rank WRAM addresses by how well their delta tracks each axis.

    Returns dict: {'x': (addr, score, sign), 'y': (...), 'ranking': [...] }.
    sign = +1 if value rises when Right/Up held, -1 if it falls (the game's
    scroll-direction convention). |score| near 1.0 = a clean scroll var.
    """
    nf = len(frames)
    # per-axis input signal, +1/-1/0 per frame
    horiz = [(-1 if (f["joy"] >> BIT_LEFT) & 1 == 0 else 0) +
             (1 if (f["joy"] >> BIT_RIGHT) & 1 == 0 else 0) for f in frames]
    vert = [(-1 if (f["joy"] >> BIT_DOWN) & 1 == 0 else 0) +
            (1 if (f["joy"] >> BIT_UP) & 1 == 0 else 0) for f in frames]

    # gather each address's value series (carry last-known value forward)
    addrs = set()
    for f in frames:
        addrs.update(f["writes"])

    scored = []
    for a in sorted(addrs):
        vals, present = [], 0
        last = None
        for f in frames:
            if a in f["writes"]:
                last = f["writes"][a]
                present += 1
            vals.append(last)
        coverage = present / nf
        if coverage < min_coverage or vals[0] is None:
            continue
        deltas = [0] + [_signed_delta(vals[i - 1], vals[i]) for i in range(1, nf)]
        # reject vars that never move or move violently (RNG): a real scroll
        # var steps by a few px/frame.
        moved = [abs(d) for d in deltas if d]
        if not moved:
            continue
        med = sorted(moved)[len(moved) // 2]
        sane = med <= 8
        cx = _pearson(deltas, horiz)
        cy = _pearson(deltas, vert)
        scored.append({"addr": a, "cov": coverage, "med_step": med,
                       "sane": sane, "x": cx, "y": cy})

    def best(axis):
        cand = [s for s in scored if s["sane"]]
        if not cand:
            return None
        b = max(cand, key=lambda s: abs(s[axis]))
        sign = 1 if b[axis] >= 0 else -1
        return (b["addr"], abs(b[axis]) * sign, sign)

    ranking = sorted(scored, key=lambda s: -max(abs(s["x"]), abs(s["y"])))
    return {"x": best("x"), "y": best("y"), "ranking": ranking}


def _report(res):
    for axis, label in (("x", "SCROLL-X ($2002)"), ("y", "SCROLL-Y ($2003)")):
        r = res[axis]
        if r is None:
            print(f"  {label}: not found")
        else:
            a, score, sign = r
            conf = "STRONG" if abs(score) > 0.7 else \
                   "weak" if abs(score) > 0.4 else "NONE"
            dirn = "rises when pressed +" if sign > 0 else "falls when pressed -"
            print(f"  {label}: $%04X  corr=%+.3f (%s, %s)" % (a, score, conf, dirn))
    print("  top candidates (addr cov med_step corrX corrY):")
    for s in res["ranking"][:8]:
        print("    $%04X  cov=%.2f step=%d  X=%+.3f Y=%+.3f%s" %
              (s["addr"], s["cov"], s["med_step"], s["x"], s["y"],
               "" if s["sane"] else "  [insane-step]"))


# --------------------------------------------------------------------------
def _synth(nframes=600):
    """Deterministic realistic trace: a camera driven by a scripted D-pad,
    plus decoys the detector must reject (frame timer, anim counter, LCG RNG,
    a rarely-changing coin count, and a Y camera driven by Up/Down)."""
    SX, SY, TIMER, ANIM, RNG, COINS = 0x00C5, 0x00C6, 0x0140, 0x0141, 0x0142, 0x0150
    lines = []
    camx = camy = 0
    rng = 0x1234
    coins = 3
    for fr in range(nframes):
        # scripted input: alternate right runs, a left backtrack, some idle,
        # then vertical. joypad is active-LOW ($FF = nothing pressed).
        joy = 0xFF
        phase = fr % 200
        if phase < 90:
            joy &= ~(1 << BIT_RIGHT)          # hold Right
        elif phase < 110:
            joy &= ~(1 << BIT_LEFT)           # backtrack Left
        elif phase < 130:
            pass                              # idle
        elif phase < 170:
            joy &= ~(1 << BIT_UP)             # climb
        else:
            joy &= ~(1 << BIT_DOWN)           # descend
        lines.append("F %d %02X" % (fr, joy))
        # camera integrates input at 2 px/frame, wraps 8-bit
        if (joy >> BIT_RIGHT) & 1 == 0:
            camx += 2
        if (joy >> BIT_LEFT) & 1 == 0:
            camx -= 2
        if (joy >> BIT_UP) & 1 == 0:
            camy += 1
        if (joy >> BIT_DOWN) & 1 == 0:
            camy -= 1
        lines.append("W %04X %02X" % (SX, camx & 0xFF))
        lines.append("W %04X %02X" % (SY, camy & 0xFF))
        # decoys, all written every frame like a real game's per-frame vars:
        lines.append("W %04X %02X" % (TIMER, fr & 0xFF))          # +1/frame, no input link
        lines.append("W %04X %02X" % (ANIM, (fr // 4) & 3))       # 0..3 cycle
        rng = (rng * 1103515245 + 12345) & 0xFFFF
        lines.append("W %04X %02X" % (RNG, rng & 0xFF))           # violent jumps
        if fr % 137 == 0:
            coins += 1
        lines.append("W %04X %02X" % (COINS, coins & 0xFF))       # rarely moves
    return "\n".join(lines), {"x": SX, "y": SY}


def _selftest():
    text, truth = _synth()
    res = hunt(parse_capture(text))
    _report(res)
    ok = True
    if res["x"] is None or res["x"][0] != truth["x"]:
        print("FAIL: scroll-X not identified as $%04X" % truth["x"]); ok = False
    elif abs(res["x"][1]) < 0.7:
        print("FAIL: scroll-X correlation too weak"); ok = False
    if res["y"] is None or res["y"][0] != truth["y"]:
        print("FAIL: scroll-Y not identified as $%04X" % truth["y"]); ok = False
    print("SELFTEST", "OK" if ok else "FAILED",
          "-- X=$%04X Y=$%04X (truth X=$%04X Y=$%04X)" %
          (res["x"][0] if res["x"] else 0, res["y"][0] if res["y"] else 0,
           truth["x"], truth["y"]))
    return 0 if ok else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    if len(sys.argv) < 2:
        sys.exit("usage: scrollhunt.py CAPTURE.txt   |   scrollhunt.py --selftest")
    res = hunt(parse_capture(open(sys.argv[1]).read()))
    _report(res)
