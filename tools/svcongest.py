# Congestion survey on the real core: warp to each checkpoint of LEVEL, play a
# fixed run/jump/fire script, and report per 128px camera bin the logic-stall
# rate (timer_sub unchanged across a display frame while Mario is on screen and
# unfrozen -- i.e. the main loop overran the frame), the mean live-object count
# and which types were present.  python3 tools/svcongest.py LEVEL [ROM]
import sys, re, subprocess, collections, numpy as np
lvl = int(sys.argv[1]); rom = sys.argv[2] if len(sys.argv) > 2 else "build/super-mario-land.sv"
S = "/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/407973b1-4713-4577-a0e2-b3e1ebdabcd8/scratchpad"
lbl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open('build/rom.lbl').read())}
ot, ti, ts = lbl['o_type'], lbl['w3_ti'], lbl['timer_sub']
frz = [lbl[n] for n in ('mario_grow', 'mario_shrink', 'death_anim', 'goal_phase', 'bonus_phase', 'pipe_phase')]
page = {6: 1, 7: 1, 8: 1, 9: 9, 10: 9, 11: 11}.get(lvl); kit = {6: 'w3code', 7: 'w3code', 8: 'w3code', 9: 'w4code', 10: 'w4code', 11: 'w43code'}.get(lvl)
if kit:
    kl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open(f'build/{kit}.lbl').read())}
    tab = list(open(rom, 'rb').read()[page * 0x8000 + kl['w3_typetab'] - 0x8000:][:48])
else: tab = [0] * 48        # Worlds 1-2: no VM types
play = ",".join(["R30,J16,.6,F12,Q16,.8"] * 24)
bins = collections.defaultdict(lambda: [0, 0, 0, collections.Counter()])   # frames, stalls, objsum, types
for ck in (0, 640, 1280, 1920, 2240):
    script = (".100,.300," if ck else ".40,") + play
    pk = f"0xB4:{(ck+60)&255}@100,0xB5:{(ck+60)>>8}@100,0x1B:200@101,0x53:1@300,0x50:1@300" if ck else "0x53:1@40,0x50:1@40"
    n = sum(int(s[1:]) for s in script.split(','))
    subprocess.run(['/tmp/svshot', rom, str(lvl), str(n), '1', S + '/cg.fb', S + '/cg.ram', script, pk], capture_output=True)
    R = np.fromfile(S + '/cg.ram', dtype=np.uint8).reshape(-1, 0x2000)
    for f in range((400 if ck else 60) + 1, len(R)):
        r = R[f]
        if any(r[a] for a in frz) or any(R[f-1][a] for a in frz) or r[0x1B] >= 150: continue
        cam = int(r[0xB4]) | int(r[0xB5]) << 8
        b = bins[cam // 128]; b[0] += 1; b[1] += r[ts] == R[f-1][ts]
        live = [k for k in range(10) if r[ot+k]]; b[2] += len(live)
        for k in live: b[3][hex(tab[r[ti+k]]) if r[ot+k] == 36 else str(int(r[ot+k]))] += 1
print(f"level {lvl}: bin(x)  frames  stall%  avg-objs  types")
for k in sorted(bins):
    fr, st, os_, ty = bins[k]
    if fr < 30: continue
    print(f"  {k*128:5d}  {fr:5d}  {100*st/fr:5.1f}  {os_/fr:5.2f}  {dict(ty.most_common(6))}")
