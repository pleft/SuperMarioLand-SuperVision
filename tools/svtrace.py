# Per-frame object trace of the PORT along a pad script, on the REAL Potator
# core (tools/svshot RAM dumps) -- the twin of tools/gbtrace.py. Rows:
#   {"f","cam","mx","my","objs":[[gbtype, screen_x, y, pc, param, vel, dir],..]}
# gbtype: W3 slots map through the kit type table; engine types are 0x100|id.
#   python3 tools/svtrace.py LEVEL script.txt out.json   (SML_SV / SHOT env)
import sys, json, os, subprocess
import numpy as np
# the kit's type table is read from RAM ($152A, the loaded window image), not
# hardcoded: World 4's kit has its own roster and a W3 table silently decodes
# every kit object as the wrong enemy (cost: an hour chasing a phantom 4-1 bug)
W3TAB_ADDR = 0x152A
OBJ_W3 = 36
# EVERY RAM offset comes from build/rom.lbl. Hardcoding them means one added BSS
# byte silently shifts the whole object array and the trace reports phantom bugs
# -- it cost an hour on 3-3's flicker and another on 4-1's spawns, same day.
import re as _re
_LBL = {m.group(2): int(m.group(1), 16) for m in
        _re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open('build/rom.lbl').read())}
O_TYPE, O_XL, O_XH, O_Y, O_VX, O_VY, O_ST, W3_PC, W3_TI = (
    _LBL[k] for k in ('o_type','o_xl','o_xh','o_y','o_vx','o_vy','o_st','w3_pc','w3_ti'))
CAM, SPRX, SPRY = _LBL['cam_x'], _LBL['spr_x'], _LBL['spr_y']
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
        gt = int(r[W3TAB_ADDR + int(r[W3_TI + i])]) if t == OBJ_W3 else 0x100 | t
        objs.append([gt, (wx - cam) & 0xFF, int(r[O_Y + i]), int(r[W3_PC + i]), int(r[O_ST + i]),
                     int(r[O_VX + i]), int(r[O_VY + i])])
    rows.append({"f": f, "cam": cam, "mx": int(r[SPRX]), "my": int(r[SPRY]), "objs": objs})
json.dump(rows, open(out, 'w'))
print("svtrace:", len(rows), "frames, final cam", rows[-1]["cam"])
