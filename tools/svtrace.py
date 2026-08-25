# Per-frame object trace of the PORT along a pad script, on the REAL Potator
# core (tools/svshot RAM dumps) -- the twin of tools/gbtrace.py. Rows:
#   {"f","cam","mx","my","objs":[[gbtype, screen_x, y, pc, param, vel, dir],..]}
# gbtype: W3 slots map through the kit type table; engine types are 0x100|id.
#   python3 tools/svtrace.py LEVEL script.txt out.json   (SML_SV / SHOT env)
import sys, json, os, subprocess
import numpy as np
W3TAB = [0x03,0x0D,0x19,0x1C,0x1F,0x23,0x25,0x31,0x32,0x33,0x35,0x38,0x39,0x3A,0x3B,
         0x3C,0x3D,0x3E,0x40,0x41,0x45,0x47,0x49,0x4A,0x4B,0x4F,0x58,0x5A]
OBJ_W3 = 36
# zero-page / RAM offsets (build/w2abi.inc)
O_TYPE, O_XL, O_XH, O_Y, O_VX, O_VY, O_ST, W3_PC, W3_TI = 0xFDA, 0xFE4, 0xFEE, 0xFF8, 0x1002, 0x100C, 0x103E, 0xBE1, 0xBEB
CAM, SPRX, SPRY = 0xB4, 0xA4, 0x1B
level, script, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
rom = os.environ.get("SML_SV", "build/super-mario-land-god.sv")
shot = os.environ.get("SHOT", "/tmp/svshot")
seq = []
for seg in open(script).read().strip().split(','):
    seq += [seg[0]] * int(seg[1:])
fb, ram = "/tmp/svtrace_fb.bin", "/tmp/svtrace_ram.bin"
subprocess.run([shot, rom, str(level), str(len(seq)), "1", fb, ram, open(script).read().strip()],
               check=True, capture_output=True)
R = np.fromfile(ram, dtype=np.uint8).reshape(-1, 0x2000)
rows = []
for f in range(len(R)):
    r = R[f]; cam = int(r[CAM]) | (int(r[CAM + 1]) << 8); objs = []
    for i in range(10):
        t = int(r[O_TYPE + i])
        if not t: continue
        wx = int(r[O_XL + i]) | (int(r[O_XH + i]) << 8)
        gt = W3TAB[int(r[W3_TI + i])] if t == OBJ_W3 else 0x100 | t
        objs.append([gt, (wx - cam) & 0xFF, int(r[O_Y + i]), int(r[W3_PC + i]), int(r[O_ST + i]),
                     int(r[O_VX + i]), int(r[O_VY + i])])
    rows.append({"f": f, "cam": cam, "mx": int(r[SPRX]), "my": int(r[SPRY]), "objs": objs})
json.dump(rows, open(out, 'w'))
print("svtrace:", len(rows), "frames, final cam", rows[-1]["cam"])
