# GB screenshots along a pad script (gbtrace boot). python3 tools/gbshot.py LEVEL script.txt outprefix f1,f2,...
import sys, os
sys.argv, real = sys.argv[:1], sys.argv
exec(open(os.path.join(os.path.dirname(__file__), "gbtrace.py")).read().split("rows = []")[0].replace("level, script, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]", "level, script, out = int(real[1]), real[2], real[3]"))
want = set(int(x) for x in real[4].split(','))
for f, w in enumerate(seq):
    for b in ("right", "a", "b", "left"): p.button_release(b)
    if w in ("R", "J", "Q", "F"): p.button_press("right")   # svshot letters:
    if w in ("J", "A", "Q", "K", "H"): p.button_press("a")  # J=R+A Q=R+A+B F=R+B
    if w in ("Q", "F", "B", "G", "H"): p.button_press("b")  # L K=L+A G=L+B H=L+A+B
    if w in ("L", "K", "G", "H"): p.button_press("left")
    p.tick(1, True)
    if f in want:
        p.screen.image.resize((480, 432)).save(f"{out}_{f}.png")
        print(f, m[0xC202], m[0xC201])
p.stop(False)
