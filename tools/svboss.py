# Boss visibility on the per-scanline core: python3 tools/svboss.py ROM script.txt FROM TO [type=0x32]
# Reference = the boss's box pixels in the first frame it is on screen with no other object within
# 40px; then per frame the fraction of reference foreground pixels that match. Prints the histogram.
import sys, subprocess, numpy as np, re
rom, sp, a, b = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]); T = int(sys.argv[5], 16) if len(sys.argv) > 5 else 0x32
sc = open(sp).read().strip(); n = sum(int(s[1:]) for s in sc.split(','))
W3 = [0x03,0x0D,0x19,0x1C,0x1F,0x23,0x25,0x31,0x32,0x33,0x35,0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x40,0x41,0x45,0x47,0x49,0x4A,0x4B,0x4F,0x58,0x5A]
subprocess.run(['/tmp/svshot', rom, '8', str(min(n, b)), '1', '/tmp/fk.fb', '/tmp/fk.ram', sc], capture_output=True)
R = np.fromfile('/tmp/fk.ram', dtype=np.uint8).reshape(-1, 0x2000); fb = np.fromfile('/tmp/fk.fb', dtype=np.uint16).reshape(-1, 160, 160)
def objs(f):
    r = R[f]; cam = int(r[0xB4]) | (int(r[0xB5]) << 8); out = []
    for k in range(10):
        t = int(r[0xFDA + k])
        if not t: continue
        gt = W3[int(r[0xBEB + k])] if t == 36 else 0x100 | t
        out.append((gt, ((int(r[0xFE4 + k]) | (int(r[0xFEE + k]) << 8)) - cam) & 0xFF, int(r[0xFF8 + k])))
    return out, int(r[0xA4])
ref = None; scores = []
for f in range(a, b):
    o, mx = objs(f); boss = [x for x in o if x[0] == T]
    if not boss: continue
    sx, ry = boss[0][1], boss[0][2]
    if sx > 130 or sx < 10: continue
    box = fb[f][ry - 16 + 16:ry + 8 + 16 + 8, sx - 8:sx + 24]     # metasprite y -16..8, x 0..16 (+margins)
    if ref is None:
        if all(abs(x[1] - sx) > 40 for x in o if x[0] != T) and abs(mx - sx) > 40:
            ref = box.copy(); bg = fb[f][150][2]; fg = ref != bg; print('reference at frame', f, 'fg px', int(fg.sum()))
        continue
    match = (box == ref) & fg; scores.append((f, match.sum() / fg.sum()))
if not scores: print('no boss frames'); sys.exit()
v = np.array([s for _, s in scores]); print(f"frames {len(v)}: visible>=0.8: {(v>=0.8).mean():.0%}  0.5-0.8: {((v>=0.5)&(v<0.8)).mean():.0%}  <0.5 (mostly wiped): {(v<0.5).mean():.0%}")
