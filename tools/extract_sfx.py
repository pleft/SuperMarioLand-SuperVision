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

def synth_channel(samples, lo_i, hi_i, vol_i, len_i, sweep_i=None):
    """samples: list of APU reg tuples per frame. Returns {frame: (F, volduty)} rows
    for one GB square channel, with hw ENVELOPE and (ch1) hw SWEEP synthesized."""
    rows = {}
    vol = 0; env_dir = 0; env_per = 0; env_ctr = 0; cur = None
    x = 0; sw_per = 0; sw_dir = 0; sw_shift = 0; sw_ctr = 0.0
    for f, s in enumerate(samples):
        nr_lo, nr_hi, nr_vol = s[lo_i], s[hi_i], s[vol_i]
        nr_len = s[len_i]
        duty = (nr_len >> 6) & 3
        key = (nr_lo, nr_hi, nr_vol, nr_len)
        emit = False
        if key != cur:                       # register change = (re)trigger / slide
            cur = key
            x = nr_lo | ((nr_hi & 7) << 8)
            vol = nr_vol >> 4
            env_dir = (nr_vol >> 3) & 1
            env_per = nr_vol & 7
            env_ctr = 0
            if sweep_i is not None:
                nr10 = s[sweep_i]
                sw_per = (nr10 >> 4) & 7
                sw_dir = (nr10 >> 3) & 1
                sw_shift = nr10 & 7
                sw_ctr = 0.0
            emit = True
        else:
            if env_per and vol > 0:
                env_ctr += 1
                if env_ctr >= env_per:       # env steps at 64Hz ~ our frame rate
                    env_ctr = 0
                    vol = min(15, vol + 1) if env_dir else max(0, vol - 1)
                    emit = True
            if sweep_i is not None and sw_per and sw_shift and vol > 0:
                sw_ctr += 128.0 / 61.0 / sw_per   # sweep steps at 128Hz/period
                while sw_ctr >= 1.0:
                    sw_ctr -= 1.0
                    d = x >> sw_shift
                    x = x - d if sw_dir else x + d
                    if x >= 2048: x = 2047; vol = 0   # overflow silences (GB rule)
                    if x < 0: x = 0
                    emit = True
        if emit:
            rows[f] = (gb2sv_freq(x), (0x40 if vol else 0) | (duty_gb2sv(duty) << 4) | min(15, vol))
    return rows

def synth_noise(samples, div_i, vol_i):
    rows = {}
    vol = 0; env_dir = 0; env_per = 0; env_ctr = 0; cur = None
    for f, s in enumerate(samples):
        nr_vol, nr_div = s[vol_i], s[div_i]
        key = (nr_vol, nr_div)
        if key != cur:
            cur = key
            vol = nr_vol >> 4
            env_dir = (nr_vol >> 3) & 1
            env_per = nr_vol & 7
            env_ctr = 0
            shift = (nr_div >> 4) & 0xF
            rows[f] = ((min(15, shift) << 4) | min(15, vol),)
        elif env_per and vol > 0:
            env_ctr += 1
            if env_ctr >= env_per:
                env_ctr = 0
                vol = min(15, vol + 1) if env_dir else max(0, vol - 1)
                shift = (nr_div >> 4) & 0xF
                rows[f] = ((min(15, shift) << 4) | vol,)
    return rows

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
    for f in range(frames):
        log.frame = f
        gb.run(1)
        # the driver's channel-ownership flags: bit7 set while the SFX plays
        flags = (m[0xDF1F] | m[0xDF2F] | m[0xDF3F] | m[0xDF4F]) & 0x80
        if flags: started = True
        elif started:
            end = f + 1
            break
    log.writes = [w for w in log.writes if w[0] <= end]
    frames = end
    # rebuild per-frame register STATE from the true write log
    shadow = {a: 0 for a in range(0xFF10, 0xFF27)}
    samples = []
    wi = 0; ws = log.writes
    for f in range(frames):
        while wi < len(ws) and ws[wi][0] <= f:
            _, a, v = ws[wi]; shadow[a] = v; wi += 1
        samples.append(tuple(shadow[a] for a in range(0xFF10, 0xFF27)))
    return samples

def encode(samples, quiet):
    # indices into the FF10..FF26 tuple: ch1 lo/hi/vol/len = FF13,FF14,FF12,FF11
    idx = lambda a: a - 0xFF10
    ch1 = synth_channel(samples, idx(0xFF13), idx(0xFF14), idx(0xFF12), idx(0xFF11), idx(0xFF10))
    ch2 = synth_channel(samples, idx(0xFF18), idx(0xFF19), idx(0xFF17), idx(0xFF16))
    noi = synth_noise(samples, idx(0xFF22), idx(0xFF21))
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
    quiet = tuple(m[a] for a in range(0xFF10, 0xFF27))
    wanted = [("dfe0", 0xDFE0, v) for v in (1, 2, 3, 4, 7, 8)] + \
             [("dff8", 0xDFF8, v) for v in (1, 2, 3)] + \
             [("dfe8", 0xDFE8, v) for v in (2,)]     # the death jingle; more with the music
    blob = bytearray(); table = []
    for name, mb, v in wanted:
        samples = capture(gb, mb, v)
        enc = encode(samples, quiet)
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
