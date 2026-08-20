"""2-3 GB-vs-PORT DIFFERENTIAL (tools/diff23.py).

    python3 tools/diff23.py <camera_px> <frames>      e.g. 640 400

Drives the real GB (PyBoy) and the port (py65) and compares them frame by
frame. FOUR of my own bugs were found with this before any port bug was:
  - the two sides did not start together
  - the GB warp inherits the title's camera (all levels "start" at 192px)
  - the GB sub position was captured AFTER the run, not at the alignment
  - a FREED GB slot reads $FF, not $00, so empty slots counted as objects
Treat a divergence as the instrument's until proven otherwise (law E5).

2-3 DIFFERENTIAL, aligned on the CAMERA (the level's clock) rather than on a
level start the warp cannot give cleanly. Both sides are advanced to the same
camera, the port's sub is put where the GB's is, then both run the SAME input
and every frame is compared. Divergences from there are the PORT's.
Coord map: port spr_x = GB $C202-8, port spr_y = GB $C201-16, port o_y = GB y-24."""
import sys, pickle
sys.path.insert(0,"tools")
TARGET = int(sys.argv[1]) if len(sys.argv)>1 else 640      # camera px to align at
FRAMES = int(sys.argv[2]) if len(sys.argv)>2 else 400

from pyboy import PyBoy
SC="/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/c76a93a9-4c59-42f6-b474-1056dca20b06/scratchpad"
p=PyBoy(SC+"/sml_iddqd3.gb", window="null", sound_emulated=False)
p.set_emulation_speed(0); m=p.memory
for _ in range(400): p.tick(1,True)
p.button_press("start")
for _ in range(10): p.tick(1,True)
p.button_release("start")
for _ in range(240): p.tick(1,True)
m[0xFFE4]=4; m[0xFFB4]=0x22; m[0xFFB3]=0x08
def gcam(): return (m[0xC0AB]|(m[0xC0AC]<<8))*16
for f in range(4000):
    m[0xC0D3]=0xF8; m[0xDA15]=5                 # keep him alive; no input
    p.tick(1,True)
    if m[0xFFB3]==0x0D and gcam() >= TARGET: break
gb_start=(m[0xC202], m[0xC201])              # AT the alignment (was captured after)
print(f"GB aligned at cam {gcam()} sub {gb_start} state ${m[0xFFB3]:02X}", flush=True)
gb=[]
for f in range(FRAMES):
    m[0xC0D3]=0xF8
    p.tick(1,True)
    objs=[(m[0xD100+16*s], m[0xD100+16*s+3]+gcam(), m[0xD100+16*s+2])
          for s in range(10) if m[0xD100+16*s] not in (0x00, 0xFF)]
    gb.append((m[0xC202], m[0xC201], gcam(), m[0xFFB3], sorted(objs)))
p.stop()
print(f"GB: {FRAMES} frames", flush=True)

exec(open("/tmp/perf21.py").read().split("# boot with fake NMIs")[0], globals())
steps=0
for _ in range(40_000_000):
    if mpu.pc==ML: break
    mpu.step(); steps+=1
    if steps%120_000==0: mem[0]=1; mem[1]=(mem[1]+1)&0xFF
    dma(); bank_check()
cl=sym('cur_level'); nl=sym('next_level'); HI=sym('hurt_inv')
mem[cl]=4
sp=mpu.sp
mem[0x100+sp]=(ML-1)>>8; mpu.sp-=1
mem[0x100+mpu.sp]=(ML-1)&0xFF; mpu.sp-=1
mpu.pc=nl
for _ in range(40):
    mem[0]=1; mem[1]=(mem[1]+1)&0xFF; until_ml()
OT=sym('o_type'); OXL=sym('o_xl'); OXH=sym('o_xh'); OY=sym('o_y')
SX=sym('spr_x'); SY=sym('spr_y'); CAM=sym('cam_x'); DA=sym('death_anim')
def pcam(): return mem[CAM]|(mem[CAM+1]<<8)
def pframe():
    mem[HI]=90
    mem[0x2020]=0xFF; mem[0]=1; mem[1]=(mem[1]+1)&0xFF
    mpu.step(); dma(); bank_check()
    for _ in range(9_000_000):
        if mpu.pc==ML: break
        mpu.step(); dma(); bank_check()
for f in range(6000):
    if pcam() >= TARGET: break
    pframe()
mem[SX]=gb_start[0]-8; mem[SY]=gb_start[1]-16     # same sub position as the GB
print(f"port aligned at cam {pcam()} sub ({mem[SX]},{mem[SY]})", flush=True)
port=[]
for f in range(FRAMES):
    pframe()
    objs=[(mem[OT+s], (mem[OXL+s]|(mem[OXH+s]<<8)), mem[OY+s])
          for s in range(10) if mem[OT+s]]
    port.append((mem[SX], mem[SY], pcam(), mem[DA], sorted(objs)))
print(f"port: {FRAMES} frames", flush=True)
pickle.dump({"gb":gb,"port":port}, open("/tmp/diff23b.pkl","wb"))

print("\n f   GB cam  port cam   GB sub      port sub    objs G/P")
first=None
for f in range(FRAMES):
    gx,gy,gc,gs,go = gb[f]
    px,py,pc,pd,po = port[f]
    if f%50==0:
        print(f"{f:4d}  {gc:6d}  {pc:6d}   ({gx-8:3d},{gy-16:3d})   ({px:3d},{py:3d})   "
              f"{len(go)}/{len(po)}", flush=True)
        print(f"        GB   {[(hex(t),x,y-24) for t,x,y in go]}", flush=True)
        print(f"        port {[(t,x,y) for t,x,y in po]}", flush=True)
    bad=[]
    if abs(pc-gc)>16: bad.append(f"CAMERA {pc} vs {gc}")
    if abs(px-(gx-8))>2: bad.append(f"sub x {px} vs {gx-8}")
    if abs(py-(gy-16))>2: bad.append(f"sub y {py} vs {gy-16}")
    if pd and gs==0x0D: bad.append("PORT DIED, GB ALIVE")
    if bad and first is None:
        first=f
        print(f"\n*** DIVERGENCE f{f}: " + "; ".join(bad), flush=True)
        print(f"    GB   objs {[(hex(t),x,y) for t,x,y in go]}", flush=True)
        print(f"    port objs {[(t,x,y) for t,x,y in po]}", flush=True)
if first is None: print(f"\nno divergence in {FRAMES} frames", flush=True)
