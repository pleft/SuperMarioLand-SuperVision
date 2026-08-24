#!/usr/bin/env python3
"""test_aux2 -- bit-exact unit tests for the v2 GROUP composer (docs/42).
One stash entry with 4 tiles at various flips/offsets on a sky background;
aux_group composes the box; every cell is compared to a python mirror."""
import sys, re
sys.path.insert(0,'tools')
from svharness import Harness
h=Harness(); h.boot_to_game()
lbl=open('build/w3aux.lbl').read()
sym={n:int(a,16) for a,n in re.findall(r'al 00([0-9A-F]{4}) \.([A-Za-z_][A-Za-z0-9_]*)$',lbl,re.M)}
def map8(): h.mem[0x2022]=0; h.mem[0x2021]=8; h._bank_check(); h.mem[0x2022]=0x0F
def call(addr):
    h.mpu.sp=0xF0; h.mem[0x1F1]=0xFD; h.mem[0x1F2]=0xFF; h.mpu.pc=addr
    for _ in range(400000):
        h.mpu.step()
        if h.mpu.pc>=0xFFF0: return
    raise SystemExit("runaway")
RING_B=0x11F0
def cell_addr(dcol,dy):
    ring=h.mem[RING_B]|(h.mem[RING_B+1]<<8); return ((dy*48+dcol+ring)%0x1FE0)+0x4000
def read_cell(dcol,dy):
    a=cell_addr(dcol,dy); return [h.mem[a+r*0x30+b] for r in range(8) for b in range(2)]
def shifted(row2,dx):
    sub=dx&3; case=(dx+8)>>2; b0,b1=row2
    if sub==0: s0,s1,s2=b0,b1,0
    else:
        lo=lambda b:h.mem[0x0200+sub*256+b]; hi=lambda b:h.mem[0x0600+sub*256+b]
        s0=lo(b0); s1=hi(b0)|lo(b1); s2=hi(b1)
    return {0:[(s2,0)],1:[(s1,0),(s2,1)],2:[(s0,0),(s1,1)],3:[(s0,1)]}[case]
def mix(buf,idx,s):
    if s==0: return
    m=h.mem[0x0600+s]; buf[idx]=(buf[idx]&(m^0xFF))|s
def flipped(px,fl):
    rows=[px[r*2:r*2+2] for r in range(8)]
    if fl&1: rows=[[h.mem[0x0BFA+b1],h.mem[0x0BFA+b0]] for b0,b1 in rows]   # revpix
    if fl&2: rows=rows[::-1]
    return [b for r in rows for b in r]
def ref(box,tiles):
    out={}
    for rj in range(box['rows']):
        for ci in range(box['cols']):
            buf=[0]*16
            for tx,ty,px,fl in tiles:
                dx,dy=tx-ci*8,ty-rj*8
                if not(-8<dx<8 and -8<dy<8): continue
                fp=flipped(px,fl)
                for r in range(8):
                    br=r+dy
                    if not(0<=br<8): continue
                    for s,c in shifted(fp[r*2:r*2+2],dx): mix(buf,br*2+c,s)
            out[(ci,rj)]=buf
    return out
E=0x1C70  # slot 0 entry
TILE=[0xC3,0x00,0x81,0x00,0x81,0x00,0xFF,0xFC,0xFF,0x03,0x81,0x00,0x81,0x00,0xC3,0xC0]
TILE2=[0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0x0F,0xF0]
map8()
for i in range(256): h.mem[0x0200+i]=0xEE          # poison page 0 (column cache)
# page-8 mirror: put tiles $A0/$A1 at $A600/$A610
for j,b in enumerate(TILE): h.mem[0xA600+j]=b
for j,b in enumerate(TILE2): h.mem[0xA610+j]=b
fails=0
def chk(n,ok):
    global fails; print(("PASS " if ok else "FAIL ")+n); fails+=(not ok)
def setup(box,tiles):
    h.mem[0x01C6]=box['dcol0']; h.mem[0x01C7]=box['dy0']; h.mem[0x01C8]=box['cols']; h.mem[0x01C9]=box['rows']
    h.mem[0x01CC]=0; h.mem[0x01CE]=0
    for k in range(10):
        e=0x1C70+k*20 if k<7 else 0x1FA0+(k-7)*20
        for j in range(20): h.mem[e+j]=0
    h.mem[E]=len(tiles); h.mem[E+1]=box['dcol0']; h.mem[E+2]=box['dy0']; h.mem[E+3]=box['cols']; h.mem[E+4]=box['rows']
    fl=0
    for t,(tx,ty,px,f,tid) in enumerate(tiles):
        h.mem[E+5+t]=tid; h.mem[E+9+t]=tx&0xFF; h.mem[E+13+t]=ty&0xFF; fl|=(f&3)<<(2*t)
    h.mem[E+17]=fl
    # cache: sky for the box columns (fb_col0 + dcol/2), all rows
    fb=h.mem[0xB6]|(h.mem[0xB7]<<8)
    for c in range(box['cols']):
        col=fb+(box['dcol0']//2)+c; s=(col&15)
        h.mem[0x1F80+2*s]=col&0xFF; h.mem[0x1F81+2*s]=col>>8
        for r in range(16): h.mem[0x0200+s*16+r]=0x2C
for name,box,tiles in (
    ("no flips 3x3", {'dcol0':10,'dy0':64,'cols':3,'rows':3}, [(3,5,TILE,0,0xA0),(11,5,TILE2,0,0xA1),(3,13,TILE2,0,0xA1),(11,13,TILE,0,0xA0)]),
    ("x-flip",       {'dcol0':10,'dy0':64,'cols':3,'rows':3}, [(2,1,TILE,1,0xA0),(10,1,TILE2,1,0xA1),(2,9,TILE,1,0xA0),(10,9,TILE2,1,0xA1)]),
    ("y-flip",       {'dcol0':10,'dy0':64,'cols':3,'rows':3}, [(5,6,TILE,2,0xA0),(13,6,TILE2,2,0xA1),(5,14,TILE,2,0xA0),(13,14,TILE2,2,0xA1)]),
    ("xy-flip (rot180)", {'dcol0':10,'dy0':64,'cols':3,'rows':3}, [(0,0,TILE,3,0xA0),(8,0,TILE2,3,0xA1),(0,8,TILE2,3,0xA1),(8,8,TILE,3,0xA0)]),
):
    setup(box,tiles)
    call(sym['aux_group'])
    want=ref(box,[(tx,ty,px,f) for tx,ty,px,f,_ in tiles])
    bad=[(ci,rj) for (ci,rj),w in want.items() if read_cell(box['dcol0']+ci*2,box['dy0']+rj*8)!=w]
    if bad:
        ci,rj=bad[0]; print("   first bad cell",bad[0],"got",bytes(read_cell(box['dcol0']+ci*2,box['dy0']+rj*8)).hex(),"want",bytes(want[(ci,rj)]).hex())
    chk(name,not bad)
print("\n"+("ALL PASS" if not fails else f"{fails} FAILURES")); sys.exit(1 if fails else 0)
