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

COLS_PER_SEG = 0x14                     # 20 — game advances the segment index every 20 columns

def decode_column(d, bank, o):
    """Decode ONE $FE-terminated column starting at file offset o. Faithful to
    LevelColumnStream ($2198): cmd byte = (Y-offset<<4)|run; run 0 -> 16; tiles follow;
    $FD <tile> fills the REST of the run with <tile> (RLE); $FE ends the column."""
    col = [BLANK_TILE] * COL_HEIGHT
    while True:
        cmd = d[o]; o += 1
        if cmd == 0xFE or cmd == 0xFF:  # end of column (or level)
            return col, o
        off = (cmd >> 4) & 0x0F
        cnt = (cmd & 0x0F) or 16
        i = 0
        while i < cnt:
            t = d[o]; o += 1
            if t == 0xFD:               # RLE fill: rest of the run = the next byte
                fill = d[o]; o += 1
                while i < cnt:
                    if 0 <= off + i < COL_HEIGHT:
                        col[off + i] = fill
                    i += 1
                break
            if 0 <= off + i < COL_HEIGHT:
                col[off + i] = t
            i += 1

def walk_segments(d, bank, seg_tab_gb, limit=256):
    """Segment-pointer list for a level, terminated by a $FF low byte."""
    segs, o = [], bank_file(bank, seg_tab_gb)
    while len(segs) < limit:
        if d[o] == 0xFF:                # table terminator
            break
        segs.append(u16(d, o)); o += 2
    return segs

def is_room_segment(d, bank, sp):
    """Pipe/sub-room segments (underground bonus rooms) begin with a SOLID WALL column
    (all 16 tiles identical and non-blank) — the room border. The surface scroll skips
    them: the game enters them only via a pipe (State_0A/0B set $ffe5 from $fff4/$fff5),
    not by walking through. TODO(pipes): extract these separately as pipe destinations."""
    col, _ = decode_column(d, bank, bank_file(bank, sp))
    return len(set(col)) == 1 and col[0] != BLANK_TILE

def decode_level(d, bank, seg_tab_gb):
    """Surface level = 20 columns decoded from EACH non-room segment pointer in order,
    until the segment list's $FF terminator. (Segments repeat — reused 20-column blocks;
    underground pipe rooms are skipped — see is_room_segment.)"""
    cols = []
    for sp in walk_segments(d, bank, seg_tab_gb):
        if is_room_segment(d, bank, sp):
            continue
        o = bank_file(bank, sp)
        for _ in range(COLS_PER_SEG):
            col, o = decode_column(d, bank, o)
            cols.append(col)
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
        segs = walk_segments(d, bank, seg_tab)      # segment list, $FF-terminated
        cols = decode_level(d, bank, seg_tab)       # 20 cols per segment, in order
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
