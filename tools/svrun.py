# Port-only quick run (twin of gbrun): python3 tools/svrun.py LEVEL "script" [STEP] [FROM]
# prints (left, feet, cam) + objs (type, world x, y[+24 for engine types = GB convention], pc, param)
import sys, json, subprocess, os
level, script = sys.argv[1], sys.argv[2]; step = int(sys.argv[3]) if len(sys.argv) > 3 else 8; frm = int(sys.argv[4]) if len(sys.argv) > 4 else 0
S = os.environ.get("SCR", "/tmp"); sp = S + "/svrun_script.txt"; open(sp, "w").write(script + "\n")
subprocess.run(["python3", "tools/svtrace.py", level, sp, S + "/svrun.json"], capture_output=True)
g = json.load(open(S + "/svrun.json"))
for f in range(frm, len(g), step):
    a = g[f]; go = [(hex(o[0] & 0xFF), (o[1] - 256 if o[1] > 200 else o[1]) + a['cam'], o[2] + (24 if o[0] & 0x100 else 0), o[3], o[4]) for o in a['objs']]  # screen x is a byte: left-of-camera wraps
    print(f"f{f:4d} ({a['mx']+a['cam']:4d},{a['my']+16:3d}) cam{a['cam']:4d} {go}")
