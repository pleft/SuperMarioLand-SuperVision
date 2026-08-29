import subprocess, numpy as np, re, sys
lbl={m.group(2):int(m.group(1),16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)',open('build/rom.lbl').read())}
SX,SY,CAM,JS,RIDE,RESP,DTH=(lbl[k] for k in ('spr_x','spr_y','cam_x','jump_state','ride','respawn_req','death_anim'))
def expand(s):
    seq=[]
    for seg in s.strip().split(','):
        seq += [seg[0]]*int(seg[1:])
    return seq
def emit(seq):
    out=[];i=0
    while i<len(seq):
        j=i
        while j<len(seq) and seq[j]==seq[i]: j+=1
        out.append(f"{seq[i]}{j-i}"); i=j
    return ','.join(out)
route=open(sys.argv[1]).read()
seq=expand(route)
n=len(seq)
subprocess.run(['/tmp/svshot','build/super-mario-land.sv','9',str(n),'1','/tmp/ch.fb','/tmp/ch.ram',route,''],capture_output=True)
R=np.fromfile('/tmp/ch.ram',dtype=np.uint8).astype(int).reshape(-1,0x2000)
best=(-1,0)
for f in range(min(n,R.shape[0])):
    r=R[f]
    if r[RESP] or r[DTH] or r[SY]>=160: break
    safe = (r[JS]==0) or r[RIDE]
    x=(r[CAM]|(r[CAM+1]<<8))+r[SX]
    if safe and x>best[0]: best=(x,f)
x,f=best
open(sys.argv[2],'w').write(emit(seq[:f+1]))
print(f"prefix -> frame {f}, world x {x} (route was {n} frames)")
