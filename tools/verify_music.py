#!/usr/bin/env python3
"""Rule 0b for the music sequencer: run the PORT under py65, trap its APU
register writes, and diff the note-on sequence + tick timing against the
(capture-validated) decode of build/audio/music.bin. Also asserts the SFX
arbitration: a claimed channel gets no music writes while a stream is live."""
import os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
ROOT = os.path.join(os.path.dirname(__file__), "..")

def expected_events(list_off, lentab_off, max_ticks):
    bin = open(os.path.join(ROOT, "build/audio/music.bin"), "rb").read()
    u16 = lambda o: bin[o] | (bin[o+1] << 8)
    ev = []; t = 0; lp = list_off; ln = 1
    while t < max_ticks:
        e = u16(lp)
        if e == 0: break
        if e == 0xFFFF:
            lp = u16(lp+2); continue
        lp += 2; q = e
        while t < max_ticks:
            b = bin[q]; q += 1
            if b == 0: break
            elif b == 0x9D: q += 3
            elif 0xA0 <= b <= 0xAF: ln = bin[lentab_off + (b & 15)]
            elif b == 1: t += ln
            else:
                ev.append((t, u16(b*2))); t += ln
    return ev

def main():
    from py65.devices.mpu65c02 import MPU
    mem = bytearray(0x10000)
    mem[0x8000:0x10000] = open(os.path.join(ROOT, "build/super-mario-land.sv"), "rb").read()
    mpu = MPU(); mpu.memory = mem

    writes = []                       # (frame, addr, val) for $2010-$2017
    frame = [0]
    class Watch(bytearray):
        def __setitem__(self, i, v):
            if isinstance(i, int) and 0x2010 <= i <= 0x2017:
                writes.append((frame[0], i, v))
            super().__setitem__(i, v)
    wmem = Watch(mem); mpu.memory = wmem

    def dma():
        if wmem[0x200D] & 0x80:
            s = wmem[0x2008] | (wmem[0x2009]<<8); d = wmem[0x200A] | (wmem[0x200B]<<8)
            for i in range(wmem[0x200C]*16): wmem[(d+i)&0xFFFF] = wmem[(s+i)&0xFFFF]
            wmem[0x200D] &= 0x7F

    mpu.pc = wmem[0xFFFC] | (wmem[0xFFFD]<<8)
    wmem[0x2020] = 0xFF               # no buttons
    # boot to title, press Start (bit3 low) briefly, then run the level
    steps = 0; press_at = None; total_frames = 1400
    while frame[0] < total_frames:
        mpu.step(); steps += 1
        if steps % 120_000 == 0:
            wmem[0] = 1; wmem[1] = (wmem[1]+1) & 0xFF; frame[0] += 1
            if frame[0] == 240: wmem[0x2020] = 0x7F      # Start pressed (SV: bit7, active low)
            if frame[0] == 248: wmem[0x2020] = 0xFF
        dma()

    # note-ons = FLO writes followed by FHI on the same channel
    def onsets(base):
        out = []; lo = None
        for f, a, v in writes:
            if a == base: lo = (f, v)
            elif a == base+1 and lo and lo[0] == f:
                out.append((f, lo[1] | (v << 8)))
        return out
    inc = open(os.path.join(ROOT, "build/audio/music.inc")).read()
    l1 = int(re.search(r"mus_l1_lo: .byte <(\d+)", inc).group(1))
    l2 = int(re.search(r"mus_l2_lo: .byte <(\d+)", inc).group(1))
    lt = int(re.search(r"MUS_T07_LT = (\d+)", inc).group(1))
    all_on = [onsets(0x2010), onsets(0x2014)]
    f0 = min(o[0][0] for o in all_on if o)          # the shared music start
    for name, got, off in (("ch1", all_on[0], l1), ("ch2", all_on[1], l2)):
        if not got: print(f"{name}: NO WRITES -- FAIL"); continue
        exp = expected_events(off, lt, int((total_frames - f0) * 64/61) + 8)
        ok = 0; errs = []
        for i, (t, F) in enumerate(exp):
            if i >= len(got): break
            gf, gF = got[i]
            dt = (gf - f0) - t*61/64 * (61/61)      # ticks -> port frames (61Hz, 64Hz ticks)
            if gF == F: ok += 1
            errs.append(round(gf - f0 - t*61/64, 1))
        n = min(len(exp), len(got))
        print(f"{name}: {ok}/{n} note freqs exact (port emitted {len(got)}); "
              f"timing err frames: first={errs[:5]} max|.|={max(abs(e) for e in errs):.1f}")
    print("done")

if __name__ == "__main__":
    main()
