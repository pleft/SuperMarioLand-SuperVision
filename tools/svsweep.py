# Parallel script sweep on the real core: python3 tools/svsweep.py LEVEL base.txt "variant1" "variant2" ...
# Each variant is appended to the base script; prints (variant, final world x, feet, alive?, max x).
import sys, os, subprocess, tempfile, numpy as np
from concurrent.futures import ThreadPoolExecutor
level, base = sys.argv[1], open(sys.argv[2]).read().strip(); variants = sys.argv[3:]
rom = os.environ.get("SML_SV", "build/super-mario-land-god.sv"); shot = os.environ.get("SHOT", "/tmp/svshot")
def run(v):
    sc = base + "," + v; n = sum(int(s[1:]) for s in sc.split(','))
    fb = tempfile.mktemp(suffix=".fb"); ram = tempfile.mktemp(suffix=".ram")
    subprocess.run([shot, rom, level, str(n), "1", fb, ram, sc, os.environ.get("POKES", "")], capture_output=True)
    R = np.fromfile(ram, dtype=np.uint8).reshape(-1, 0x2000); os.remove(fb); os.remove(ram)
    cam = R[:, 0xB4].astype(int) | (R[:, 0xB5].astype(int) << 8); x = cam + R[:, 0xA4]; y = R[:, 0x1B].astype(int) + 16
    alive = int(y[-1]) < 170
    return v, int(x[-1]), int(y[-1]), alive, int(x.max())
with ThreadPoolExecutor(max_workers=os.cpu_count()) as ex:
    for v, x, y, alive, mx in ex.map(run, variants):
        print(f"{'OK ' if alive else 'die'} x{x:5d} feet{y:4d} max{mx:5d}  {v}")
