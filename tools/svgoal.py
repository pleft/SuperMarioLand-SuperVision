# Replay a pad script on the real core and report whether Mario reached the goal
# (goal_phase != 0), plus his final world x/y -- the 3-2 ship gate's yes/no.
#   python3 tools/svgoal.py LEVEL script.txt [extra letters, e.g. R300]
import sys, os, subprocess, numpy as np
level, script = int(sys.argv[1]), sys.argv[2]
extra = sys.argv[3] if len(sys.argv) > 3 else ""
rom = os.environ.get("SML_SV", "build/super-mario-land-god.sv")
text = open(script).read().strip() + ("," + extra if extra else "")
seq = sum(([seg[0]] * int(seg[1:]) for seg in text.split(',')), [])
subprocess.run([os.environ.get("SHOT", "/tmp/svshot"), rom, str(level), str(len(seq)), "1",
                "/tmp/svgoal_fb.bin", "/tmp/svgoal_ram.bin", text], check=True, capture_output=True)
R = np.fromfile("/tmp/svgoal_ram.bin", dtype=np.uint8).reshape(-1, 0x2000)
gp = [int(r[0x5A]) for r in R]
first = next((i for i, g in enumerate(gp) if g), None)
r = R[-1]; cam = int(r[0xB4]) | (int(r[0xB5]) << 8)
print(f"frames {len(seq)}: final x {cam + int(r[0xA4])} y {int(r[0x1B])} respawn {int(r[0x39])} "
      f"death {int(r[0x8A])} goal_phase {gp[-1]}" + (f"  GOAL at frame {first}" if first is not None else "  (no goal)"))
