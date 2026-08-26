# Visibility metric on the real core: for each kit object on screen, is its image PRESENT in the
# framebuffer (non-bg pixels in its box)?  python3 tools/svflick.py ROM LEVEL script.txt FROM TO
import sys, subprocess, numpy as np, re
rom, level, sp, a, b = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
sc = open(sp).read().strip(); n = sum(int(s[1:]) for s in sc.split(','))
lbl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open('build/rom.lbl').read())}
W3 = [0x03,0x0D,0x19,0x1C,0x1F,0x23,0x25,0x31,0x32,0x33,0x35,0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x40,0x41,0x45,0x47,0x49,0x4A,0x4B,0x4F,0x58,0x5A]
subprocess.run(['/tmp/svshot', rom, level, str(min(n, b)), '1', '/tmp/fk.fb', '/tmp/fk.ram', sc], capture_output=True)
R = np.fromfile('/tmp/fk.ram', dtype=np.uint8).reshape(-1, 0x2000); fb = np.fromfile('/tmp/fk.fb', dtype=np.uint16).reshape(-1, 160, 160)
ts = lbl['timer_sub']; logic = sum(1 for f in range(a + 1, b) if R[f][ts] != R[f - 1][ts])
absent = {}; tot = {}
for f in range(a, b):
    r = R[f]; cam = int(r[0xB4]) | (int(r[0xB5]) << 8); bg = fb[f][150][2]
    for k in range(10):
        if int(r[0xFDA + k]) != 36: continue
        gt = W3[int(r[0xBEB + k])]; sx = ((int(r[0xFE4 + k]) | (int(r[0xFEE + k]) << 8)) - cam) & 0xFF; ry = int(r[0xFF8 + k])
        if sx > 140 or sx < 8: continue
        box = fb[f][max(16, ry - 8):ry + 32, max(0, sx - 8):sx + 24]
        present = int((box != bg).sum()) > 24
        key = f"{gt:x}[s{k}]"; tot[key] = tot.get(key, 0) + 1; absent[key] = absent.get(key, 0) + (not present)
print(f"logic {logic}/{b-a-1}  ABSENT frames per object:", {k: f"{absent[k]}/{tot[k]}" for k in sorted(tot)})
