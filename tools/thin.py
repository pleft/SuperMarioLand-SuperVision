# Congestion thinning table (tools/thin.json, written by tools/svthin.py; docs/45,
# law E42): {level: [[fire_cam, type, o_y], ...]} entries dropped from that
# level's spawn list. Every named entry must exist: a typo fails the build.
import json, os
_T = os.path.join(os.path.dirname(__file__), "thin.json")
THIN = {int(k): [tuple(e) for e in v] for k, v in json.load(open(_T)).items()} if os.path.exists(_T) else {}
def thin_spawns(lv, d):
    drops = set(THIN.get(lv, []))
    out = bytearray(); i = 0; seen = set()
    while i + 1 < len(d) and not (d[i] == 0xFF and d[i+1] == 0xFF):
        e = d[i:i+5]; key = (e[0] | e[1] << 8, e[3], e[2])
        if key in drops: seen.add(key)
        else: out += e
        i += 5
    assert seen == drops, f"level {lv}: THIN entries not found: {drops - seen}"
    return bytes(out) + d[i:]
