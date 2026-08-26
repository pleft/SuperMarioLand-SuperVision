# GB-only quick run: python3 tools/gbrun.py LEVEL "script" [STEP] [FROM]  -> (left, feet, cam) + objs (type, world x, y)
import sys, json, subprocess, os
level, script = sys.argv[1], sys.argv[2]; step = int(sys.argv[3]) if len(sys.argv) > 3 else 8; frm = int(sys.argv[4]) if len(sys.argv) > 4 else 0
S = os.environ.get("SCR", "/tmp"); sp = S + "/gbrun_script.txt"; open(sp, "w").write(script + "\n")
env = dict(os.environ); subprocess.run(["python3", "tools/gbtrace.py", level, sp, S + "/gbrun.json"], capture_output=True, env=env)
g = json.load(open(S + "/gbrun.json"))
for f in range(frm, len(g), step):
    a = g[f]; go = [(hex(o[0]), (o[1] + a['cam'] - 7) & 0xFFFF, o[2], o[3], o[4]) for o in a['objs']]
    print(f"f{f:4d} ({a['mx']+a['cam']-10:4d},{a['my']-6:3d}) cam{a['cam']:4d} {go}")
