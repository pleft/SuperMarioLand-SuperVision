# World 3 (Easton Kingdom): the plan (recon 2026-08-19)

3-1/3-2/3-3 = port levels 6/7/8 (extraction already done: build/levels/
level_06..08 + jsons; lvl_ws is generic; next_level wraps at NUM_LEVELS).

## The space problem (measured)

All 8 banks are spoken for: 0=1-2(+title), 1=1-1(+L11/L13E/bonus), 2=1-3,
3=2-1, 4=2-2, 5=2-3, 6=data (2-3 kit blobs, 13.1K free), 7=FIXED. FIXED has
ZERO free bytes. The shared LEVELS prefix ($8000-$A24E, 8783B: music
sequencer + music/sfx data + mario tables + bg charset + engine procs) must
be mapped during play, so a bank hosting a level resident-style has 7601B.
W3 needs ~12.6K (maps+rooms+spawns+kit+gfx) -> no single-bank geometry fits.

## The keys (measured)

1. **Column dedup**: maps are stored raw col-major (16B/col) and columns
   repeat heavily. Per-level pool of unique columns + a 2B-per-column pointer
   table: W1/W2 banks free 1176-3856 bytes EACH; the three W3 maps together
   drop 17280 -> 7952 (118/98/146 unique cols of 460/320/300).
2. **W3's rooms are two unique grids** shared by all three levels (measured
   by hash; same is true within W1/W2 pairs).
3. **pack_banks already patches per-bank prefix copies** (the W2 look: BG
   overlay over bg_chardata $31-$6F + the W2 theme into the W1-theme slot,
   music_data+304, 511B). The W3 look/theme reuse this machinery.

## Architecture

- **Universal map format**: every level/room map = unique-column pool +
  per-column ADDRESS table (2B/col, absolute in-bank). read_map_tile:
  ptr = (map_base + col*2) -> tile = ptr[mrow]. One format everywhere;
  pack decodes back and byte-asserts == the raw extract for every map.
- **W3 cold data lives in bank 6** (prefix-less): the three maps' pools +
  ptr tables, the 2 shared room grids, spawn lists, pipes/blocks, and the
  W3 kit window blob. read_map_tile gets a mapped-bank trampoline (a W3
  flag: map bank 6 around the read, back to the resident); the load-time
  copies ride a w2stub-style stub (window blob + spawns + pipes/blocks
  copied into RAM/window tail).
- **W3's resident bank = an existing W2 bank's freed tail** (bank 5 or 3,
  post-dedup 3.9K/3.3K free): W3 kit far code + the W3 obj gfx slice
  (header +18) + the W3 THEME track (new track-table entry -> tail addr)
  + the W3 BG charset slice read via a new bgchar POINTER (bg_chardata
  becomes (ptr); W1/W2 keep the prefix charset -- zero behavior change).
  lvl_bank_tab[6..8] = that bank; bank 6 is only touched by the
  read-trampoline + load stub (+ kit-side juggling if the gfx slice
  overflows to bank 6).
- **FIXED ledger**: dedup read (~+10), trampoline (~+20), bgchar ptr
  (~+10), W3 header branch (~+14) ~= +55 bytes -> needs a dedicated FIXED
  golf pass, each golf paired with a targeted regression sim.

## Phases (each gated on full sim regressions; capture-first throughout)

- **A. Dedup refactor** (no W3 yet): extractor/pack emit pools+ptrs,
  read_map_tile rework, byte-assert decode==raw for every map+room, full
  regression battery (doors, pipes/rooms, both endings, bonus, respawn,
  block bonks, music). Banks shrink; prefix tables get W3 rows (+8B).
- **B. W3 scaffold**: bank-6 layout + stub, resident-tail content (theme,
  bg slice, gfx slice), headers, walker-boot 3-1/3-2/3-3 with correct
  look/music/rooms/pipes/one-way caps (W3 caps = 7C only).
- **C. Enemies, GB-capture-first, level by level.** Spawn-type ids seen in
  the lists (to be identified on the GB before ANY implementation):
  3-1: $02 $03 $04 $0A $0B $31 $36 $3A $3B $3C $49 (+high-bit variants)
  3-2: $02 $03 $04 $0A $0E $25 $35 $36 $3A $49 (+variants; $25 x11)
  3-3: $02 $04 $0B $0E $31 $32 $36 $38 $39 $3A $3B $3C $47 $56 (+variants)
  Expected cast (to confirm): Tokotoko, Batadon, Ganchan (incl. the
  RIDEABLE rolling stone), Kumo, falling spikes, elevators; 3-3 boss
  Hiyoihoi (throws Ganchans) + sphere + the x-3 rescue (the machine is
  already parameterized: e_cap rope col + creature tile swap).
- **D. 3-3 ending** (W3 creature tiles via the same VRAM-dump+ROM-match).
- **E. Full-game soak + hardware handoff.**
