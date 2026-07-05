#!/usr/bin/env python3
"""Rule 0b for audio: for EVERY extracted SFX, FFT the original's rendered audio
and compare against our stream's expected frequencies, slice by slice."""
import os, re, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
ROOT = os.path.join(os.path.dirname(__file__), "..")

def parse_streams():
    data = open(os.path.join(ROOT, "build/audio/sfx.bin"), "rb").read()
    inc = open(os.path.join(ROOT, "build/audio/sfx.inc")).read()
    ids = [l.split()[0] for l in inc.splitlines() if l.startswith("SFX_")]
    offs = [int(v) for v in re.findall(r"\.byte <(\d+)", inc)]
    out = {}
    for name, off in zip(ids, offs):
        p = off; f = 0; rows = []
        while p < len(data):
            d = data[p]
            if d == 0xFF: break
            p += 1; f += d
            mask = data[p]; p += 1
            r = {}
            for bit, key, n in ((1,'1',3),(2,'2',3),(4,'n',1),(0x10,'v1',1),(0x20,'v2',1)):
                if mask & bit:
                    r[key] = data[p:p+n]; p += n
            rows.append((f, r))
        out[name] = rows
    return out

def stream_hz(rows, frame):
    best = (0, None)
    state = {}
    for f, r in rows:
        if f > frame: break
        for k in ('1','2'):
            if k in r:
                F = r[k][0] | (r[k][1] << 8); vd = r[k][2]
                state[k] = (F, vd & 15)
            vk = 'v' + k
            if vk in r and k in state:
                state[k] = (state[k][0], r[vk][0] & 15)
    for k, (F, v) in state.items():
        if v > best[0] and F > 20: best = (v, 125000.0 / (F + 1))
    return best[1]

def main():
    from gbharness import GB
    streams = parse_streams()
    from pyboy import PyBoy
    pb = PyBoy(os.path.join(ROOT, "super-mario-land-gb.gb"), window="null", sound_emulated=True)
    m = pb.memory
    for _ in range(300): pb.tick()
    pb.button_press("start")
    for _ in range(10): pb.tick()
    pb.button_release("start")
    for _ in range(240): pb.tick()
    sr = pb.sound.sample_rate
    MB = {"DFE0": 0xDFE0, "DFF8": 0xDFF8, "DFE8": 0xDFE8}
    for name, rows in streams.items():
        _, mbn, vs = name.split("_")
        mb, v = MB[mbn], int(vs, 16)
        m[0xDFE8] = 0x10
        for _ in range(40): pb.tick()
        m[0xFF1A] = 0           # hard-mute: wave OFF (it drones forever otherwise),
        m[0xFF12] = 0; m[0xFF17] = 0; m[0xFF21] = 0   # squares + noise env to 0
        for _ in range(4): pb.tick()
        m[mb] = v
        length = (rows[-1][0] + 8) if rows else 30
        chunks = []
        for _ in range(length):
            if mb != 0xDFE8:
                m[0xDFE8] = 0x10          # hold the music dead during SFX recording
            pb.tick(); chunks.append(pb.sound.ndarray.copy())
        audio = np.concatenate(chunks).astype(np.float32)
        if audio.ndim > 1: audio = audio.mean(axis=1)
        spf = max(1, len(audio) // length)
        ok = tot = 0; worst = ""
        for seg in range(2, length - 6, 6):
            a = audio[seg*spf:(seg+6)*spf]
            if len(a) < 256: continue
            sp = np.abs(np.fft.rfft(a * np.hanning(len(a))))
            fr = np.fft.rfftfreq(len(a), 1/sr)
            sp[fr < 80] = 0
            if sp.max() < 1e-3: continue
            orig = fr[np.argmax(sp)]
            ours = stream_hz(rows, seg + 3)
            if ours is None: continue
            tot += 1
            rel = abs(orig - ours) / orig if orig else 1
            if rel < 0.06 or abs(orig - 2*ours)/orig < 0.06 or abs(orig - ours/2)/orig < 0.06:
                ok += 1
            elif not worst:
                worst = f" worst@f{seg}: orig {orig:.0f} vs ours {ours:.0f}"
        print(f"{name}: {ok}/{tot} tonal slices match{worst}")
    pb.stop()

if __name__ == "__main__":
    main()
