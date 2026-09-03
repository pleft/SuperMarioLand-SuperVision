# ride-aware sweep: prints final ride/js and whether Mario ends SAFE (grounded or riding)
import sys, os, subprocess, tempfile, re, numpy as np
from concurrent.futures import ThreadPoolExecutor
lbl={m.group(2):int(m.group(1),16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)',open('build/rom.lbl').read())}
SX,SY,CAM,JS,RIDE=(lbl[k] for k in ('spr_x','spr_y','cam_x','jump_state','ride'))
level, base = sys.argv[1], open(sys.argv[2]).read().strip(); variants = sys.argv[3:]
rom = os.environ.get("SML_SV","build/super-mario-land.sv")
def run(v):
    sc = base + "," + v; n = sum(int(s[1:]) for s in sc.split(','))
    fb=tempfile.mktemp(suffix=".fb"); ram=tempfile.mktemp(suffix=".ram")
    subprocess.run(["/tmp/svshot",rom,level,str(n),"1",fb,ram,sc,""],capture_output=True)
    R=np.fromfile(ram,dtype=np.uint8).astype(int).reshape(-1,0x2000); os.remove(fb); os.remove(ram)
    r=R[-1]; x=(r[CAM]|(r[CAM+1]<<8))+r[SX]; feet=r[SY]+16
    safe = feet<160 and (r[JS]==0 or r[RIDE])
    return v,x,feet,r[JS],r[RIDE],safe
with ThreadPoolExecutor(max_workers=os.cpu_count()) as ex:
    for v,x,feet,js,ride,safe in ex.map(run,variants):
        print(f"{'SAFE' if safe else '....'} x{x:5d} feet{feet:4d} js{js} ride{ride}  {v}")
