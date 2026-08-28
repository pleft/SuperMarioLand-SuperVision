# Route-INDEPENDENT boss-arena meter: warp the camera + Mario onto the sphere
# ledge (the arena route's own end state) and hold still. Same frames on every
# build, so budget/renderer variants are comparable (E23: a replayed ROUTE is
# not -- it diverges the moment engine speed changes).
#   python3 tools/svboss2.py ROM [frames]
import sys, os, subprocess, re, numpy as np
rom = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 700
lbl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open('build/rom.lbl').read())}
O_TYPE, O_XL, O_XH, O_Y, W3TI = (lbl[k] for k in ('o_type','o_xl','o_xh','o_y','w3_ti'))
W3 = [0x03,0x0D,0x19,0x1C,0x1F,0x23,0x25,0x31,0x32,0x33,0x35,0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x40,0x41,0x45,0x47,0x49,0x4A,0x4B,0x4F,0x58,0x5A]
POKES = "0xB4:0xFC@98,0xB5:0x08@98,0xA4:64@98,0x1B:172@100"   # the documented warp:
ROUTE = open('/tmp/arena_route_fix.txt').read().strip()       # cam 2300 + a death ->
CUT = 700                                                     # the 1920 checkpoint,
o, t = [], 0                                                  # then the route to the
for seg in ROUTE.split(','):                                  # arena -- cut SHORT of
    k = int(seg[1:])                                          # the sphere (f~751) so
    if t + k >= CUT: o.append(seg[0] + str(max(1, CUT - t))); break
    o.append(seg); t += k                                     # the FIGHT keeps running
ROUTE = ','.join(o); rn = sum(int(x[1:]) for x in ROUTE.split(','))
sc = ROUTE + f",.{n}"                                         # (god build: Mario just
subprocess.run(['/tmp/svshot', rom, '8', str(rn + n), '1', '/tmp/b2.fb', '/tmp/b2.ram', sc, POKES], capture_output=True)
R = np.fromfile('/tmp/b2.ram', dtype=np.uint8).reshape(-1, 0x2000)
fb = np.fromfile('/tmp/b2.fb', dtype=np.uint16).reshape(-1, 160, 160)
ts = lbl['timer_sub']; pdr = lbl['o_pdr']
a, b = rn + 20, rn + n            # measure only the STANDING TAIL: same scene,
                                  # same length on every build (the route itself diverges)
logic = sum(1 for f in range(a+1, b) if R[f][ts] != R[f-1][ts])
img = []; bd = []; gd = []; bl = []
for f in range(a, b):
    r = R[f]; cam = int(r[0xB4]) | (int(r[0xB5]) << 8)
    for k in range(10):
        if int(r[O_TYPE + k]) != 36: continue
        gt = W3[int(r[W3TI + k])]; sx = ((int(r[O_XL+k]) | (int(r[O_XH+k]) << 8)) - cam) & 0xFF; ry = int(r[O_Y+k])
        if gt == 0x32 and 8 < sx < 130:
            img.append(int((fb[f][ry:ry+24, sx-8:sx+24] == 0x8000).sum())); bd.append(int(r[pdr+k]))
        if gt == 0x47 and 8 < sx < 140: gd.append(int(r[pdr+k]))
        if gt in (0x31, 0x33) and 8 < sx < 140: bl.append(int(r[pdr+k]))
img = np.array(img)
print(f"{os.path.basename(rom)}: logic {logic}/{b-a-1}  boss {len(img)}f: wiped(<40%) {int((img < 0.4*img.max()).sum()) if len(img) else '-'}, "
      f"not-drawn {len(bd)-sum(bd)}/{len(bd)}  ganchan not-drawn {len(gd)-sum(gd)}/{len(gd)}  boulder not-drawn {len(bl)-sum(bl)}/{len(bl)}")
