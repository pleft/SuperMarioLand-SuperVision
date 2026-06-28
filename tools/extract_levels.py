#!/usr/bin/env python3
"""
Extract Super Mario Land level data (tilemaps + object spawn lists) from the
user's own ROM. RULE 5: this script ships; its OUTPUT (ROM-derived bytes) does NOT
— it is written under build/ which is gitignored.

Format reverse-engineered in docs/10-level-format.md. Level data is in bank 2.

Usage:  python3 tools/extract_levels.py [super-mario-land-gb.gb] [--out build/levels]
"""
import sys, os, json, hashlib

EXPECT_SHA1 = "418203621b887caa090215d97e3f509b79affd3e"

# Level data is split across banks BY WORLD (Call_000_0d6d sets $2000 = bank):
#   world 1 -> bank 2, world 2 -> bank 1, world 3 -> bank 3, world 4 -> bank 1.
# Worlds 2 & 4 share bank 1 but live at different table indices (level*2).
WORLD_BANK = {1: 2, 2: 1, 3: 3, 4: 1}
def bank_file(bank, gb):  return bank * 0x4000 + (gb - 0x4000)  # GB addr in `bank` -> file offset
def world_of(level):      return level // 3 + 1                  # level 0-11 -> world 1-4

SEGPTR_TABLE   = 0x4000        # bank2: per-level -> segment pointer table
SPAWN_TABLE    = 0x401A        # bank2: per-level -> spawn list
PARAM_TABLE    = 0x2436        # bank0: per-level param byte (file offset == addr)
NUM_LEVELS     = 12
COL_HEIGHT     = 16
BLANK_TILE     = 0x2C

def u16(d, off): return d[off] | (d[off + 1] << 8)

def decode_segment(d, bank, seg_gb, max_cols=4096):
    """Decode column data starting at GB addr seg_gb in `bank`. Returns list of
    columns; each column is a list of COL_HEIGHT tile ids. Stops at $FF."""
    o = bank_file(bank, seg_gb)
    cols = []
    col = [BLANK_TILE] * COL_HEIGHT
    while len(cols) < max_cols:
        cmd = d[o]; o += 1
        if cmd == 0xFF:                 # end of level
            cols.append(col); break
        if cmd == 0xFE:                 # end of column
            cols.append(col); col = [BLANK_TILE] * COL_HEIGHT; continue
        off = (cmd >> 4) & 0x0F         # starting Y
        cnt = cmd & 0x0F
        if cnt == 0: cnt = 16
        i = 0
        while i < cnt:
            t = d[o]; o += 1
            if t == 0xFD:               # end run early
                break
            if 0 <= off + i < COL_HEIGHT:
                col[off + i] = t
            i += 1
    return cols

def decode_spawns(d, bank, gb):
    """3-byte entries [col, position, type], ascending by col, until col drops/ends.
    position: Y = (pos&0x1F)*8+0x10 ; X screen-offset = (pos>>6)&3."""
    o = bank_file(bank, gb); out = []; last = -1
    for _ in range(256):
        c, pos, typ = d[o], d[o + 1], d[o + 2]
        if c < last:                    # columns are ascending; a drop = end
            break
        out.append({"col": c, "type": typ,
                    "y": (pos & 0x1F) * 8 + 0x10, "x_off": (pos >> 6) & 3})
        last = c; o += 3
        if c == 0xFF:
            break
    return out

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rom = args[0] if args else "super-mario-land-gb.gb"
    out = "build/levels"
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
    if not os.path.exists(rom):
        sys.exit(f"ROM not found: {rom} (supply your own legally-owned ROM)")
    d = open(rom, "rb").read()
    sha1 = hashlib.sha1(d).hexdigest()
    if sha1 != EXPECT_SHA1:
        print(f"WARNING: SHA1 {sha1} != expected {EXPECT_SHA1} (continuing)")

    os.makedirs(out, exist_ok=True)
    summary = []
    for lvl in range(NUM_LEVELS):
        world = world_of(lvl)
        bank  = WORLD_BANK[world]
        seg_tab = u16(d, bank_file(bank, SEGPTR_TABLE) + lvl * 2)
        spawn_p = u16(d, bank_file(bank, SPAWN_TABLE)  + lvl * 2)
        param   = d[PARAM_TABLE + lvl]
        # segment pointer table: read pointers until one leaves bank range
        segs = []
        for s in range(16):
            sp = u16(d, bank_file(bank, seg_tab) + s * 2)
            if not (0x4000 <= sp < 0x8000):
                break
            segs.append(sp)
        cols = decode_segment(d, bank, segs[0]) if segs else []
        spawns = decode_spawns(d, bank, spawn_p)
        lvldata = {
            "level": lvl, "world": world, "stage": lvl % 3 + 1, "bank": bank, "param": param,
            "seg_ptr_table": f"${seg_tab:04X}", "segment_ptrs": [f"${x:04X}" for x in segs],
            "columns": cols, "width_cols": len(cols),
            "spawns": spawns,
        }
        with open(os.path.join(out, f"level_{lvl:02d}.json"), "w") as f:
            json.dump(lvldata, f, indent=1)
        # flat SV tilemap binary: column-major, COL_HEIGHT (16) tile bytes per column.
        with open(os.path.join(out, f"level_{lvl:02d}.bin"), "wb") as f:
            for col in cols:
                f.write(bytes(col))
        summary.append((lvl, f"{world}-{lvl%3+1}", bank, f"${seg_tab:04X}", len(cols), len(spawns)))

    print(f"Extracted {NUM_LEVELS} levels -> {out}/ (gitignored)")
    print(f"{'lvl':>3} {'stage':>5} {'bank':>4} {'segTbl':>7} {'#cols':>6} {'#spawns':>7}")
    for lvl, st, bk, sg, nc, nsp in summary:
        print(f"{lvl:>3} {st:>5} {bk:>4} {sg:>7} {nc:>6} {nsp:>7}")

if __name__ == "__main__":
    main()
