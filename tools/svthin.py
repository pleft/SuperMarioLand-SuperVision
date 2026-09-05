# Congestion thinning, the user's algorithm (2026-09-04): in a congested scene,
# drop STATIC enemies first (pipe plants, cannons with their missiles, fixed
# hazards, stone-droppers) one at a time -- rebuild, re-measure -- keep a drop
# only if the frame-overrun rate falls; if the scene is still congested, do the
# same with MOVING enemies. Lifts are never dropped. Results land in
# tools/thin.json (read by pack_w4.py) and are printed as a table for docs/45.
#   python3 tools/svthin.py LEVEL SCENE [threshold%]     (scenes below)
import sys, re, json, subprocess, collections, numpy as np
sys.path.insert(0, "tools")
S = "/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/407973b1-4713-4577-a0e2-b3e1ebdabcd8/scratchpad"
ROM = "build/super-mario-land.sv"
PLAY = ",".join(["R30,J16,.6,F12,Q16,.8"] * 24)
FIGHT = ",".join(["J16,.20,F8,.20,L8,.20,R8,.20"] * 8)
def warp(ck):   # checkpoint warp: camera poke + a fall = death -> respawn at the checkpoint
    return f"0xB4:{(ck+60)&255}@100,0xB5:{(ck+60)>>8}@100,0x1B:200@101,0x53:1@300,0x50:1@300", ".100,.300," + PLAY, 420
def place(cam, sprx):   # no death: everything up to cam spawns at once (GB-unlike, but the scene is what we want)
    return f"0xB4:{cam&255}@100,0xB5:{cam>>8}@100,0xA4:{sprx}@100,0x53:1@100,0x50:1@100", ".100,.30," + FIGHT + "," + PLAY, 120
def walk(cam, sprx, lo, hi):
    # walked-in scene: camera + Mario placed on real ground, the spawner's index set to
    # the first entry that would fire within the last 300px (so the objects of the
    # stretch are alive, not the whole level's), invulnerable, PLAY script rightwards
    return ("__WALK__", cam, sprx, lo, hi)
def stand(cam, sprx, lo, hi):
    # standing scene: camera FIXED on the stretch, Mario on real ground firing now and
    # then; the spawner index set so the stretch's entries fire (entries past the
    # first 51-entry window: index 51 -> the window shifts itself, then everything
    # up to the camera fires -- the stretch's objects plus a few behind Mario)
    return ("__STAND__", cam, sprx, lo, hi)
def region(x0, x1):
    # a stretch by WORLD x from the static scan (tools/congest_static.py): the
    # standing scene is derived automatically -- camera x0-96, Mario on the nearest
    # row-14 ground inside the screen (the map decides), firing now and then
    return ("__REGION__", x0, x1)
def fly(cam):   # 4-3 (autoscroll, no d-pad): camera poke, plane at its default, autofire
    return f"0xB4:{cam&255}@100,0xB5:{cam>>8}@100", ".100,A700", 160, cam, cam + 400
SCENES = {  # (level, name): (pokes, script, first frame, cam lo, cam hi)
    (11, "s200"): fly(200), (11, "s800"): fly(800), (11, "s1400"): fly(1400), (11, "s2000"): fly(2000),
    (9, "start"):   ("0x53:1@40,0x50:1@40", ".40," + PLAY, 60, 100, 520),
    (9, "cannon"):  place(560, 100) + (540, 900),
    (9, "pillars"): warp(1920) + (1900, 2300),      # (a respawn skips every entry fired before it: pessimistic scenes below instead)
    (9, "pillars2"): place(1748, 40) + (1740, 2300),  # walked in: all six hazards + plants alive, as in real play
    (10, "orbiters2"): place(1150, 40) + (1150, 1700),
    (9, "drop6"):   stand(2450, 142, 2450, 2451),   # six stone-droppers + cannon 2592, Mario at 2592
    (9, "trio1"):   stand(2990, 90, 2990, 2991),    # cannon trio 3104-3168 on screen, Mario at 3080
    (9, "trio2"):   stand(3330, 70, 3330, 3331),    # three Pionpi (3312), droppers, cannon trio 3440-3472; Mario at 3400
    (10, "late"):   stand(2248, 40, 2248, 2249),    # 4-2 at 2288: orbiters + Gao + Nokobons
    (10, "end"):    stand(2840, 40, 2840, 2841),    # 4-2 at 2880: hazard, lift, five droppers
    (6, "a"): region(288, 608), (6, "b"): region(1728, 2048), (6, "c"): region(2016, 2496),
    (7, "b"): region(1024, 1408), (7, "c"): region(1952, 2272), (7, "d"): region(2240, 2560),
    (9, "mid"): region(1056, 1536),
    (10, "a"): region(352, 672), (10, "b"): region(832, 1152), (10, "c"): region(2304, 2624),
    (7, "start"):   ("0x53:1@40,0x50:1@40", ".40," + PLAY, 60, 100, 520),   # 3-2: Tokotokos + Nokobons + a plant
    (6, "start"):   ("0x53:1@40,0x50:1@40", ".40," + PLAY, 60, 100, 520),
    (10, "orbiters"): warp(1280) + (1280, 1700),
}
CAND = []          # candidate world-x range override (region scenes)
STATIC = {0x02, 0x49, 0x55, 0x36, 0x0C, 0x1C}   # $1C = W3's static shooter
LIFTS = {0x0A, 0x0B}
lbl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open('build/rom.lbl').read())}
ot, ts = lbl['o_type'], lbl['timer_sub']
frz = [lbl[n] for n in ('mario_grow', 'mario_shrink', 'death_anim', 'goal_phase', 'bonus_phase', 'pipe_phase')]
def measure(lvl, scene):
    if isinstance(scene, list):
        rs = [measure(lvl, sc) for sc in scene]; fr = sum(r[1] for r in rs)
        return (sum(r[0] * r[1] for r in rs) / fr if fr else 0.0), fr, (sum(r[2] * r[1] for r in rs) / fr if fr else 0)
    pk, script, f0, lo, hi = scene; n = sum(int(s[1:]) for s in script.split(','))
    # invulnerable (hurt_inv topped up every 100 frames): the scene must SURVIVE long
    # enough to be measured -- a 127-frame baseline once accepted a drop on noise
    pk = pk + ',' + ','.join(f"{lbl['hurt_inv']}:250@{f}" for f in range(f0, n, 100))
    subprocess.run(['/tmp/svshot', ROM, str(lvl), str(n), '1', S + '/th.fb', S + '/th.ram', script, pk], capture_output=True)
    R = np.fromfile(S + '/th.ram', dtype=np.uint8).reshape(-1, 0x2000)
    ok = [f for f in range(f0 + 1, len(R)) if not any(R[f][a] for a in frz) and not any(R[f-1][a] for a in frz)
          and R[f][0x1B] < 150 and lo <= (int(R[f][0xB4]) | int(R[f][0xB5]) << 8) <= hi]
    st = sum(1 for f in ok if R[f][ts] == R[f-1][ts]); objs = sum(sum(1 for k in range(10) if R[f][ot+k]) for f in ok)
    if len(ok) < 300: print(f'   (warning: only {len(ok)} measured frames)')
    return (100.0 * st / len(ok) if ok else 0.0), len(ok), (objs / len(ok) if ok else 0)
def entries(lvl, thinned=False):
    d = open(f"build/levels/level_{lvl:02d}_spawns.bin", "rb").read(); i = 0; out = []
    if thinned:   # the PACKED list (current drops applied): spawn indices are positions in THIS list
        import importlib, thin as T; importlib.reload(T); d = T.thin_spawns(lvl, d)
    while not (d[i] == 0xFF and d[i+1] == 0xFF):
        out.append((d[i] | d[i+1] << 8, d[i+3], d[i+2])); i += 5
    return out
def build():
    import os, time
    t = os.path.getmtime(ROM) + 2 if os.path.exists(ROM) else time.time()   # make compares mtimes at 1s: a table written in the ROM's second built nothing
    os.utime('tools/thin.json', (t, t))
    r = subprocess.run(['make'], capture_output=True, text=True); assert 'built' in r.stdout, r.stdout[-400:] + r.stderr[-400:]
def main():
    lvl, name = int(sys.argv[1]), sys.argv[2]; thr = float(sys.argv[3]) if len(sys.argv) > 3 else 4.0
    raw = SCENES[(lvl, name)]
    import json as _j
    C = _j.load(open(f"build/levels/level_{lvl:02d}.json"))["columns"]
    def ground(x): c = x // 8; return c + 1 < len(C) and C[c][14] >= 0x60 and C[c][13] < 0x60 and C[c][12] < 0x60 and C[c+1][14] >= 0x60 and C[c+1][13] < 0x60
    def spawn_pokes(cam, sprx):   # spawner index into the PACKED list (recomputed after every drop)
        idx = min(sum(1 for e in entries(lvl, True) if e[0] <= cam - 300), 51)
        return f"0xB4:{cam&255}@100,0xB5:{cam>>8}@100,0xA4:{sprx}@100,{lbl['spawn_idx']}:{idx}@100,0x1FF0:0@100,0x53:1@100,0x50:1@100"
    def build_scene():
        if raw[0] == "__REGION__":
            _, x0, x1 = raw; subs = []
            for cam0 in (max(0, x0 - 40), max(0, x1 - 200)):   # two FIXED cameras cover a 320px stretch
                for shift in range(0, 200, 8):
                    cands = [x for x in range(cam0 + shift + 24, cam0 + shift + 136, 8) if ground(x)]
                    if cands: subs.append((cam0 + shift, cands[0] - cam0 - shift)); break
            assert subs, f"no standing ground in {x0}-{x1}"
            return [(spawn_pokes(c, sx), ".100,.10," + ",".join(["B2,.12"] * 50), 120, c, c + 1) for c, sx in subs], (x0 - 160, x1 + 160)
        if raw[0] == "__STAND__":
            _, cam, sprx, lo, hi = raw
            return (spawn_pokes(cam, sprx), ".100,.10," + ",".join(["B2,.12"] * 50), 120, lo, hi), (lo - 160, hi + 160)
        if raw[0] == "__WALK__":
            _, cam, sprx, lo, hi = raw
            return (spawn_pokes(cam, sprx), ".100,.10," + PLAY, 120, lo, hi), (lo - 160, hi + 160)
        return raw, (raw[3] - 160, raw[4] + 160)
    scene, (clo, chi) = build_scene()
    if isinstance(scene, list): print(f"   {name}: standing scenes at camera", [sc[3] for sc in scene])
    thin = json.load(open("tools/thin.json")); cur = [tuple(e) for e in thin.get(str(lvl), [])]
    cands = [e for e in entries(lvl) if clo <= e[0] + 192 <= chi and e[1] not in LIFTS and e not in cur]
    cands.sort(key=lambda e: (0 if e[1] in STATIC else 1, e[0]))
    build(); base = measure(lvl, scene); print(f"{name}: baseline {base[0]:.1f}% over {base[1]} frames, {base[2]:.2f} objs; candidates {[(e[0], hex(e[1])) for e in cands]}")
    if base[1] < 300: print(f"{name}: INVALID scene ({base[1]} frames) -- no drops accepted"); return
    best = base[0]; log = []
    for e in cands:
        if best <= thr: break
        thin[str(lvl)] = [list(x) for x in cur + [e]]; json.dump(thin, open("tools/thin.json", "w"), indent=1); build()
        scene, _ = build_scene()
        m = measure(lvl, scene); keep = m[0] <= best - 1.0 and m[1] >= 300
        print(f"  drop {e[0]:5d} {hex(e[1])} y{e[2]:3d} ({'static' if e[1] in STATIC else 'moving'}): {m[0]:.1f}% ({m[1]} fr, {m[2]:.2f} objs) -> {'KEEP' if keep else 'revert'}")
        log.append((e, m[0], keep))
        if keep: cur.append(e); best = m[0]
    thin[str(lvl)] = [list(x) for x in cur]; json.dump(thin, open("tools/thin.json", "w"), indent=1); build()
    scene, _ = build_scene(); fin = measure(lvl, scene); print(f"{name}: final {fin[0]:.1f}% (was {base[0]:.1f}%); kept {[(e[0], hex(e[1])) for e, m, k in log if k]}")
main()
