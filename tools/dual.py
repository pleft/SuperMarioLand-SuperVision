# Run one pad script on the GB (gbtrace) and the port (svtrace); print Mario as
# (world left, feet) every STEP frames plus every object (type, world x, y).
#   python3 tools/dual.py LEVEL "R2,J8,R40" [STEP]
import sys, json, subprocess, os
level, script = sys.argv[1], sys.argv[2]; step = int(sys.argv[3]) if len(sys.argv) > 3 else 6
S = os.environ.get("SCR", "/tmp"); sp = S + "/dual_script.txt"; open(sp, "w").write(script + "\n")
subprocess.run(["python3", "tools/gbtrace.py", level, sp, S + "/dual_gb.json"], capture_output=True)
subprocess.run(["python3", "tools/svtrace.py", level, sp, S + "/dual_sv.json"], capture_output=True)
g = json.load(open(S + "/dual_gb.json")); s = json.load(open(S + "/dual_sv.json"))
for f in range(0, min(len(g), len(s)), step):
    a, b = g[f], s[f]
    go = [(hex(o[0]), (o[1] + a['cam'] - 7) & 0xFFFF, o[2]) for o in a['objs']]
    so = [(hex(o[0] & 0xFF), o[1] + b['cam'], o[2]) for o in b['objs']]
    print(f"f{f:4d} GB ({a['mx']+a['cam']-10:4d},{a['my']-6:3d}) cam{a['cam']:4d} {go}")
    print(f"      SV ({b['mx']+b['cam']:4d},{b['my']+16:3d}) cam{b['cam']:4d} {so}")
