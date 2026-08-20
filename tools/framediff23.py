"""FRAME-LEVEL GB-vs-port diff for 2-3.

    python3 tools/framediff23.py <frames>

Starts BOTH at the level start -- the GB through its own level select (A x5 +
START), the port through next_level -- and runs each for the same number of
frames with the same (no) input, then captures the
rendered frame from each, quantises to the 4 DMG shades and diffs the PLAYFIELD
(rows 16..143 -- both machines put a 16px status bar on top; the port's screen
is 160 tall vs the GB's 144, so the last 16 rows have no counterpart).

Writes /tmp/fd_gb.png, /tmp/fd_port.png and /tmp/fd_diff.png (differing pixels
in black) and prints the bounding box, so a visual artifact is localised to the
pixel instead of being argued about.

RENDER FROM THE ENGINE'S SCROLL SHADOW (vxph_ap/vyp_ap), not from $2002/$2003:
this harness fakes the NMI, and the NMI is what writes XSCROLL -- reading the
register makes every port frame render unscrolled, which looks exactly like the
port failing to scroll (it cost an afternoon).

ALIGN BY TIME, NOT BY REGISTER. Two GB variables were mis-mapped trying to
align on position: $C0AB is a streaming pointer whose lead over the view is not
constant, and $C202 is not the sub's screen x (it read 216 on a 160-wide
screen). Both sides autoscroll deterministically from a start that is verified
pixel-identical, so equal frame counts is the alignment that needs no
assumptions."""
import sys, os
sys.path.insert(0, "tools")
FRAMES = int(sys.argv[1]) if len(sys.argv) > 1 else 200

# ---------------- GB ----------------
from pyboy import PyBoy
SC = "/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/c76a93a9-4c59-42f6-b474-1056dca20b06/scratchpad"
p = PyBoy(SC + "/sml_iddqd3.gb", window="null", sound_emulated=False)
p.set_emulation_speed(0); m = p.memory
for _ in range(400): p.tick(1, True)
for i in range(5):                                  # level select: A x5 = 2-3
    p.button_press("a"); p.tick(1, True); p.tick(1, True); p.button_release("a")
    for _ in range(8): p.tick(1, True)
assert m[0xFFE4] == 5, f"level select landed on {m[0xFFE4]}"
p.button_press("start")
for _ in range(4): p.tick(1, True)
p.button_release("start")
for f in range(1200):                               # to the level's first frame
    p.tick(1, True)
    if m[0xFFB3] == 0x0D: break
for _ in range(2): p.tick(1, True)                  # let it actually RENDER one
                                                    # (capturing on the state change
                                                    #  itself yields a blank screen)
for f in range(FRAMES):                             # then N frames, no input
    m[0xC0D3] = 0xF8; m[0xDA15] = 5
    p.tick(1, True)
print(f"GB   {FRAMES} frames from the level start; $C0AB={m[0xC0AB]|(m[0xC0AC]<<8)} ({(m[0xC0AB]|(m[0xC0AC]<<8))*16}px)", flush=True)
import numpy as np
sh = np.asarray(p.screen.ndarray)[:, :, :3].astype(int).sum(axis=2)   # luminance
p.stop()
# quantise to the four DMG shades by FIXED luminance bands: keying off the shades
# that happen to be present silently collapses a uniform frame to all-zero
gb_px = np.digitize(sh, [130, 380, 600])            # 0=darkest band .. 3=lightest
gb_px = 3 - gb_px                                   # -> 0 = lightest, like the port
assert gb_px.max() > 0, "GB frame is uniform -- capture is blank"


# ---------------- port ----------------
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
CAM = sym('cam_x'); SX = sym('spr_x'); SY = sym('spr_y')
def pframe():
    mem[HI] = 90
    mem[0x2020] = 0xFF; mem[0] = 1; mem[1] = (mem[1] + 1) & 0xFF
    mpu.step(); dma(); bank_check()
    for _ in range(9_000_000):
        if mpu.pc == ML: break
        mpu.step(); dma(); bank_check()
for f in range(FRAMES):
    pframe()
print(f"port {FRAMES} frames from the level start; cam_x={mem[CAM]|(mem[CAM+1]<<8)}", flush=True)
rows = render_vram(mem[0x4000:0x6000], mem[sym('vxp')], mem[sym('vyp')], palette=[0, 1, 2, 3])
port_px = np.array(rows, dtype=int)

np.savez("/tmp/fd_arrays.npz", gb=gb_px, port=port_px)   # so alignment can be
                                                          # re-searched without
                                                          # re-capturing
# ---------------- diff ----------------
# Find the alignment rather than trusting the camera mapping: slide the port
# frame over the GB frame and take the shift with the fewest differing pixels.
best=None
for dx in range(-160, 161, 1):
    a = gb_px[16:144, max(0,dx):160+min(0,dx)]
    b = port_px[16:144, max(0,-dx):160+min(0,-dx)]
    if a.shape[1] < 40: continue
    n = (a != b).sum() / a.size
    if best is None or n < best[1]: best = (dx, n, a.size)
print(f"best horizontal alignment: port is {best[0]:+d}px vs the GB, "
      f"{100*best[1]:.1f}% of pixels still differ there", flush=True)
Y0, Y1 = 16, 144
g = gb_px[Y0:Y1, :]; q = port_px[Y0:Y1, :]
d = (g != q)
print(f"\nplayfield rows {Y0}..{Y1-1}: {d.sum()} of {d.size} pixels differ "
      f"({100.0*d.sum()/d.size:.1f}%)", flush=True)
if d.any():
    ys, xs = np.where(d)
    print(f"  bounding box: x {xs.min()}..{xs.max()}  y {ys.min()+Y0}..{ys.max()+Y0}", flush=True)
    per_row = d.sum(axis=1)
    worst = np.argsort(per_row)[::-1][:5]
    print("  worst rows:", [(int(r)+Y0, int(per_row[r])) for r in worst if per_row[r]], flush=True)
GREY = [(255,255,255),(170,170,170),(85,85,85),(0,0,0)]
write_png("/tmp/fd_gb.png",   [[GREY[v] for v in row] for row in gb_px[Y0:Y1]], scale=2)
write_png("/tmp/fd_port.png", [[GREY[v] for v in row] for row in port_px[Y0:Y1]], scale=2)
write_png("/tmp/fd_diff.png", [[(0,0,0) if d[y][x] else (255,255,255)
                                for x in range(d.shape[1])] for y in range(d.shape[0])], scale=2)
print("-> /tmp/fd_gb.png /tmp/fd_port.png /tmp/fd_diff.png", flush=True)
