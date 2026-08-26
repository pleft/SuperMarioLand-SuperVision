# GB deep start: poke $ffe5=SEG at level load (world px ~ (SEG-4)*160, rounds to x4),
# then replay a pad script (gbtrace letters). Rows as gbtrace + 'hp' (slot+12).
#   python3 tools/gbdeep.py LEVEL SEG "script" out.json
import sys, json, os
sys.path.insert(0, os.path.dirname(__file__))
from gbauto import ROM
from pyboy import PyBoy
level, SEG, script, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
seq = []
for seg in script.strip().split(','): seq += [seg[0]] * int(seg[1:])
p = PyBoy(ROM, window="null", sound_emulated=False); p.set_emulation_speed(0); m = p.memory
for _ in range(400): p.tick(1, True)
for _ in range(level):
    p.button_press("a"); p.tick(1, True); p.tick(1, True); p.button_release("a")
    for _ in range(8): p.tick(1, True)
p.button_press("start"); poked = False
for f in range(900):
    p.tick(1, True)
    if f == 4: p.button_release("start")
    if not poked and m[0xFFE5] == 3: m[0xFFE5] = SEG; poked = True
    if f > 200 and m[0xC202]: break
rows = []
for f, w in enumerate(seq):
    for b in ("right", "a", "b", "left"): p.button_release(b)
    if w in ("R", "J", "Q", "F"): p.button_press("right")
    if w in ("J", "A", "Q", "K", "H"): p.button_press("a")
    if w in ("Q", "F", "B", "G", "H"): p.button_press("b")
    if w in ("L", "K", "G", "H"): p.button_press("left")
    p.tick(1, True)
    if f == 0:                     # deep starts: the c0ab column base can be 128px off,
        cam = (m[0xC0AB] | (m[0xC0AC] << 8)) * 16 - 192   # so integrate ffa4 deltas
        cam += (m[0xFFA4] - cam) & 0xFF; cam -= 256 if ((m[0xFFA4] - cam) & 0xFF) > 128 else 0
        pa4 = m[0xFFA4]
    else:
        dd = (m[0xFFA4] - pa4) & 0xFF; cam += dd - 256 if dd > 128 else dd; pa4 = m[0xFFA4]
    objs = []
    for k in range(10):
        b = 0xD100 + 16 * k
        if m[b] != 0xFF: objs.append([m[b], m[b + 3], m[b + 2], m[b + 4], m[b + 6], m[b + 1], m[b + 5], m[b + 12]])
    rows.append({"f": f, "cam": cam, "mx": m[0xC202], "my": m[0xC201], "objs": objs})
p.stop(False); json.dump(rows, open(out, 'w'))
print("gbdeep:", len(rows), "frames, cam", rows[0]["cam"], "->", rows[-1]["cam"], "mario", rows[-1]["mx"] + rows[-1]["cam"] - 15, rows[-1]["my"] - 6)
