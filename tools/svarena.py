# Boss-arena visibility on the per-scanline core via the warp route:
#   python3 tools/svarena.py ROM script.txt   (POKES env = the warp pokes)
import sys, os, subprocess, numpy as np, re
rom, sp = sys.argv[1], sys.argv[2]; sc = open(sp).read().strip(); n = sum(int(s[1:]) for s in sc.split(','))
lbl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open('build/rom.lbl').read())}
W3 = [0x03,0x0D,0x19,0x1C,0x1F,0x23,0x25,0x31,0x32,0x33,0x35,0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x40,0x41,0x45,0x47,0x49,0x4A,0x4B,0x4F,0x58,0x5A]
subprocess.run(['/tmp/svshot', rom, '8', str(n), '1', '/tmp/fk.fb', '/tmp/fk.ram', sc, os.environ.get('POKES', '')], capture_output=True)
R = np.fromfile('/tmp/fk.ram', dtype=np.uint8).reshape(-1, 0x2000); fb = np.fromfile('/tmp/fk.fb', dtype=np.uint16).reshape(-1, 160, 160)
cam = lambda f: int(R[f][0xB4]) | (int(R[f][0xB5]) << 8)
fr = [f for f in range(200, n) if cam(f) >= 2150]
if not fr: print('never reached the arena'); sys.exit()
a, b = fr[0], fr[-1]; ts = lbl['timer_sub']; logic = sum(1 for f in range(a + 1, b) if R[f][ts] != R[f - 1][ts])
cnt = []; pdr = []; g = []
for f in range(a, b):
    r = R[f]; c = cam(f)
    for k in range(10):
        if int(r[0xFDA + k]) != 36: continue
        gt = W3[int(r[0xBEB + k])]; sx = ((int(r[0xFE4 + k]) | (int(r[0xFEE + k]) << 8)) - c) & 0xFF; ry = int(r[0xFF8 + k])
        if gt == 0x32 and 8 < sx < 130: cnt.append(int((fb[f][ry:ry + 24, sx - 8:sx + 24] == 0x8000).sum())); pdr.append(int(r[lbl['o_pdr'] + k]))
        if gt == 0x47 and 8 < sx < 140: g.append(int(r[lbl['o_pdr'] + k]))
cnt = np.array(cnt)
print(f'{rom}: arena frames {a}-{b}, logic {logic}/{b-a-1}; boss frames {len(cnt)}: mostly-wiped(<40% of max dark) {int((cnt < 0.4 * cnt.max()).sum()) if len(cnt) else "-"}, not-drawn {len(pdr)-sum(pdr)}/{len(pdr)}; ganchan not-drawn {len(g)-sum(g)}/{len(g)}')
