#!/usr/bin/env python3
"""
Extract SML music tracks (bank-3 sequence data, RE'd from MusicStart_6AB5 +
the walker at $6CBE; format VALIDATED against PyBoy write-log captures of
track $07 -- ch2 = 77/77 note events matched in order, timing within 0.5
frames at 64Hz ticks). RULE 5: everything lands in gitignored build/audio/.

Song: SongTable_663C[track-1] -> header [b0][lentblptr][ch1][ch2][ch3][ch4].
Channel = list of 2-byte phrase pointers; control by entry HI byte (6C7F):
$FFxx = JUMP: the next word is a list address to continue from (the loop
point -- track 7 loops to entry 2: entry 1 is a play-once intro), $00xx =
END (one-shot jingles: the goal fanfare's ch1 stops the song). The stop
path (6CB1) kills the WHOLE song, so a channel list may lack a terminator
entirely (track $0F ch2 abuts phrase data): we end a list when it runs
into a known phrase/list address.
Phrase bytes: $00 next-phrase, $01 hold cell, $9D e d c = instrument
(e = GB NRx2 envelope, c = GB NRx1 duty), $A0-$AF = cell length := tbl[x]
(ticks @64Hz), even bytes = note: byte indexes NoteFreqTable_6E74 (2B LE).

Port encoding (music.bin):
  [0]        note table: 0x98 entries x 2B little-endian SV F (byte-index*2)
  [ntab]     drum table: N x 3B [FREQVOL init (svN<<4|vol), env (GB NRx2), cutoff ticks]
  per track: [16B length table][phrase blob][ch1..ch4 lists]
  lists hold 16-bit offsets from music.bin start; $FFFF+target = jump, $0000 = end.
  ch4 phrases have their drum bytes REWRITTEN to 1-based dense drum-table indices
  (on the GB ch4 every non-command byte is a drum -- $01 included: it is the
  SILENT drum, vol 0; verified 95/95 hits vs capture before its mid-capture restart).
  ch3 (wave) notes keep the shared note table; the player derives the octave-below
  frequency as F*2+1. List terminators: $0000 = a REAL GB end entry (stops the WHOLE
  song, $6CB1); $FE00 = DORMANT (null channel pointer, or a list that just runs out
  unterminated -- the GB treats those channels as inactive, never as a song end).
music.inc: mus_l1..l4 offset tables + mus_track_ids + MUS_* indices.
"""
import os
ROOT = os.path.join(os.path.dirname(__file__), "..")
OUT = os.path.join(ROOT, "build", "audio")
d = open(os.path.join(ROOT, "super-mario-land-gb.gb"), "rb").read()
B = lambda gb: 3*0x4000 + (gb-0x4000)
u16 = lambda o: d[o] | (d[o+1] << 8)

# Track ids verified against the running GB (the old static catalog had THREE wrong
# labels): level $07 (table $07CE), underground $04 ($07C8/$17AB), star $0C ($09C9),
# GOAL = $01 (the bottom-door write at $1B70; $0F was a mislabel), BONUS = $09 (the
# bonus state sets $dfe9=$09; $12 was a mislabel). $0F/$11/$12 = unknown later-level ids.
# Bonus stage (harness, forced $ffb3=$12 with A presses): entry $09 (ladder stage),
# the walk-to-prize $0A (state $17), the award celebration $0D (state $1A), and the
# 1UP chirp $dfe0=$08 at each joy hop.
TRACKS = [0x07, 0x04, 0x0C, 0x01, 0x09, 0x0A, 0x0D, 0x03, 0x0B, 0x0F, 0x12, 0x10]
# W2 tracks ride in the W2 banks' PREFIX copies, in the byte-space of tracks a
# W2 bank never plays (the packer overwrites slot 0's table entries per bank):
#   $08 = the Muda overworld theme (2-1/2-2), $05 = the Marine Pop theme (2-3).
W2_TRACKS = [0x08, 0x05]
NAMES  = ["MUS_LEVEL", "MUS_UNDER", "MUS_STAR", "MUS_GOAL", "MUS_BONUS", "MUS_BWALK", "MUS_BAWARD",
          "MUS_T03", "MUS_BOSS", "MUS_RESCUE", "MUS_REVEAL", "MUS_GOVER"]
# Tracks whose data lives in FIXED (music2.bin) instead of the per-bank LEVELS
# prefix (music.bin): the 1-3 ending set. Offsets are TRACK-RELATIVE either way;
# the player resolves them against the per-track base (mus_base_lo/hi).
# BIAS: relative offsets are emitted +512 and the base tables -512, because the
# list sentinels are HIGH-BYTE-coded ($00xx end / $FExx dormant / $FFxx jump)
# and a small offset's zero high byte would read as END.
FIXED_TRACKS = {0x0B, 0x0F, 0x12}
RAM_TRACKS   = {0x10}   # game-over: FIXED is full; rides in RCODE RAM (bank-6 load)
BIAS = 512

def gb_noise_to_sv(nr43):
    """GB NR43 -> SV noise freq nibble N (freq = 4MHz/(8<<N)); same rule as extract_sfx."""
    s_ = nr43 >> 4; r = nr43 & 7
    gb = 262144.0 / ((r if r else 0.5) * (1 << (s_ + 1)))
    best, bn = None, 0
    for N in range(16):
        sv = 4_000_000.0 / (8 << N)
        e = abs(sv - gb)
        if best is None or e < best: best, bn = e, N
    return bn

NT = B(0x6E74)
ntab = bytearray()
for i in range(0x98):
    x = d[NT+i] | (d[NT+i+1] << 8)
    if x >= 2048: F = 0
    else:
        hz = 131072.0 / (2048 - x)
        F = max(0, min(2047, int(round(125000.0/hz)) - 1))
    ntab += bytes([F & 0xFF, F >> 8])

# pre-pass: find every drum id used by any track's ch4
def parse_phrase_bytes(gbaddr):
    q = B(gbaddr); out = bytearray()
    while True:
        b = d[q]; q += 1
        out.append(b)
        if b == 0: break
        if b == 0x9D: out += d[q:q+3]; q += 3
    return bytes(out)

drum_ids = set()
for tr in TRACKS + W2_TRACKS:
    hdr0 = B(u16(B(0x663C) + (tr-1)*2))
    chp0 = [u16(hdr0+3+i*2) for i in range(4)]
    ch4p = chp0[3]
    if not (0x4000 <= ch4p < 0x8000): continue
    # the same boundary discipline as the main parse: track $01 packs its four
    # lists OVERLAPPING (each starts 2 bytes into the previous, unterminated)
    bounds0 = set(p for p in chp0 if p)
    for ch in range(3):
        if not (0x4000 <= chp0[ch] < 0x8000): continue
        lp = B(chp0[ch])
        while True:
            if lp - 3*0x4000 + 0x4000 != chp0[ch] and lp - 3*0x4000 + 0x4000 in bounds0: break
            p = u16(lp); lp += 2
            if (p >> 8) in (0x00, 0xFF): break
            bounds0.add(p)
    lp = B(ch4p); seenp = set()
    while True:
        if lp - 3*0x4000 + 0x4000 != ch4p and lp - 3*0x4000 + 0x4000 in bounds0: break
        p = u16(lp); lp += 2
        if (p >> 8) in (0x00, 0xFF): break
        bounds0.add(p)
        if p in seenp: continue
        seenp.add(p)
        blob = parse_phrase_bytes(p); i = 0
        while i < len(blob):
            b = blob[i]; i += 1
            if b == 0: break
            elif b == 0x9D: i += 3
            elif 0xA0 <= b <= 0xAF: pass
            else: drum_ids.add(b)          # ch4: EVERY other byte is a drum, $01 too
drum_ids = sorted(drum_ids)
drum_map = {gid: 1+i for i, gid in enumerate(drum_ids)}   # 1-based dense indices
DT = B(0x6F06)
dtab = bytearray()
for gid in drum_ids:
    st = d[DT+gid:DT+gid+5]                # [NR42, special, NR41, NR43, NR44]
    vol = st[0] >> 4
    fv = (gb_noise_to_sv(st[3]) << 4) | vol
    if st[4] & 0x40:                       # length-enabled burst -> cutoff in 64Hz ticks
        cut = max(1, round((64 - (st[2] & 63)) / 256 * 64))
    else:
        cut = 0
    dtab += bytes([fv, st[0], cut])
    print(f"drum ${gid:02X} -> idx {drum_map[gid]}: NR42={st[0]:02X} NR41={st[2]:02X} "
          f"NR43={st[3]:02X} NR44={st[4]:02X} => fv={fv:02X} cut={cut}")

out = bytearray(ntab)
out3 = bytearray()               # RAM-resident tracks (RCODE blob)
out2 = bytearray(dtab)           # drum table -> FIXED (music2): shared, but costs
DRUMS = 0                        # every bank if kept in the prefix
inc = ["; GENERATED by tools/extract_music.py (build artifact)"]
inc.append(f"MUS_DRUMS = {DRUMS}")
track_lists = {}
track_base = {}
def convert_track(tr):
    song = u16(B(0x663C) + (tr-1)*2)
    hdr = B(song)
    lentbl = u16(hdr+1)
    chp = [u16(hdr+3+i*2) for i in range(4)]
    tout = bytearray()
    ltab_off = 0
    tout += bytes(d[B(lentbl):B(lentbl)+16])
    phrases, order = {}, []
    lists = []   # (entries, loop_ix or None); None entries-list = null channel
    bounds = set(p for p in chp if p)
    for ch in range(4):                      # all four GB channels
        if not (0x4000 <= chp[ch] < 0x8000): # null pointer (e.g. goal ch3/ch4)
            lists.append((None, None, b"\x00\xFE"))
            continue
        base = chp[ch]; lp = B(base); lst = []; loop_ix = None
        term_bytes = b"\x00\xFE"            # truncated list = dormant channel
        while True:
            gbaddr = lp - 3*0x4000 + 0x4000
            if gbaddr != base and gbaddr in bounds:
                break
            p = u16(lp); lp += 2
            if (p >> 8) == 0x00:
                term_bytes = b"\x00\x00"    # a REAL end entry: stops the whole song
                break
            if (p >> 8) == 0xFF:
                tgt = u16(lp)
                loop_ix = (tgt - base) // 2
                assert 0 <= loop_ix <= len(lst), f"list jump outside list: {tgt:04X}"
                break
            bounds.add(p)
            key = (p, ch == 3)               # ch4 phrases are rewritten: separate blob
            if key not in phrases:
                q = B(p); blob = bytearray()
                while True:
                    if q >= len(d) or len(blob) > 400:
                        raise SystemExit(f"RUNAWAY track ${tr:02X} ch{ch+1} phrase ${p:04X}: "
                                         + " ".join(f"{x:02X}" for x in d[B(p):B(p)+24]))
                    b = d[q]; q += 1
                    blob.append(b)
                    if b == 0: break
                    if b == 0x9D: blob += d[q:q+3]; q += 3
                if ch == 3:                  # remap drum bytes to dense indices
                    nb = bytearray(); i = 0
                    while i < len(blob):
                        b = blob[i]; i += 1
                        if b == 0: nb.append(0); break
                        elif b == 0x9D: nb += blob[i-1:i+3]; i += 3
                        elif 0xA0 <= b <= 0xAF: nb.append(b)
                        else: nb.append(drum_map[b])
                    blob = nb
                phrases[key] = None; order.append(key)
            lst.append(key)
        lists.append((lst, loop_ix, term_bytes))
    poff = {}
    for key in order:
        p, isdrum = key
        blob = parse_phrase_bytes(p)
        if isdrum:
            nb = bytearray(); i = 0
            while i < len(blob):
                b = blob[i]; i += 1
                if b == 0: nb.append(0); break
                elif b == 0x9D: nb += blob[i-1:i+3]; i += 3
                elif 0xA0 <= b <= 0xAF: nb.append(b)
                else: nb.append(drum_map[b])
            blob = nb
        poff[key] = len(tout); tout += blob
    L = []
    for lst, loop_ix, tb in lists:
        lbase = len(tout)
        L.append(lbase)
        if lst is None:                      # null channel: dormant, NOT song-end
            tout += tb
            continue
        for key in lst:
            o = poff[key] + BIAS
            tout += bytes([o & 0xFF, o >> 8])
        if loop_ix is None:
            tout += tb
        else:
            t = lbase + loop_ix*2 + BIAS
            tout += b"\xFF\xFF" + bytes([t & 0xFF, t >> 8])
    return tout, L, ltab_off, len(order)

for tr in TRACKS:
    tout, L, ltab_off, nphr = convert_track(tr)
    track_lists[tr] = L
    if tr in RAM_TRACKS:
        dest = out3
        base = "mus3_data"
    elif tr in FIXED_TRACKS:
        dest = out2
        base = "music2_data"
    else:
        dest = out
        base = "music_data"
    track_base[tr] = (base, len(dest))
    dest += tout
    inc.append(f"MUS_T{tr:02X}_LT = {ltab_off + BIAS}")
    print(f"track ${tr:02X}: {len(tout)}B -> {track_base[tr][0]}+{track_base[tr][1]}"
          f" lists@{L} ({nphr} phrases)")

# W2 tracks: converted the same way, emitted as standalone blobs. The packer
# writes each into a donor track's byte-space inside the W2 banks' prefix copy
# and repoints slot 0's table entries (mus_base/mus_l1..l4) at it per bank.
w2json = {}
for tr in W2_TRACKS:
    tout, L, ltab_off, nphr = convert_track(tr)
    with open(os.path.join(OUT, f"w2_t{tr:02X}.bin"), "wb") as f:
        f.write(bytes(tout))
    w2json[f"{tr:02X}"] = {"size": len(tout), "lists": L, "lt": ltab_off + BIAS}
    print(f"track ${tr:02X} (W2): {len(tout)}B lists@{L} ({nphr} phrases)")
import json as _json
with open(os.path.join(OUT, "w2music.json"), "w") as f:
    _json.dump(w2json, f)

inc.append(f"MUS_NTRACKS = {len(TRACKS)}")
for i, nm in enumerate(NAMES):
    inc.append(f"{nm} = {i}")
# (mus_track_ids emission dropped: never referenced by the player -- 12 dead FIXED bytes)
for ci in range(4):
    inc.append(f"mus_l{ci+1}_lo: .byte " + ", ".join(f"<{track_lists[t][ci]+BIAS}" for t in TRACKS))
    inc.append(f"mus_l{ci+1}_hi: .byte " + ", ".join(f">{track_lists[t][ci]+BIAS}" for t in TRACKS))
inc.append("mus_lt_lo: .byte " + ", ".join(f"<MUS_T{t:02X}_LT" for t in TRACKS))
inc.append("mus_lt_hi: .byte " + ", ".join(f">MUS_T{t:02X}_LT" for t in TRACKS))
inc.append("mus_base_lo: .byte " + ", ".join(
    f"<({sym}+{off}-{BIAS})" for sym, off in (track_base[t] for t in TRACKS)))
inc.append("mus_base_hi: .byte " + ", ".join(
    f">({sym}+{off}-{BIAS})" for sym, off in (track_base[t] for t in TRACKS)))
for t in TRACKS:
    sym, off = track_base[t]
    inc.append(f"; track ${t:02X}: {sym}+{off}")
os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, "music.bin"), "wb").write(bytes(out))
open(os.path.join(OUT, "music2.bin"), "wb").write(bytes(out2))
open(os.path.join(OUT, "music3.bin"), "wb").write(bytes(out3))
open(os.path.join(OUT, "music.inc"), "w").write("\n".join(inc) + "\n")
print(f"music.bin: {len(out)} bytes (LEVELS prefix), music2.bin: {len(out2)} bytes (FIXED), music3.bin: {len(out3)} bytes (RCODE RAM)")
