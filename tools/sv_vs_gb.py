#!/usr/bin/env python3
"""sv_vs_gb -- play the SAME input script on the GB and on the port, then report
where Mario's path diverges.

The script comes from tools/gbauto.py (which searches the GB for a route through
the level), so both sides get a run that actually crosses the pits. Letters:
R = right, J = right+A, A = A alone, . = nothing -- the same alphabet svshot's
input script takes.

    python3 tools/gbauto.py 6 4000 /tmp/gbscript_6.txt
    python3 tools/sv_vs_gb.py 6 /tmp/gbscript_6.txt

Positions are compared as DELTAS from the first frame (the two engines put Mario
at slightly different absolute coordinates), and both runs use the invincibility
build so a contact death cannot end one side early (iddqd-ROM-trap: never read
DAMAGE off this run, only geometry).
"""
import sys, subprocess, os
import numpy as np

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
GB_ROM = _gb_rom()
SV_ROM = os.environ.get("SML_SV", "build/super-mario-land-god.sv")
SHOT = os.environ.get("SHOT", "/tmp/svshot")

LEVEL = int(sys.argv[1])
SCRIPT = open(sys.argv[2]).read().strip()


def expand(script):
    seq = []
    for seg in script.split(","):
        seq += [seg[0]] * int(seg[1:])
    return seq


def gb(seq):
    from pyboy import PyBoy
    p = PyBoy(GB_ROM, window="null", sound_emulated=False)
    p.set_emulation_speed(0)
    m = p.memory
    for _ in range(400):
        p.tick(1, True)
    for _ in range(LEVEL):
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
    out = []
    for w in seq:
        for b in ("right", "a"):
            p.button_release(b)
        if w in ("R", "J"):
            p.button_press("right")
        if w in ("J", "A"):
            p.button_press("a")
        p.tick(1, True)
        cam = (m[0xC0AB] | (m[0xC0AC] << 8)) * 16 - 192
        # object slots: type, screen x, y -- 16 bytes apart from $D100
        objs = [(m[0xD100 + 16 * k], m[0xD100 + 16 * k + 3], m[0xD100 + 16 * k + 2])
                for k in range(10) if m[0xD100 + 16 * k] != 0xFF]
        out.append((cam + m[0xC202], m[0xC201], m[0xFFB3], objs, cam))
    p.stop(False)
    return out


def port(seq):
    subprocess.run([SHOT, SV_ROM, str(LEVEL), str(len(seq)), "1",
                    "/tmp/cmpfb.bin", "/tmp/cmpram.bin", SCRIPT], capture_output=True)
    R = np.fromfile("/tmp/cmpram.bin", dtype=np.uint8).astype(int).reshape(-1, 0x2000)
    out = []
    for i in range(len(R)):
        r = R[i]
        objs = [(r[0xFDA + k], (r[0xFE4 + k] | (r[0xFEE + k] << 8)), r[0xFF8 + k])
                for k in range(10) if r[0xFDA + k]]
        cam = r[0xB4] | (r[0xB5] << 8)
        out.append((cam + r[0xA4], r[0x1B], r[0x5D], objs, cam))
    return out


def main():
    seq = expand(SCRIPT)
    G, P = gb(seq), port(seq)
    n = min(len(G), len(P))
    gx0, gy0 = G[0][0], G[0][1]
    px0, py0 = P[0][0], P[0][1]
    print(f"frames compared: {n}   (GB start x {gx0} y {gy0} / port x {px0} y {py0})")
    first = None
    worst = (0, 0)
    for i in range(n):
        dx = (G[i][0] - gx0) - (P[i][0] - px0)
        dy = (G[i][1] - gy0) - (P[i][1] - py0)
        if abs(dx) > worst[0]:
            worst = (abs(dx), i)
        if first is None and (abs(dx) > 8 or abs(dy) > 10):
            first = (i, dx, dy)
    print(f"worst |dx| {worst[0]}px at frame {worst[1]}")
    if first:
        i, dx, dy = first
        print(f"FIRST DIVERGENCE at frame {i}: dx {dx:+d} dy {dy:+d}")
        for j in range(max(0, i - 24), min(n, i + 12), 4):
            print(f"   f{j:4d} GB x{G[j][0]:5d} y{G[j][1]:4d} | port x{P[j][0]:5d} "
                  f"y{P[j][1]:4d} ride {P[j][2]}")
        print("   GB slots:  ", G[i][3])
        print("   port slots:", P[i][3])
    else:
        print("no divergence beyond 8px x / 10px y -- the port plays this input like the GB")
    for j in range(0, n, max(1, n // 20)):
        dx = (G[j][0] - gx0) - (P[j][0] - px0)
        dy = (G[j][1] - gy0) - (P[j][1] - py0)
        print(f"   f{j:4d}: GB {G[j][0] - gx0:5d},{G[j][1]:4d}  "
              f"port {P[j][0] - px0:5d},{P[j][1]:4d}  d {dx:+4d},{dy:+4d}")


if __name__ == "__main__":
    main()
