"""Sweep the GB-vs-port frame diff across a whole run of 2-3, to HUNT visual
artifacts instead of arguing about them.

    python3 tools/framesweep23.py [frames] [every]

Captures each side ONCE (one GB run, one port run), sampling the rendered
playfield every `every` frames, then diffs each pair with an alignment search
and reports the residual per sample. A visual artifact shows as a SPIKE above
the baseline; the worst sample's frames and diff are written to /tmp/fs_*.png.

Instrument laws that make this trustworthy (docs/35 E9/E10, and the header of
tools/framediff23.py): render the port from vxp/vyp (the sim runs no IRQ, so
$2002 is always 0), settle 2 frames after the GB reaches the level, and
quantise by FIXED luminance bands."""
import sys
import numpy as np
sys.path.insert(0, "tools")
FRAMES = int(sys.argv[1]) if len(sys.argv) > 1 else 600
EVERY  = int(sys.argv[2]) if len(sys.argv) > 2 else 20
Y0, Y1 = 16, 144

from pyboy import PyBoy
SC = "/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/c76a93a9-4c59-42f6-b474-1056dca20b06/scratchpad"
p = PyBoy(SC + "/sml_iddqd3.gb", window="null", sound_emulated=False)
p.set_emulation_speed(0); m = p.memory
for _ in range(400): p.tick(1, True)
for i in range(5):
    p.button_press("a"); p.tick(1, True); p.tick(1, True); p.button_release("a")
    for _ in range(8): p.tick(1, True)
assert m[0xFFE4] == 5, m[0xFFE4]
p.button_press("start")
for _ in range(4): p.tick(1, True)
p.button_release("start")
for f in range(1200):
    p.tick(1, True)
    if m[0xFFB3] == 0x0D: break
for _ in range(2): p.tick(1, True)
def gshot():
    a = np.asarray(p.screen.ndarray)[:, :, :3].astype(int).sum(axis=2)
    return 3 - np.digitize(a, [130, 380, 600])
gb = {0: gshot()}
for f in range(1, FRAMES + 1):
    m[0xC0D3] = 0xF8; m[0xDA15] = 5
    p.tick(1, True)
    if f % EVERY == 0: gb[f] = gshot()
p.stop()
print(f"GB: {len(gb)} samples", flush=True)

exec(open("/tmp/perf21.py").read().split("# boot with fake NMIs")[0], globals())
from svrender import render_vram, write_png
steps = 0
for _ in range(40_000_000):
    if mpu.pc == ML: break
    mpu.step(); steps += 1
    if steps % 120_000 == 0: mem[0] = 1; mem[1] = (mem[1] + 1) & 0xFF
    dma(); bank_check()
cl = sym('cur_level'); nl = sym('next_level'); HI = sym('hurt_inv')
mem[cl] = 4
sp = mpu.sp
mem[0x100 + sp] = (ML - 1) >> 8; mpu.sp -= 1
mem[0x100 + mpu.sp] = (ML - 1) & 0xFF; mpu.sp -= 1
mpu.pc = nl
for _ in range(40):
    mem[0] = 1; mem[1] = (mem[1] + 1) & 0xFF; until_ml()
def pframe():
    mem[HI] = 90
    mem[0x2020] = 0xFF; mem[0] = 1; mem[1] = (mem[1] + 1) & 0xFF
    mpu.step(); dma(); bank_check()
    for _ in range(9_000_000):
        if mpu.pc == ML: break
        mpu.step(); dma(); bank_check()
def pshot():
    return np.array(render_vram(mem[0x4000:0x6000], mem[sym('vxp')], mem[sym('vyp')],
                                palette=[0, 1, 2, 3]), dtype=int)
port = {0: pshot()}
for f in range(1, FRAMES + 1):
    pframe()
    if f % EVERY == 0: port[f] = pshot()
print(f"port: {len(port)} samples", flush=True)

def best_align(g, q):
    b = None
    for dx in range(-24, 25):
        a = g[Y0:Y1, max(0, dx):160 + min(0, dx)]
        c = q[Y0:Y1, max(0, -dx):160 + min(0, -dx)]
        if a.shape[1] < 100: continue
        n = (a != c).mean()
        if b is None or n < b[1]: b = (dx, n, a != c)
    return b
print("\n frame   shift   differing")
rows = []
for f in sorted(gb):
    if f not in port: continue
    dx, frac, dmask = best_align(gb[f], port[f])
    rows.append((f, dx, frac, dmask))
    print(f"  {f:4d}   {dx:+3d}px   {100*frac:5.2f}%", flush=True)
base = np.median([r[2] for r in rows])
worst = max(rows, key=lambda r: r[2])
print(f"\nbaseline {100*base:.2f}%   worst frame {worst[0]} at {100*worst[2]:.2f}% "
      f"({worst[2]/base:.1f}x baseline)", flush=True)
GREY = [(255,255,255),(170,170,170),(85,85,85),(0,0,0)]
f = worst[0]; d = worst[3]
write_png("/tmp/fs_gb.png",   [[GREY[v] for v in r] for r in gb[f][Y0:Y1]], scale=2)
write_png("/tmp/fs_port.png", [[GREY[v] for v in r] for r in port[f][Y0:Y1]], scale=2)
write_png("/tmp/fs_diff.png", [[(0,0,0) if d[y][x] else (255,255,255)
                                for x in range(d.shape[1])] for y in range(d.shape[0])], scale=2)
ys, xs = np.where(d)
if len(ys): print(f"worst-frame diff box: x {xs.min()}..{xs.max()} y {ys.min()+Y0}..{ys.max()+Y0}")
print("-> /tmp/fs_gb.png /tmp/fs_port.png /tmp/fs_diff.png", flush=True)
