#!/usr/bin/env python3
"""
Extract Super Mario Land music (songs -> channels -> patterns -> notes) from the
user's own ROM. RULE 5: ships as a tool; output (ROM-derived) under build/ (gitignored).

Format (reverse-engineered, see docs/13-sound.md), all in bank 3:
  Song table @ $663C : song id (1..19) -> song header ptr  (index = (id-1)*2)
  Song header        : 1 flag byte + 5 channel order-list pointers
                       (channels: master, pulse1, pulse2, wave, noise)
  Channel order list : 2-byte pattern pointers; $FFFF then 2-byte target = loop
  Pattern            : note/command bytes:
                         $00          = end of pattern (-> next order entry)
                         $9D + 3      = command (instrument/base/envelope)
                         $A0-$AF      = NOTE: low nibble = scale degree (via note-base
                                        ptr), followed by a duration byte
                         other        = duration / control
"""
import sys, os, json, hashlib

EXPECT_SHA1 = "418203621b887caa090215d97e3f509b79affd3e"
SONG_TABLE = 0x663C
NUM_SONGS  = 19
def bf(gb): return 0xC000 + (gb - 0x4000)      # bank 3 GB addr -> file offset
def inb3(p): return 0x4000 <= p < 0x8000

def u16(d, fo): return d[fo] | (d[fo + 1] << 8)

FREQ_TABLE = 0x6E74    # bank 3: byte value -> 11-bit GB frequency ($6ECD is a slice of this)

def gb_freq_to_hz(x):
    return 131072 / (2048 - x) if x < 2048 else 0

def direct_freq(d, byte):
    fo = bf(FREQ_TABLE) + byte
    x = (d[fo] | (d[fo + 1] << 8)) & 0x7FF
    return x, round(gb_freq_to_hz(x))

def decode_pattern(d, gb, maxlen=256):
    o = bf(gb); out = []; n = 0
    while n < maxlen:
        b = d[o]; o += 1; n += 1
        if b == 0x00:
            out.append({"op": "end"}); break
        elif b == 0x9D:                       # command: instrument / note-base / envelope
            args = [d[o], d[o + 1], d[o + 2]]; o += 3; n += 3
            out.append({"op": "cmd_9D", "args": [f"${x:02X}" for x in args]})
        elif b == 0x01:                       # rest / tie control
            out.append({"op": "rest"})
        elif 0xA0 <= b <= 0xAF:               # scale-degree note (+ duration byte)
            dur = d[o]; o += 1; n += 1
            out.append({"op": "note_scale", "degree": b & 0x0F, "dur": dur})
        else:                                 # direct-frequency note (index into $6E74)
            x, hz = direct_freq(d, b)
            out.append({"op": "note", "byte": f"${b:02X}", "gbfreq": f"${x:03X}", "hz": hz})
    return out

def walk_order(d, gb, maxentries=64):
    """Return (pattern_ptrs, loop_target). Order = 2-byte pattern ptrs; $FFFF+target = loop."""
    o = bf(gb); pats = []; loop = None
    for _ in range(maxentries):
        p = u16(d, o); o += 2
        if p == 0xFFFF:
            loop = u16(d, o)            # loop target (an order address)
            break
        if not inb3(p):
            break
        pats.append(p)
    return pats, loop

def main():
    rom = sys.argv[1] if len(sys.argv) > 1 else "super-mario-land-gb.gb"
    out = "build/music"
    if "--out" in sys.argv: out = sys.argv[sys.argv.index("--out") + 1]
    d = open(rom, "rb").read()
    if hashlib.sha1(d).hexdigest() != EXPECT_SHA1:
        print("WARNING: ROM SHA1 mismatch")
    os.makedirs(out, exist_ok=True)
    CHN = ["master", "pulse1", "pulse2", "wave", "noise"]
    summary = []
    for sid in range(1, NUM_SONGS + 1):
        hdr = u16(d, bf(SONG_TABLE) + (sid - 1) * 2)
        if not inb3(hdr):
            continue
        ho = bf(hdr)
        flag = d[ho]; ho += 1
        song = {"id": sid, "header": f"${hdr:04X}", "flag": f"${flag:02X}", "channels": {}}
        npat = 0
        for ci, name in enumerate(CHN):
            cp = u16(d, ho + ci * 2)
            if not inb3(cp):
                continue
            pats, loop = walk_order(d, cp)
            patterns = {f"${p:04X}": decode_pattern(d, p) for p in dict.fromkeys(pats)}
            npat += len(patterns)
            song["channels"][name] = {
                "order_ptr": f"${cp:04X}",
                "order": [f"${p:04X}" for p in pats],
                "loop_to": f"${loop:04X}" if loop is not None else None,
                "patterns": patterns,
            }
        with open(os.path.join(out, f"song_{sid:02d}.json"), "w") as f:
            json.dump(song, f, indent=1)
        summary.append((sid, f"${hdr:04X}", len(song["channels"]), npat))

    print(f"Extracted {len(summary)} songs -> {out}/ (gitignored)")
    print(f"{'song':>4} {'header':>7} {'#chan':>5} {'#patterns':>9}")
    for sid, h, nc, npat in summary:
        print(f"{sid:>4} {h:>7} {nc:>5} {npat:>9}")

if __name__ == "__main__":
    main()
