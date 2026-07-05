#!/usr/bin/env python3
"""
Capture the ORIGINAL's sound effects as APU register streams (PyBoy, build time)
and convert them into Watara Supervision register scripts. RULE 5: outputs land
in gitignored build/audio/.

Method: silence the music ($dfe8=$10), fire each SFX mailbox value, sample the
GB APU registers every frame until silence returns. GB hardware envelopes are
synthesized offline into explicit volume rows (the SV has no hw envelope).

Stream format (per SFX), rows:
  delay(1) mask(1) [ch1: FLO FHI VOLDUTY]? [ch2: FLO FHI VOLDUTY]? [noise: FREQVOL]?
  mask bit0=ch1, bit1=ch2, bit2=noise; delay=$FF terminates (player silences used chs).
Emits: build/audio/sfx.bin + build/audio/sfx.inc (offsets + count).
"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from gbharness import GB

OUT = os.path.join(os.path.dirname(__file__), "..", "build", "audio")

def gb2sv_freq(x):
    if x >= 2048: x = 2047
    f = 131072.0 / (2048 - x)
    F = int(round(125000.0 / f)) - 1
    return max(0, min(2047, F))

def duty_gb2sv(d):  return d          # both: 12.5/25/50/75 in 2 bits

def simulate_square(writes, lo_a, hi_a, vol_a, len_a, sweep_a=None, frames=180):
    """Interpret one GB square channel from the WRITE log. Slides don't retrigger;
    the envelope restarts only on NRx2 writes or NRx4 bit7. Returns {frame:(gbfreq_x, vol, duty)}."""
    rows = {}
    x = 0; duty = 2; vol = 0; vol_init = 0; env_dir = 0; env_per = 0; env_ctr = 0
    sw_per = 0; sw_dir = 0; sw_shift = 0; sw_ctr = 0.0
    length = 0; len_en = 0; len_frames = 0.0
    wl = [(f, a, v) for f, a, v in writes if a in (lo_a, hi_a, vol_a, len_a, sweep_a)]
    wi = 0
    for f in range(frames):
        emit = False
        while wi < len(wl) and wl[wi][0] <= f:
            _, a, v = wl[wi]; wi += 1
            if a == lo_a:
                x = (x & 0x700) | v; emit = True
            elif a == hi_a:
                x = (x & 0xFF) | ((v & 7) << 8); emit = True
                len_en = (v >> 6) & 1
                if v & 0x80:
                    env_ctr = 0; sw_ctr = 0.0            # retrigger
                    vol = vol_init
                    len_frames = (64 - length) * 59.7 / 256.0  # length ticks at 256Hz
            elif a == vol_a:
                vol_init = v >> 4; vol = vol_init
                env_dir = (v >> 3) & 1; env_per = v & 7; env_ctr = 0
                emit = True
            elif a == len_a:
                duty = (v >> 6) & 3; length = v & 63
                len_frames = (64 - length) * 59.7 / 256.0   # NRx1 write reloads the counter
            elif sweep_a is not None and a == sweep_a:
                sw_per = (v >> 4) & 7; sw_dir = (v >> 3) & 1; sw_shift = v & 7
        if len_en and vol > 0 and len_frames > 0:        # countdown only when ARMED
            len_frames -= 1.0
            if len_frames <= 0:
                vol = 0; emit = True                     # the hw length counter cut
        if env_per and vol > 0:
            env_ctr += 1
            if env_ctr >= env_per:
                env_ctr = 0
                vol = min(15, vol + 1) if env_dir else max(0, vol - 1)
                emit = True
        if sw_per and sw_shift and vol > 0:
            sw_ctr += 128.0 / 61.0 / sw_per
            while sw_ctr >= 1.0:
                sw_ctr -= 1.0
                d = x >> sw_shift
                x = x - d if sw_dir else x + d
                if x >= 2048: x = 2047; vol = 0
                emit = True
        if emit:
            rows[f] = (x, vol, duty)
    return rows

def simulate_wave(writes, frames=180):
    """GB ch3: freq = 65536/(2048-x); volume from NR32 (0/100/50/25%)."""
    rows = {}
    x = 0; vol = 0; on = 0
    VMAP = {0: 0, 1: 15, 2: 8, 3: 4}
    wl = [(f, a, v) for f, a, v in writes if a in (0xFF1A, 0xFF1C, 0xFF1D, 0xFF1E)]
    wi = 0
    for f in range(frames):
        emit = False
        while wi < len(wl) and wl[wi][0] <= f:
            _, a, v = wl[wi]; wi += 1
            if a == 0xFF1A: on = v >> 7; emit = True
            elif a == 0xFF1C: vol = VMAP[(v >> 5) & 3]; emit = True
            elif a == 0xFF1D: x = (x & 0x700) | v; emit = True
            elif a == 0xFF1E: x = (x & 0xFF) | ((v & 7) << 8); emit = True
        if emit:
            rows[f] = (x, vol if on else 0, 2)
    return rows

def gb2sv_wave_freq(x):
    if x >= 2048: x = 2047
    f = 65536.0 / (2048 - x)
    F = int(round(125000.0 / f)) - 1
    return max(0, min(2047, F))

def gb_noise_to_sv(nr43):
    """GB: freq = 262144 / (r * 2^(s+1)), r=0 counts as 0.5 (NR43 = s<<4 | w<<3 | r).
    Potator noise (sound.c): freq = 4e6 / (8 << N). Pick N minimizing the freq error."""
    s = (nr43 >> 4) & 0xF; r = nr43 & 7
    gb = 262144.0 / ((r if r else 0.5) * (1 << (s + 1)))
    best, bn = None, 0
    for N in range(16):
        sv = 4_000_000.0 / (8 << N)
        e = abs(sv - gb)
        if best is None or e < best: best, bn = e, N
    return bn

def simulate_noise(writes, frames=180):
    rows = {}
    vol = 0; vol_init = 0; env_dir = 0; env_per = 0; env_ctr = 0; svn = 0
    wl = [(f, a, v) for f, a, v in writes if a in (0xFF21, 0xFF22, 0xFF23)]
    wi = 0
    for f in range(frames):
        emit = False
        while wi < len(wl) and wl[wi][0] <= f:
            _, a, v = wl[wi]; wi += 1
            if a == 0xFF21:
                vol_init = v >> 4; vol = vol_init
                env_dir = (v >> 3) & 1; env_per = v & 7; env_ctr = 0; emit = True
            elif a == 0xFF22:
                svn = gb_noise_to_sv(v); emit = True
            elif a == 0xFF23 and (v & 0x80):
                env_ctr = 0; vol = vol_init; emit = True
        if env_per and vol > 0:
            env_ctr += 1
            if env_ctr >= env_per:
                env_ctr = 0
                vol = min(15, vol + 1) if env_dir else max(0, vol - 1)
                emit = True
        if emit:
            v = (vol + 1) // 2               # NOISE MIX LEVEL: Potator mixes all channels
            rows[f] = ((svn << 4) | min(15, v),)   # at equal raw weight; the GB's percussion
    return rows                                    # sits deeper in its 4-voice bipolar mix.
                                                   # 50% is the energy-equivalent default --
                                                   # the one deliberate MIX knob (not RE).

def find_write_sites(rom):
    """Bank-3 code addresses of `ldh [c],a` (E2) and `ldh [$10-$26],a` (E0 xx)."""
    sites = []
    base = 3 * 0x4000
    for i in range(0x4000 - 1):
        op = rom[base + i]
        gb_addr = 0x4000 + i
        if op == 0xE2:
            sites.append((gb_addr, None))
        elif op == 0xE0 and 0x10 <= rom[base + i + 1] <= 0x26:
            sites.append((gb_addr, 0xFF00 | rom[base + i + 1]))
    return sites

class WriteLog:
    def __init__(self, pb):
        self.pb = pb; self.frame = 0; self.writes = []
    def cb(self, target):
        rf = self.pb.register_file
        addr = target if target is not None else (0xFF00 | rf.C)
        if 0xFF10 <= addr <= 0xFF26:
            self.writes.append((self.frame, addr, rf.A))

_hooked = {}
def install_hooks(gb):
    if _hooked.get('done'): return _hooked['log']
    rom = open(os.path.join(os.path.dirname(__file__), "..", "super-mario-land-gb.gb"), "rb").read()
    log = WriteLog(gb.pb)
    for gb_addr, target in find_write_sites(rom):
        try:
            gb.pb.hook_register(3, gb_addr, log.cb, target)
        except Exception:
            pass
    _hooked['done'] = True; _hooked['log'] = log
    return log

def capture(gb, mailbox, value, frames=180):
    m = gb.m
    log = install_hooks(gb)
    log.writes = []
    m[mailbox] = value
    end = frames
    started = False
    owned = set()
    jingle = (mailbox == 0xDFE8)
    for f in range(frames):
        log.frame = f
        gb.run(1)
        if jingle and f > 2 and m[0xDFE9] != value:
            end = f
            break
        # per-channel ownership: the driver sets bit7 while an SFX holds a channel
        if m[0xDF1F] & 0x80: owned.add(1)
        if m[0xDF2F] & 0x80: owned.add(2)
        if m[0xDF3F] & 0x80: owned.add(3)
        if m[0xDF4F] & 0x80: owned.add(4)
        flags = (m[0xDF1F] | m[0xDF2F] | m[0xDF3F] | m[0xDF4F]) & 0x80
        if flags: started = True
        elif started:
            end = f + 1
            break
    log.writes = [w for w in log.writes if w[0] <= end]
    return list(log.writes), end, owned

def encode(writes, frames, owned):
    ch1 = simulate_square(writes, 0xFF13, 0xFF14, 0xFF12, 0xFF11, 0xFF10, frames) if 1 in owned else {}
    ch2 = simulate_square(writes, 0xFF18, 0xFF19, 0xFF17, 0xFF16, None, frames) if 2 in owned else {}
    ch3 = simulate_wave(writes, frames) if 3 in owned else {}
    noi = simulate_noise(writes, frames) if 4 in owned else {}
    # 3 tonal channels -> the SV's 2 squares: drop DOUBLING lines first (channels
    # playing the same rhythm, e.g. the wave doubling the melody in octaves),
    # then rank the distinct lines by energy.
    def energy(rows): return sum(v for (_, v, _) in rows.values())
    def rhythm(rows):
        on = []; px = None
        for f in sorted(rows):
            x = rows[f][0]
            if x != px: on.append(f); px = x
        return frozenset(on)                       # NOTE onsets, not envelope rows
    cands = [("s", ch1), ("s", ch2), ("w", ch3)]
    cands = [c for c in cands if c[1]]
    drop = None
    for i in range(len(cands)):
        for j in range(i + 1, len(cands)):
            a, b = rhythm(cands[i][1]), rhythm(cands[j][1])
            if a and b and len(a & b) / max(1, min(len(a), len(b))) > 0.7:
                # doubles: drop the wave one (keep the square timbre), else the quieter
                pair = [cands[i], cands[j]]
                pair.sort(key=lambda kv: (kv[0] != "w", energy(kv[1])))
                drop = pair[0]
    if drop is not None and len(cands) > 2:
        cands = [c for c in cands if c is not drop]
    ranked = sorted(cands, key=lambda kv: -energy(kv[1]))[:2]
    def to_sv(kind, rows):
        out = {}
        for f, (x, v, d) in rows.items():
            F = gb2sv_wave_freq(x) if kind == "w" else gb2sv_freq(x)
            out[f] = (F, (0x40 if v else 0) | (d << 4) | min(15, v))
        return out
    ch1 = to_sv(*ranked[0]) if len(ranked) > 0 else {}
    ch2 = to_sv(*ranked[1]) if len(ranked) > 1 else {}
    events = {}
    for f, r in ch1.items(): events.setdefault(f, {})['1'] = r
    for f, r in ch2.items(): events.setdefault(f, {})['2'] = r
    for f, r in noi.items(): events.setdefault(f, {})['n'] = r
    if not events: return b""
    out = bytearray(); last = 0; pf1 = None; pf2 = None
    for f in sorted(events):
        ev = events[f]
        m = 0; pay = bytearray()
        if '1' in ev:
            F, vd = ev['1']
            if F == pf1: m |= 0x10; pay.append(vd)          # vol-only row
            else: m |= 0x01; pay += bytes([F & 0xFF, F >> 8, vd]); pf1 = F
        if '2' in ev:
            F, vd = ev['2']
            if F == pf2: m |= 0x20; pay.append(vd)
            else: m |= 0x02; pay += bytes([F & 0xFF, F >> 8, vd]); pf2 = F
        if 'n' in ev:
            m |= 0x04; pay.append(ev['n'][0])
        out.append(min(254, f - last)); out.append(m); out += pay
        last = f
    out.append(0xFF)
    return bytes(out)

def main():
    os.makedirs(OUT, exist_ok=True)
    gb = GB(state=os.path.join("w1_open.state")) if os.path.exists(
        os.path.join(os.path.dirname(__file__), "..", "build", "states", "w1_open.state")) else GB()
    m = gb.m
    m[0xDFE8] = 0x10                     # stop the music
    for _ in range(40): gb.run(1)
    wanted = [("dfe0", 0xDFE0, v) for v in (1, 2, 3, 4, 7, 8)] + \
             [("dff8", 0xDFF8, v) for v in (1, 2, 3)] + \
             [("dfe8", 0xDFE8, v) for v in (2,)]     # the death jingle; more with the music
    blob = bytearray(); table = []
    for name, mb, v in wanted:
        writes, frames, owned = capture(gb, mb, v)
        if mb == 0xDFE8:                 # jingles play via the MUSIC path: no ownership
            owned = {1, 2, 3}            # flags; tonal channels only -- the noise writes
                                         # during a jingle are the SILENCED level music's
                                         # percussion still being serviced (user-verified:
                                         # the original's death jingle has NO drums)
        enc = encode(writes, frames, owned)
        m[0xDFE8] = 0x10                 # re-silence between captures
        for _ in range(30): gb.run(1)
        label = f"{name}_{v:02X}"
        if len(enc) <= 3:                # empty capture
            table.append((label, -1)); continue
        table.append((label, len(blob)))
        blob += enc
        print(f"SFX {label}: {len(enc)} bytes")
    gb.stop()
    with open(os.path.join(OUT, "sfx.bin"), "wb") as f:
        f.write(bytes(blob))
    with open(os.path.join(OUT, "sfx.inc"), "w") as f:
        f.write("; GENERATED by tools/extract_sfx.py (build artifact, rule 5)\n")
        live = [(l, o) for l, o in table if o >= 0]
        for i, (l, o) in enumerate(live):
            f.write(f"SFX_{l.upper()} = {i}\n")
        f.write("sfx_offsets_lo:\n")
        for l, o in live: f.write(f"    .byte <{o}\n")
        f.write("sfx_offsets_hi:\n")
        for l, o in live: f.write(f"    .byte >{o}\n")
    print(f"total: {len(blob)} bytes, {len([1 for _,o in table if o>=0])} live SFX")

if __name__ == "__main__":
    main()
