# Per-frame object trace of the GB along a pad script (PyBoy replay, the
# gbauto/sv_vs_gb boot + alphabet). Rows as tools/svtrace.py:
#   {"f","cam","mx","my","objs":[[type, screen_x, y, pc, param, vel, dir],..]}
# from the $D100 object table (+0 type, +1 vel ffc1, +2 y, +3 x, +4 pc ffc4,
# +5 dir ffc5, +6 param ffc6). Uses the iddqd measurement ROM (geometry only).
#   python3 tools/gbtrace.py LEVEL script.txt out.json
import sys, json, os
sys.path.insert(0, 'tools')
from gbauto import ROM
from pyboy import PyBoy
level, script, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
seq = []
for seg in open(script).read().strip().split(','):
    seq += [seg[0]] * int(seg[1:])
p = PyBoy(ROM, window="null", sound_emulated=False); p.set_emulation_speed(0); m = p.memory
for _ in range(400): p.tick(1, True)
for _ in range(level):
    p.button_press("a"); p.tick(1, True); p.tick(1, True); p.button_release("a")
    for _ in range(8): p.tick(1, True)
p.button_press("start")
for _ in range(4): p.tick(1, True)
p.button_release("start")
for f in range(900):
    p.tick(1, True)
    if f > 200 and m[0xC202]: break
if os.environ.get("HARD"):        # $FF9A != 0: the spawner takes the bit-7 (hard-
    m[0xFF9A] = 1                 # mode) entries too (ObjectPhysics_Init_24EF)
rows = []
for f, w in enumerate(seq):
    for b in ("right", "a", "b", "left"): p.button_release(b)
    if w in ("R", "J", "Q", "F"): p.button_press("right")   # svshot letters:
    if w in ("J", "A", "Q", "K", "H"): p.button_press("a")  # J=R+A Q=R+A+B F=R+B
    if w in ("Q", "F", "B", "G", "H"): p.button_press("b")  # L K=L+A G=L+B H=L+A+B
    if w in ("L", "K", "G", "H"): p.button_press("left")
    p.tick(1, True)
    cam = (m[0xC0AB] | (m[0xC0AC] << 8)) * 16 - 192   # 16-px spawn-column camera
    d = (m[0xFFA4] - cam) & 0xFF                        # refine with ffa4 (pixel scroll)
    cam += d - 256 if d > 128 else d
    objs = []
    for k in range(10):
        b = 0xD100 + 16 * k
        if m[b] != 0xFF:
            objs.append([m[b], m[b + 3], m[b + 2], m[b + 4], m[b + 6], m[b + 1], m[b + 5]])
    rows.append({"f": f, "cam": cam, "mx": m[0xC202], "my": m[0xC201], "objs": objs})
p.stop(False)
json.dump(rows, open(out, 'w'))
print("gbtrace:", len(rows), "frames, final cam", rows[-1]["cam"])
