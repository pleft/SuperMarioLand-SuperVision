#!/usr/bin/env python3
"""Rule 0b for the music sequencer: run the PORT under py65, trap every APU
register write, and diff against a faithful Python model of the 4-channel
player (squares + borrowed-square ch3 + noise drums) walking music.bin."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

def load():
    bin = open(os.path.join(ROOT, "build/audio/music.bin"), "rb").read()
    inc = open(os.path.join(ROOT, "build/audio/music.inc")).read()
    drums = int(re.search(r"MUS_DRUMS = (\d+)", inc).group(1))
    lists = []
    for c in range(4):
        lo = re.search(r"mus_l%d_lo: \.byte (.*)" % (c+1), inc).group(1).split(", ")
        lists.append(int(lo[0][1:]))          # track index 0 = MUS_LEVEL
    lt = int(re.search(r"MUS_T07_LT = (\d+)", inc).group(1))
    return bin, drums, lists, lt

class Ch:
    def __init__(s, bin, lst, lt):
        s.bin=bin; s.list=lst; s.lt=lt; s.pos=None; s.active=True
        s.wait=1; s.len=1; s.env=0; s.duty=0x40; s.vol=0; s.ectr=1
        s.pending_zero=True                   # mus_zero seeding
    def u16(s,o): return s.bin[o]|(s.bin[o+1]<<8)

def model(frames, rate=3):
    bin, drums, L, lt = load()
    ch=[Ch(bin,L[i],lt) for i in range(4)]
    ch[2].duty=0x60
    borrowed=[None]                            # ch3's square (0/4/None)
    sq_user=[0,0]
    writes=[]                                  # (frame, reg, val) reg names
    fr=[0]
    def free(sq):                              # no live SFX in this run
        return True
    def sq_wr(sq,reg,val): writes.append((fr[0],(sq,reg),val))
    def env_step(i,c):
        if not c.active or c.pos is None: return
        per=c.env&7
        if per==0 or c.vol==0: return
        c.ectr-=1
        if c.ectr: return
        c.ectr=per
        if c.env&8:
            if c.vol<15: c.vol+=1
        else: c.vol-=1
        wr_vol(i,c)
    def wr_vol(i,c):
        if i<2: sq_wr(i,"vd",c.vol|c.duty)
        elif i==2:
            if borrowed[0] is None: return
            si=borrowed[0]//4
            if sq_user[si]!=1: borrowed[0]=None; return
            sq_wr(si,"vd",c.vol|0x60)
        else: writes.append((fr[0],"nfv",c.vol|c.duty))
    def cell(i,c):
        while True:
            b=c.bin[c.pos]; c.pos+=1
            if b==0:
                while True:
                    e=c.u16(c.list); c.list+=2
                    if e==0:
                        # ANY channel's REAL END stops the WHOLE song ($6CB1)
                        for j,cc in enumerate(ch):
                            cc.pos=None; cc.vol=0
                        sq_wr(0,"vd",0x40); sq_wr(1,"vd",0x40)
                        writes.append((fr[0],"nfv",0))
                        borrowed[0]=None
                        return
                    if e==0xFE00:
                        # dormant: this channel off, the song continues
                        c.pos=None; c.vol=0
                        if i==2:
                            wr_vol(i,c); borrowed[0]=None
                        elif i==3: writes.append((fr[0],"nfv",c.duty))
                        else: sq_wr(i,"vd",0x40)
                        return
                    if e==0xFFFF:
                        c.list=c.u16(c.list); continue
                    c.pos=e; break
                continue
            if b==0x9D:
                if i!=3:
                    c.env=c.bin[c.pos]
                    if i<2: c.duty=((c.bin[c.pos+2]>>2)&0x30)|0x40
                c.pos+=3; continue
            if 0xA0<=b<=0xAF:
                c.len=c.bin[c.lt+(b&15)]; continue
            if b==1 and i!=3:
                c.wait=c.len; return
            if i==3:                            # drum
                o=drums+(b-1)*3
                fv,env,cut=c.bin[o],c.bin[o+1],c.bin[o+2]
                c.duty=fv&0xF0; c.vol=fv&15; c.env=env; c.ectr=max(1,env&7)
                c.cut=cut
                writes.append((fr[0],"nfv",fv))
            elif i==2:
                F=c.u16(b*2); F3=min(0x7FF,F*2+1)
                sq=None
                if ch[0].vol==0: sq=0
                elif ch[1].vol==0: sq=4
                if sq is None: borrowed[0]=None
                else:
                    borrowed[0]=sq; sq_user[sq//4]=1
                    sq_wr(sq//4,"flo",F3&0xFF); sq_wr(sq//4,"fhi",F3>>8)
                c.vol=c.env>>4; c.ectr=max(1,c.env&7)
                wr_vol(i,c)
            else:
                sq_user[i]=0
                F=c.u16(b*2)
                sq_wr(i,"flo",F&0xFF); sq_wr(i,"fhi",F>>8)
                c.vol=c.env>>4; c.ectr=max(1,c.env&7)
                wr_vol(i,c)
            c.wait=c.len; return
    def tick():
        for i,c in enumerate(ch):
            if c.pos is None and not c.pending_zero: continue
            if c.pending_zero:
                c.pending_zero=False; c.pos=None
                c.wait=1
                # emulate mus_zero: first tick pulls phrase 1
                # implemented by treating pos as "at a $00 byte"
            if i==3 and getattr(c,'cut',0):
                c.cut-=1
                if c.cut==0:
                    c.vol=0; wr_vol(i,c)
            env_step(i,c)
            c.wait-=1
            if c.wait==0:
                if c.pos is None:              # the mus_zero $00 fetch
                    while True:
                        e=c.u16(c.list); c.list+=2
                        if e==0:
                            for cc in ch: cc.pos=None; cc.vol=0
                            sq_wr(0,"vd",0x40); sq_wr(1,"vd",0x40)
                            writes.append((fr[0],"nfv",0))
                            break
                        if e==0xFE00: c.pos=None; c.active=False; break
                        if e==0xFFFF:
                            c.list=c.u16(c.list); continue
                        c.pos=e; break
                    if c.pos is None: continue
                cell(i,c)
    acc=0
    for f in range(frames):
        fr[0]=f
        tick()
        acc+=rate
        if acc>=61:
            acc-=61
            tick()
    return writes

def run_port(frames):
    from py65.devices.mpu65c02 import MPU
    mem=bytearray(0x10000)
    rom=open(os.path.join(ROOT,"build/super-mario-land.sv"),"rb").read()
    mem[0x8000:0x10000]=rom[:0x4000]+rom[-0x4000:]   # 64K image: [bank0][fixed] view (1-1)
    writes=[]; frame=[0]
    class W(bytearray):
        def __setitem__(s,i,v):
            if isinstance(i,int) and 0x2010<=i<=0x202A: writes.append((frame[0],i,v))
            super().__setitem__(i,v)
    wm=W(mem); mpu=MPU(); mpu.memory=wm
    def dma():
        if wm[0x200D]&0x80:
            s0=wm[0x2008]|(wm[0x2009]<<8); d=wm[0x200A]|(wm[0x200B]<<8)
            for i in range(wm[0x200C]*16): wm[(d+i)&0xFFFF]=wm[(s0+i)&0xFFFF]
            wm[0x200D]&=0x7F
    mpu.pc=wm[0xFFFC]|(wm[0xFFFD]<<8); wm[0x2020]=0xFF
    steps=0
    while frame[0]<frames:
        mpu.step(); steps+=1
        if steps%120_000==0:
            wm[0]=1; wm[1]=(wm[1]+1)&0xFF; frame[0]+=1
            if frame[0]==240: wm[0x2020]=0x7F
            if frame[0]==248: wm[0x2020]=0xFF
        dma()
    return writes

def main():
    frames=1200
    port=run_port(frames)
    # music starts at the first square write after Start
    f0=min(f for f,a,v in port if 0x2010<=a<=0x2017)
    span=frames-f0-2
    exp=model(span)
    NAME={0x2010:(0,"flo"),0x2011:(0,"fhi"),0x2012:(0,"vd"),
          0x2014:(1,"flo"),0x2015:(1,"fhi"),0x2016:(1,"vd"),0x2028:"nfv"}
    got=[( f-f0, NAME[a], v) for f,a,v in port if a in NAME and f>=f0]
    em=[(f,k,v) for f,k,v in exp]
    n=min(len(em),len(got)); ok=0; bad=None
    for i in range(n):
        if em[i][1]==got[i][1] and em[i][2]==got[i][2] and abs(em[i][0]-got[i][0])<=2: ok+=1
        elif bad is None: bad=i
    print(f"model vs port: {ok}/{n} register writes identical in order+value (±2f)")
    print(f"  (model {len(em)} writes, port {len(got)}; first divergence: {bad})")
    if bad is not None:
        for i in range(max(0,bad-3),min(n,bad+5)):
            print("   ", "OK " if em[i][1]==got[i][1] and em[i][2]==got[i][2] else "XX ", "exp",em[i],"got",got[i])

if __name__=="__main__":
    main()
