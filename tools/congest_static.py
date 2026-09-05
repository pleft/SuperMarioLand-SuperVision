# Static congestion candidates from the spawn lists alone (user, 2026-09-05: "you
# already know the enemy positions and spawns -- areas with more than one cannon
# are candidates, areas with 2-3 plants are also candidates"). Per level, slide a
# 320px window over the (thinned) list; flag it when it holds >1 cannon, >=2
# plants, or a weighted load >= 12. Weights are the measured per-object costs
# (docs/45: a cannon ~20 points on its own, a 16x16 mover ~5, a bobbing hazard
# ~4, a dropper ~3 with its stones, a plant ~1, a lift ~2).
#   python3 tools/congest_static.py [level ...]
import sys, os
sys.path.insert(0, os.path.dirname(__file__)); from thin import thin_spawns, THIN
W = {0x49: 20, 0x1C: 20, 0x02: 1, 0x55: 4, 0x36: 3, 0x0A: 2, 0x0B: 2, 0x3A: 2, 0x38: 2, 0x39: 2, 0x00: 3, 0x04: 3}
NAME = {0x49: "cannon", 0x02: "plant", 0x55: "hazard", 0x36: "dropper", 0x56: "Pionpi", 0x54: "orbiter", 0x25: "Tokotoko",
        0x04: "Nokobon", 0x00: "Chibibo", 0x3F: "Gao", 0x53: "flyer53", 0x52: "spawner52", 0x59: "e59", 0x0A: "lift", 0x0B: "lift", 0x3A: "lift"}
def entries(lv, thinned=True):
    d = open(f"build/levels/level_{lv:02d}_spawns.bin", "rb").read()
    if thinned: d = thin_spawns(lv, d)
    i = 0; out = []
    while i + 1 < len(d) and not (d[i] == 0xFF and d[i+1] == 0xFF):
        out.append((d[i] | d[i+1] << 8, d[i+3], d[i+2])); i += 5
    return out
def scan(lv, thinned=True, win=320):
    es = entries(lv, thinned); flags = []
    for a in range(0, 3900, 32):
        w = [e for e in es if a <= e[0] + 192 < a + win]
        cannons = sum(1 for e in w if e[1] == 0x49); plants = sum(1 for e in w if e[1] == 0x02)
        load = sum(W.get(e[1], 5) for e in w)
        if cannons > 1 or plants >= 2 or load >= 12:
            flags.append((a, a + win, cannons, plants, load, [NAME.get(e[1], hex(e[1])) for e in w]))
    # keep the LOCAL maxima only: a window is dropped if a neighbouring window
    # (within one stride) has a higher load -- so a stretch prints once
    out = []
    for i, f in enumerate(flags):
        if all(g[4] <= f[4] for g in flags if g is not f and abs(g[0] - f[0]) <= 128):
            if out and f[0] - out[-1][0] <= 160 and f[4] == out[-1][4] and f[5] == out[-1][5]: continue   # the same stretch again
            out.append(f)
    return out
if __name__ == "__main__":
    lvls = [int(a) for a in sys.argv[1:]] or list(range(12))
    for lv in lvls:
        for thinned in (False, True):
            m = scan(lv, thinned)
            tag = "thinned" if thinned else "GB list"
            print(f"level {lv} ({tag}): {len(m)} candidate stretch(es)")
            for a, b, c, p, load, names in m: print(f"   x {a:4d}-{b:4d}: cannons {c} plants {p} load {load:3d}  {names}")
