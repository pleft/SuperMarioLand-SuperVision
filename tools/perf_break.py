# py65 profiler: measure CYCLES PER FRAME through a big-Mario brick break (col 68, row 7).
# Frame budget on the SV: 4MHz / 61Hz NMI = ~65,574 cycles. Frames over budget = the flicker.
# Also PC-samples the worst frame and prints a per-routine cycle profile.
from py65.devices.mpu65c02 import MPU
import re, bisect

dbg = open("build/dbg.txt").read()
def sym(n):
    m = re.search(r'name="%s",[^\n]*val=(0x[0-9A-Fa-f]+)' % n, dbg)
    return int(m.group(1), 16)

# all absolute code labels, for the profile buckets
labels = sorted(set(
    (int(v, 16), n) for n, v in re.findall(r'name="([A-Za-z_@][A-Za-z0-9_]*)",addrsize=absolute[^\n]*val=(0x[0-9A-Fa-f]+)', dbg)
    if int(v, 16) >= 0xC000))
label_addrs = [a for a, _ in labels]
def bucket(pc):
    i = bisect.bisect_right(label_addrs, pc) - 1
    return labels[i][1] if i >= 0 else hex(pc)

ML = sym('main_loop')
SPRX, SPRY, BIG = sym('spr_x'), sym('spr_y'), sym('mario_big')
CAMX, FBC = sym('cam_x'), sym('fb_col0')
OT = sym('o_type')

rom = open("build/super-mario-land.sv", "rb").read()
mem = bytearray(0x10000); mem[0x8000:0x10000] = rom
mpu = MPU(); mpu.memory = mem
def do_dma():
    src = mem[0x2008] | (mem[0x2009] << 8); dst = mem[0x200A] | (mem[0x200B] << 8); n = mem[0x200C] * 16
    for i in range(n): mem[(dst + i) & 0xFFFF] = mem[(src + i) & 0xFFFF]
mem[0x2020] = 0xFF
mpu.pc = mem[0xFFFC] | (mem[0xFFFD] << 8)
for _ in range(8_000_000):
    if mpu.pc == ML: break
    mpu.step()

# big Mario on the ground under the brick at col 68 row 7:
# feet_col = (cam_x + spr_x + 8) >> 3 = 68  ->  cam_x = 68*8 - 48 = 496, spr_x = 40
mem[BIG] = 1
mem[CAMX] = 496 & 0xFF; mem[CAMX + 1] = 496 >> 8
mem[FBC] = 62; mem[FBC + 1] = 0
mem[SPRX] = 40; mem[SPRY] = 88

BUDGET = 4_000_000 // 61
def run_frame(profile=None):
    mem[1] = (mem[1] + 1) & 0xFF          # frame_count (fake NMI)
    mem[0] = 1                            # frame_flag
    c0 = mpu.processorCycles
    n = 0
    while n < 4_000_000:
        pcyc = mpu.processorCycles
        pc = mpu.pc
        mpu.step(); n += 1
        if profile is not None:
            profile[bucket(pc)] = profile.get(bucket(pc), 0) + (mpu.processorCycles - pcyc)
        if mem[0x200D] & 0x80: do_dma(); mem[0x200D] &= 0x7F
        if mpu.pc == ML and mem[0] == 0: break
    return mpu.processorCycles - c0

print(f"budget/frame = {BUDGET} cycles")
worst = (0, -1)
cyc_log = []
def pad(f):
    # bonk col 68 (f2), walk right to col 70, bonk again mid-shard-flight (~f26)
    if f in (2, 3): return 0xDF                    # A
    if 8 <= f < 24: return 0xFE                    # Right
    if f in (26, 27): return 0xDF                  # A again
    return 0xFF
for f in range(150):
    mem[0x2020] = pad(f)
    c = run_frame()
    types = ''.join('%x' % mem[OT + i] for i in range(8))
    cyc_log.append((f, c, types))
    if c > worst[0]: worst = (c, f, types)
    over = "  <-- OVER" if c > BUDGET else ""
    if c > BUDGET or types != '00000000' or f < 6:
        print(f"f{f:3}  {c:6} cyc  obj={types}{over}")

print(f"\nworst frame: f{worst[1]} = {worst[0]} cyc ({100*worst[0]//BUDGET}% of budget)")
# re-run same scenario and profile the worst frame
mem2 = bytearray(0x10000); mem2[0x8000:0x10000] = rom
mpu.memory = mem = mem2
mpu.pc = mem[0xFFFC] | (mem[0xFFFD] << 8)
mem[0x2020] = 0xFF
for _ in range(8_000_000):
    if mpu.pc == ML: break
    mpu.step()
mem[BIG] = 1
mem[CAMX] = 496 & 0xFF; mem[CAMX + 1] = 496 >> 8
mem[FBC] = 62; mem[FBC + 1] = 0
mem[SPRX] = 40; mem[SPRY] = 88
prof = None
for f in range(worst[1] + 1):
    mem[0x2020] = pad(f)
    p = {} if f == worst[1] else None
    run_frame(profile=p)
    if p is not None: prof = p
print(f"\nprofile of f{worst[1]} (top 14 by cycles):")
for name, cyc in sorted(prof.items(), key=lambda kv: -kv[1])[:14]:
    print(f"  {name:24} {cyc:6} cyc  {100*cyc//worst[0]:3}%")
