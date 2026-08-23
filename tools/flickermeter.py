#!/usr/bin/env python3
"""flickermeter -- count DISPLAYED frames where a live, on-screen W3 object's
sprite pixels are absent (the erase/draw straddle = the user's flicker).
For each frame and each OBJ_W3 slot fully on screen, look at the 16x16 rect
at its position: if it contains zero non-background pixels, that frame
FLICKERED for that object.  Prints flicker events per zone per 600 frames.
    python3 tools/flickermeter.py [rom]
"""
import subprocess, os, sys
import numpy as np
T=os.environ.get('CLAUDE_JOB_DIR','/tmp')+'/tmp'
ROM=sys.argv[1] if len(sys.argv)>1 else "build/super-mario-land-god.sv"
def run(frames,script,pokes=""):
    subprocess.run(["/tmp/svshot",ROM,"6",str(frames),"1",T+"/fm.bin",T+"/fm.ram",script,pokes],capture_output=True)
    return (np.fromfile(T+"/fm.ram",dtype=np.uint8).astype(int).reshape(-1,0x2000),
            np.fromfile(T+"/fm.bin",dtype=np.uint16).reshape(-1,160,160))
pin=",".join(f"0x1B:32@{f}" for f in range(204,896,4))
for tag,camv in (("two-cannon",0x480),("tokotoko",0x7D0),("ganchan",0x980)):
    R,F=run(900,"R900",f"0xB4:{camv&0xFF}@200,0xB5:{camv>>8}@200,0xA4:40@200,"+pin)
    sky=65535
    flick=0; obsv=0
    for i in range(280,880):
        r=R[i]
        cam=r[0xB4]|(r[0xB5]<<8)
        for k in range(10):
            if r[0xFDA+k]!=36: continue
            if r[0xBEB+k] in (22,23,24): continue   # cannon family hides in
            x=(r[0xFE4+k]|(r[0xFEE+k]<<8))-cam; y=r[0xFF8+k]  # the pipe (behind)
            if not (0<=x<=144 and 40<=y<=128): continue
            rect=F[i, y:y+16, x:x+16]
            if rect.size!=256: continue
            obsv+=1
            if int((rect!=sky).sum())<8: flick+=1
    print(f"{tag:12s} flicker-frames {flick} / {obsv} object-frames")
