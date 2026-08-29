# Rendering / OAM Subsystem (Task #2)

How the screen is composed each frame. All [FACT] unless tagged. Addresses are GB.

## VRAM layout (observed)
| Region        | Use |
|---------------|-----|
| $8000–$8FFF   | sprite (OBJ) tiles; some BG tiles too (loaded in State_0E to $8800) |
| $9000–$97FF   | BG tile patterns (animated tiles updated at $95D1, see #7) |
| $9800–$9BFF   | **BG map 0** (32×32 tilemap); status bar uses top rows |
| $9C00–$9FFF   | **BG map 1** = window layer (used by state $3A and others) |

### Status-bar tile positions in BG map 0 (top row area)
- $9806/$9807 — 2-digit BCD display from `$DA15` (#3)
- $9820       — score digits, from BCD `$C0A0..$C0A2` (#5)
- $9831–$9833 — 3-digit BCD display from `$DA00..$DA02` (#6) = **game TIMER** (see docs/13)

## OAM (sprites)
- **[FACT]** Shadow OAM buffer at **`$C000`** (40 entries × 4 bytes = 160).
  Game logic writes sprites here; it is DMA'd to hardware OAM each VBlank.
- **[FACT]** OAM-DMA routine lives in HRAM at **`$FFB6`** (copied from `$3F92`
  during init). Body: `ld a,$C0; ldh [rDMA],a; ld a,$28; .wait: dec a; jr nz; ret`.
- **[CAND]** Parallel BG-map shadow/metadata array at **`$C800`** (= `$9800`+$3000;
  `$2258` writes `[h+$30]`=meta alongside each map tile). Used for collision/tile-type.

## The VBlank rendering chain (runs inside the VBlank ISR, in this order)
VRAM is only safely writable during VBlank, so all VRAM commits happen here:

| # | Addr  | Name (symbols)            | Role | Gate |
|---|-------|---------------------------|------|------|
| 1 | $2258 | VBlank_ScrollColumnUpd    | draw the next BG-map column from 16-byte buffer `$C0B0` as the level scrolls; column cursor `$FFE9` cycles `$40..$5F` | `$FFEA==1` |
| 2 | $1B86 | VBlank_ProcessVRAMQueue   | apply queued single-tile VRAM writes (cmd in `$FFEE`, target ptr, values like $7F/$2C) — block-break/coin pickups | cmd-driven |
| 3 | $1C33 | VBlank_UpdateDisp_DA15    | write 2-digit BCD `$DA15` → map `$9806/$9807` | `$FF9F==0`, `$C0A3` |
| 4 | $FFB6 | (OAM DMA)                 | DMA `$C000` → OAM | always |
| 5 | $3F39 | VBlank_DrawScore          | BCD score `$C0A0..2` → tiles `$9820..` (blank leading zeros with $2C) | `$FFB1` dirty |
| 6 | $3D6A | VBlank_UpdateDisp_DA00    | 3-digit BCD `$DA00..2` → map `$9831..33` | `$C0A4==0`, state<$12, `$DA00==$28` |
| 7 | $2401 | VBlank_AnimateTiles       | copy an 8-byte tile pattern → `$95D1` every 8 frames (animated tiles); source `$3FC4`+idx or `$C600` | `$D014`, state<$0D, `$FFAC&7==0` |

After the chain the ISR: `inc $FFAC`; if state==$3A enable window (`set 5,rLCDC`);
`rSCX=rSCY=0`; `$FF85=1` (frame done); `reti`.

## Key variables (rendering)
| Addr  | Meaning |
|-------|---------|
| $C000 | **[FACT]** shadow OAM (40×4) → DMA each VBlank |
| $C0B0 | **[FACT]** 16-byte BG column buffer for scroll updates |
| $C800 | **[CAND]** BG-map shadow/metadata array (tile-type/collision) |
| $FFB1 | **[FACT]** score-display-dirty flag (set by score-add `$0166`, cleared by `$3F39`) |
| $FFE9 | **[FACT]** scroll column cursor ($40..$5F) |
| $FFEA | **[FACT]** scroll-update enable / phase |
| $FFEE | **[CAND]** VRAM-write queue command byte |
| $DA15 | **[CAND]** value shown at $9806/$9807 (2-digit) |
| $DA00–$DA02 | **[FACT]** game TIMER (BCD countdown); $DA1D = time-up trigger (docs/13) |

## Port implications (Watara Supervision)
- Supervision has a **linear framebuffer LCD**, not a GB tile/OAM PPU. The whole
  "shadow OAM + DMA" and "BG tilemap + scroll-column" model must be re-expressed as
  framebuffer blitting on the target. The *logical* structure here (what to draw,
  when, from which buffers) is what we reproduce 1-1; the mechanism changes.
- The status-bar split (STAT/LYC ISR) has no Supervision equivalent — revisit in
  the port phase (tracked separately).

## TODO / open
- [ ] Confirm $C800 meta-array purpose by xref from collision code.
- [ ] Confirm $DA00/$DA15 identities (coins / timer / lives) via the gameplay code.
- [ ] Document where game logic builds the $C000 OAM buffer (sprite assembly).

## ATOMIC erase+draw for sprites that overlap nothing (2026-08-28)

The port's sprite pipeline is: erase every dirty sprite, then draw them all
(pass 3a / pass 4), because one sprite's erase must never land on another's
fresh pixels. That leaves every sprite BLANK from its own erase until its draw
-- and on the real machine the display is not synced to the render (61Hz NMI vs
~50.8Hz LCD), so the beam samples that gap. User, on 3-3's boss: *"it still
flickers a lot even with 1 boulder ... we only have mario, boss and one boulder
on the scene"*.

The whole split is only needed for sprites that actually OVERLAP:

* `@spread` already box-tests every pair (and Mario vs every slot). It now marks
  **bit3 of `o_nfl`** on any pair where BOTH are dirty -- "entangled" -- and
  `m_dirty` bit1 for Mario. Only j is marked in the slot loop: the loop visits
  (j,i) too and marks i there on the same terms.
* pass 3a: a dirty sprite that is **visible and not entangled** is drawn RIGHT
  AFTER its own erase (`jsr p4_one`, then bits 0+2 cleared so pass 4 skips it).
  Its blank window is one blit instead of the whole render.
* Mario, isolated, has his erase moved down beside his own draw; entangled, it
  moves to the END of the erase phase (it only has to precede the DRAWS).

Measured (instrumented build, counters removed before shipping): **30% of the
boss arena's sprite draws and 44% of the 3-3 lift ride's are now atomic**;
Mario takes the tight path in 13% of lift-ride frames (in the arena he is
usually within the coarse 32x28 box of the boss, and that box IS the right test
-- his erase rect is 24px wide).

Space: FIXED had 3 bytes. `draw_obj_sprite`'s 21-entry `cmp/bne/jmp` chain was
replaced by an RTS jump table (`@dtab`), which freed 76 -- gold-identical on all
nine levels by itself.

Two traps this hit, both caught by svgold:
1. **A dead slot is dirty too** (its leftover image still needs the erase) and
   is NOT visible. Drawing it ran the type-0 dispatch -- into address $0001.
   The guard is `and #$0A / cmp #2` (visible AND not entangled), and table
   entry 0 now points at an `rts`.
2. **A dirty slot with no old image** (a fresh spawn) has no box to test, so
   Mario was left "isolated" and his late erase clipped 2-2's score popup. Such
   a slot now holds him in the group.

Note: `o_pdr` (drawn-flag) feeds the kits' slot-reuse guard, so drawing earlier
can change which slot a spawn takes. Scenes stay correct but REPLAYS diverge --
re-record routes on this build (E23).

### what the erase pass will NOT give back (tried and reverted, 2026-08-28)

The probe above says the erase pass is the whole frame deficit, so two ways to
shrink it were tried against it:

* **Exact per-param erase boxes.** The W3 default box is 5 cols x 3 rows = 15
  cells for every metasprite; most are 16x16 (4x3) or 8x8 (3x3). Emitting an
  exact box for all 35 params (packed 2 bytes/entry -- the y-adjust rides in the
  width byte's free bits 3-4 -- because three arrays do not fit the $1500
  window) came out **slower AND wrong**: 842 frames of the lift ride differed in
  pixels (trails) and the logic rate fell 900 -> 750 of 959. The trails are the
  straddle row: `o_pvy` is not 8-aligned while an object moves vertically, so a
  metasprite covers one more tile row than its height implies; adding that row
  back removes most of the saving, and the remaining divergence (o_pvy is itself
  edited by `w3_width` to lift the erase origin, and `@spread` box-tests o_pvy)
  perturbs which slots get redrawn. The 40x24 default's slack is load-bearing.
  REVERTED.
* **The composite blit** (background+sprite merged, one write per cell) is
  already implemented in the aux page (`ax_cell`/`ax_bg`, docs/42) and was
  measured there at **~3x a plain draw** (-12% logic): rebuilding a cell's
  background from the map costs more than the erase it replaces. A leaner
  version that took the background straight from the tile ROM would save the
  16 background stores per covered cell -- roughly 20-25% of sprite work, not
  the 50% the two-pass structure suggests, because the merge still reads two
  sources and writes one.

So the flicker left in dense scenes is not a pass-order or box-size problem: at
~530 cycles per erased cell and a 65,574-cycle frame, a boss (15 cells) plus two
Ganchans plus Mario is simply the machine's limit. The lever that remains is
scene cost -- fewer sprite cells on screen -- which is a game-design decision,
not a renderer one.

### CORRECTION (2026-08-29): the atomic path was measured on the wrong scene

The "measured neutral, 4.3% -> 4.3%" note above came from the 3-3 LIFT RIDE,
where almost nothing is entangled. In the BOSS ARENA -- the scene the user was
actually complaining about -- the same metric read **boss blank 274/581 = 47%**,
which is exactly "it still flickers a lot even with 1 boulder". Two lessons, both
Law E31 again: measure the scene the user plays, and `o_pdr` per frame is the
metric (the strict box-ink metric read 0 wiped frames there because a partial
erase still leaves ink).

Instrumented counters (a throwaway build with the 1-3 bang stubbed for space)
settled the mechanism: in 148 of those frames the erase AND the draw both ran --
the frame boundary simply fell between them. Not an overrun, not the budget: the
gap itself.

**The fix.** The boss could not go atomic because `@spread` marked it entangled
with Mario, and they genuinely overlap (median |dx| 6, |dy| 0 while fighting).
But Mario is not like another sprite: his erase can be hoisted to the FRONT of
the erase phase and his draw is last and lands on top, so a sprite under him
needs no group at all. `@sp_mmark` now sets only `m_dirty` bit1 (Mario back in
the group) and leaves the SLOT's bit3 clear, so it keeps its atomic eligibility:

    boss blank      47% -> 16%
    lift-ride blank 4.3% -> 2.5%

with svgold 9/9 byte-identical and battery31 10/10. The 16% that remains is the
frames where the boss is entangled with its own thrown BOULDER, which holds slot
0 -- the one slot whose erase and draw are adjacent (erases run 9..0, draws
0..9). Giving that spot to the boss (children allocated from the top of the slot
array) is the next lever; it costs ~16 bytes of FIXED, i.e. one more dispatch
chain turned into a table.

### the boulder held the one tight slot (2026-08-29)

With Mario hoisted, the boss's remaining 16% of blank frames were the ones where
it was entangled with its own thrown BOULDER -- and the boulder held **slot 0**,
the only slot whose erase and draw are adjacent (erases run 9..0, draws 0..9).
`w3_spawn_at` (the kit's only caller is `w3_child`) now allocates a child from
the TOP of the slot array, so the thrower keeps the low slot:

    boss blank   16% -> 13%   (atomic in 533 of 581 arena frames, was 380)
    ride blank   2.5% (unchanged)

Paid for with `update_objects`' 21-entry cmp/beq chain -> an RTS jump table, the
same trick `draw_obj_sprite` got; svgold 9/9 identical, battery31 10/10.

What is left is not a scheduling problem: the boss is ATOMIC in 92% of frames
and still blank in 13%, because its own erase+draw pair (a 24px-tall metasprite,
a 4x4-cell box ~ 8500 cycles, plus the draw) is itself ~13% of a 65,574-cycle
frame, so the frame boundary lands inside the pair that often. Its box is
already straddle-exact -- 4 rows is the minimum that covers a 24px sprite at an
unaligned y. Only a composite blit (one write per cell instead of restore-then-
draw) shortens the pair further, and the aux-page implementation of that
measures ~3x a plain draw. 47% -> 13% is where this line of attack ends.
