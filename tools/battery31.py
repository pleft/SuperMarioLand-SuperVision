#!/usr/bin/env python3
"""The 3-1 verification battery (docs/41): every GB-measured behavior asserted
on the REAL core via svshot RAM pokes. Run after ANY W3 change:
    python3 tools/battery31.py
Each test prints PASS/FAIL; exit code 1 if any fail. GB reference values inline."""
import subprocess, os, sys, struct
import numpy as np
T=os.environ.get('CLAUDE_JOB_DIR','/tmp')+'/tmp'
os.makedirs(T,exist_ok=True)
TT=[0x03,0x0D,0x19,0x1C,0x1F,0x23,0x25,0x31,0x32,0x33,0x35,0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x40,0x41,0x45,0x47,0x49,0x4A,0x4B,0x4F,0x58,0x5A]
def run(rom,frames,script,pokes=""):
    subprocess.run(["/tmp/svshot",rom,"6",str(frames),"1",T+"/bt.bin",T+"/bt.ram",script,pokes],capture_output=True)
    return np.fromfile(T+"/bt.ram",dtype=np.uint8).astype(int).reshape(-1,0x2000)
NORM="build/super-mario-land.sv"; GOD="build/super-mario-land-god.sv"
fails=0
def chk(name,ok,detail=""):
    global fails
    print(("PASS " if ok else "FAIL ")+name+("  "+detail if detail else ""))
    if not ok: fails+=1

# 1. missile: falling stomp (3 phases), no hurt  [GB: stomp morphs $4B->$0D]
allok=True
for h0 in (54,62,70):
    R=run(NORM,520,".520",f"0xB4:0xF4@200,0xB5:0x01@200,0xA4:78@200,0x1B:72@200,0xA4:44@330,0x1B:{h0}@330")
    st=any(R[i][0xFDA+k]==36 and R[i][0xBEB+k]==1 for i in range(331,520) for k in range(10))
    hurt=any(R[i][0x8A] or R[i][0x7B] for i in range(331,520))
    allok &= (st and not hurt)
chk("missile falling-stomp (3 phases)",allok)

# 2. missile passes under STANDING Mario  [GB: nothing at dy=-6]
R=run(GOD,700,".700","0xB4:0xF4@200,0xB5:0x01@200,0xA4:78@200,0x1B:72@200")
morph=any(R[i][0xFDA+k]==36 and R[i][0xBEB+k]==1 for i in range(200,700) for k in range(10))
chk("missile standing pass-through",not morph)

# 3. missile faces Mario  [GB: F0 $40 before the morph]
R=run(GOD,620,".620","0xB4:0xF4@200,0xB5:0x01@200,0xA4:60@200,0x1B:96@200")
xs=[r[0xFE4+k]|(r[0xFEE+k]<<8) for i in range(210,620) for k in range(10)
    if (r:=R[i])[0xFDA+k]==36 and r[0xBEB+k]==24]
lok=bool(xs) and xs[-1]<xs[0]
R=run(GOD,620,".620","0xB4:0xF4@200,0xB5:0x01@200,0xA4:130@200,0x1B:96@200")
xs=[r[0xFE4+k]|(r[0xFEE+k]<<8) for i in range(210,620) for k in range(10)
    if (r:=R[i])[0xFDA+k]==36 and r[0xBEB+k]==24]
rok=bool(xs) and xs[-1]>xs[0]
chk("missile faces Mario (both sides)",lok and rok)

# 4. cannon ride + walk-off  [GB: feet on box top, falls at +11]
R=run(GOD,560,".330,R230","0xB4:0xF4@200,0xB5:0x01@200,0xA4:78@200,0x1B:72@200")
rode=any(R[i][0x5D] for i in range(210,330))
off=all(R[i][0x5D]==0 for i in range(430,560))
chk("cannon ride + walk-off",rode and off)

# 5. ledge landing stability  [zero jump_state flips while riding]
R=run(GOD,420,".420","0xB4:0x60@200,0xB5:0x03@200,0xA4:26@200,0x1B:40@200")
tr=sum(1 for i in range(207,400) if R[i][0x32]!=R[i-1][0x32])
chk("ledge landing stable",tr==0,f"js flips {tr}")

# 6. spikes hurt  [GB $181E: small dies, big shrinks, still lands]
pre=open(T+'/roomscript.txt').read() if os.path.exists(T+'/roomscript.txt') else None
if pre:
    n=sum(int(seg[1:]) for seg in pre.split(','))
    d=n+8
    R=run(NORM,n+140,pre+",.140",f"0xA4:92@{d},0x1B:40@{d}")
    small=any(R[i][0x8A] for i in range(n,len(R)))
    R=run(NORM,n+140,pre+",.140",f"0xA4:92@{d},0x1B:40@{d},0x50:1@{d-2}")
    big=any(R[i][0x7B] for i in range(n,len(R)))
    chk("spikes: small dies / big shrinks",small and big)
    # 7. unlisted $80 block  [GB: small hop only, big smash +50 & gone]
    R=run(NORM,n+220,pre+",.12,.8,A22,.70,A22,.70",f"0xA4:76@{d},0x1B:64@{d}")
    r0,r1=R[n+10],R[-1]
    small_ok=(r0[0x47]==r1[0x47]) and ((r0[0x49]|(r0[0x4A]<<8))==(r1[0x49]|(r1[0x4A]<<8)))
    R=run(NORM,n+220,pre+",.12,.8,A22,.70,A22,.70",f"0xA4:76@{d},0x1B:64@{d},0x50:1@{d-2}")
    r0,r1=R[n+10],R[-1]
    sc=( (r1[0x49]|(r1[0x4A]<<8)) - (r0[0x49]|(r0[0x4A]<<8)) )
    peak=min(int(R[i][0x1B]) for i in range(n+80,len(R)))
    big_ok=(sc==0x50) and peak<60
    chk("unlisted $80: hop small / smash big",small_ok and big_ok,f"big dscore {sc:x} peak {peak}")
else:
    print("SKIP room tests (no roomscript)")

# 8. boulder: rolls + gravity + ping-pong  [GB: 1.5px/f, y grounded, reverses]
R=run(NORM,900,".900","0xB4:0xD0@200,0xB5:0x07@200,0xA4:20@200,0x1B:96@200")
xs=[(i,r[0xFE4+k]|(r[0xFEE+k]<<8),r[0xFF8+k]) for i in range(205,900) for k in range(10)
    if (r:=R[i])[0xFDA+k]==36 and r[0xBEB+k]==7]
moved=xs and (max(x for _,x,_ in xs)-min(x for _,x,_ in xs))>60
grounded=xs and all(y==112 for _,_,y in xs[10:])
revs=0;d=0
for a,b in zip(xs,xs[1:]):
    nd=1 if b[1]>a[1] else (-1 if b[1]<a[1] else d)
    if d and nd!=d: revs+=1
    d=nd
chk("boulder rolls + grounded + ping-pong",bool(moved and grounded and revs>=2),f"revs {revs}")

# 9. boulder stomp chain  [GB: ->$40 +400 + Mario bounce; ~45 ticks; ->$0D; gone]
# The boulder's phase shifts a few frames with engine changes: SWEEP drop frames
# until one connects (a fixed frame made this test flaky, not the mechanic).
# scout-driven drop: the engine's speed changed twice (task #30) and every
# fixed drop frame/x went stale with it -- read the roller's own trajectory
# and drop Mario onto where it will be (lead = its direction * fall time).
Rs=run(NORM,920,".920","0xB4:0xD0@200,0xB5:0x07@200,0xA4:20@200,0x1B:96@200")
tj={}
for i in range(560,880):
    for k in range(10):
        if Rs[i][0xFDA+k]==36 and Rs[i][0xBEB+k]==7:
            cam=Rs[i][0xB4]|(Rs[i][0xB5]<<8)
            tj[i]=(Rs[i][0xFE4+k]|(Rs[i][0xFEE+k]<<8))-cam
ok=False; det=""
for f0 in sorted(tj)[::12][:8]:
    lead=tj.get(f0+16,tj[f0])
    dx=max(8,min(150,lead))
    R=run(NORM,920,".920",f"0xB4:0xD0@200,0xB5:0x07@200,0xA4:20@200,0x1B:96@200,0xA4:{dx}@{f0},0x1B:80@{f0}")
    chain=[]; prev=None
    for i in range(f0,920):
        r=R[i]
        for k in range(10):
            if r[0xFDA+k]==36 and TT[r[0xBEB+k]] in (0x31,0x40,0x41,0x0D):
                t=TT[r[0xBEB+k]]
                if prev!=(k,t): chain.append((i,t,r[0x49]|(r[0x4A]<<8))); prev=(k,t)
    types=[t for _,t,_ in chain]
    sc = next((s for _,t,s in chain if t==0x40),0) - (chain[0][2] if chain else 0)
    if (0x40 in types) and (0x0D in types) and sc==0x400:
        ok=True; det=f"drop@{f0} chain {[hex(t) for t in types]} dscore {sc:x}"; break
chk("boulder stomp -> $40 +400 -> crumble",ok,det or "no drop frame connected")

# 10. GANCHAN $47 (docs/41 + mariowiki): six $03 sky spawners (cols 155-215);
# the boulder is RIDEABLE and CARRIES Mario (phys1 $A2 bit7; GB capture: Mario's
# x tracks the boulder's exactly while standing), and its 2nd anim frame (param
# $47) is the SAME quad rotated 180 deg (display-list control bit5 = Y-flip,
# user-reported twice as "corrupted"). Pixel truth read off the framebuffer.
def _shot(rom,frames,script,pokes=""):
    subprocess.run(["/tmp/svshot",rom,"6",str(frames),"1",T+"/bt.bin",T+"/bt.ram",script,pokes],capture_output=True)
    return (np.fromfile(T+"/bt.ram",dtype=np.uint8).astype(int).reshape(-1,0x2000),
            np.fromfile(T+"/bt.bin",dtype=np.uint16).reshape(-1,160,160))
base="0xB4:0x80@200,0xB5:0x09@200,0xA4:8@200,0x1B:64@200"
Rr,Ff=_shot(GOD,620,".620",base)
recs=[]
for i in range(320,620):
    r=Rr[i]
    for k in range(10):
        if r[0xFDA+k]==36 and r[0xBEB+k]==21:
            cam=r[0xB4]|(r[0xB5]<<8)
            recs.append((i,r[0x103E+k],(r[0xFE4+k]|(r[0xFEE+k]<<8))-cam,r[0xFF8+k]))
Aa=[t for t in recs if t[1]==0x31 and 20<t[2]<130]
Bb=[t for t in recs if t[1]==0x47 and 20<t[2]<130]
flip_ok=False
if Aa and Bb:
    ta=next(t for t in Aa if 0<=t[2]<=144 and t[3]<=144)
    rot=Ff[ta[0],ta[3]:ta[3]+16,ta[2]:ta[2]+16][::-1,::-1]
    for tb in Bb:
        for dx in range(-3,4):
            for dy in range(-3,4):
                y0,x0=tb[3]+dy,tb[2]+dx
                if not(0<=x0<=144 and 0<=y0<=144): continue
                if int((rot!=Ff[tb[0],y0:y0+16,x0:x0+16]).sum())<=12: flip_ok=True; break
            if flip_ok: break
        if flip_ok: break
# drop frames LOCKED TO THE TRAJECTORY, not the clock: engine speed changes
# (task #30) shift where the boulder is at a given display frame, and fixed
# f0s went stale twice. Scout the boulder first, then drop where it will be.
Rs=run(GOD,700,".700","0xB4:0x80@200,0xB5:0x09@200,0xA4:8@200,0x1B:64@200")
cand=[]
for i in range(360,660):
    for k in range(10):
        if Rs[i][0xFDA+k]==36 and Rs[i][0xBEB+k]==21:
            cam=Rs[i][0xB4]|(Rs[i][0xB5]<<8)
            sx=(Rs[i][0xFE4+k]|(Rs[i][0xFEE+k]<<8))-cam
            if 12<sx<120: cand.append((i,sx,Rs[i][0xFF8+k]))
cand2=[]
byf={c[0]:c for c in cand}
for i,sx,yy in cand:
    j=byf.get(i+8)
    if j: cand2.append((i, j[1], j[2]))
cand=cand2[::15] or [(480,20,98),(490,20,98),(500,20,98)]
carry_ok=False; det10=""
for f0,sx,yb in cand[:8]:
    y0=max(24,yb-34)
    R=run(GOD,860,".860","0xB4:0x80@200,0xB5:0x09@200,0xA4:8@200,0x1B:64@200"+f",0xA4:{sx}@{f0},0x1B:{y0}@{f0}")
    best=[]; cur=[]
    for i in range(f0,860):
        if R[i][0x5D]: cur.append(i)
        else:
            if len(cur)>len(best): best=cur
            cur=[]
    if len(cur)>len(best): best=cur
    if len(best)<60: continue
    slot=R[best[0]][0x5D]-1
    if R[best[0]][0xBEB+slot]!=21: continue
    win=[i for i in best if 16<=R[i][0xA4]<=140]   # spr_x wraps at the screen
    if len(win)<60: continue                       # edge; measure only inside
    i0,i1=win[0],win[-1]
    bdx=(R[i1][0xFE4+slot]|(R[i1][0xFEE+slot]<<8))-(R[i0][0xFE4+slot]|(R[i0][0xFEE+slot]<<8))
    mdx=((R[i1][0xB4]|(R[i1][0xB5]<<8))+R[i1][0xA4])-((R[i0][0xB4]|(R[i0][0xB5]<<8))+R[i0][0xA4])
    if abs(bdx)>=20 and bdx==mdx:
        carry_ok=True; det10=f"ride {i1-i0+1}f dx {bdx}=={mdx}"; break
chk("ganchan: tumble frame rot180 + ride carries Mario",flip_ok and carry_ok,
    (det10 or "no long ride")+(" flip ok" if flip_ok else " FLIP MISSING"))

print("\n"+("ALL PASS" if fails==0 else f"{fails} FAILURES"))
sys.exit(1 if fails else 0)
