# The 1-3 ending: sphere, boss explosion, rescue scene (RE, 2026-07-19)

All PyBoy-captured (tools/cap_ending13.py: nav to the arena, fly the boss pass
with his slot frozen at the grounded phase of his own cycle, drop onto the
pedestal, sphere touch with the boss ALIVE; state walk + music/SFX consume
hooks + BG map diffs + OAM traces + screen film).

## The arena (map cols 278-299)

- Bridge = a row of $7F tiles at world row 12, cols 282-296, over an empty
  row 13 and LAVA rows 14-15 ($3B surface / $53 body). The boss stands on it.
- Pedestal/stair block cols 293-296 (top at row 10), the SPHERE = **tile $E1
  at col 297 row 9**, under a solid arch (col 297+ rows 0-5). The rope $EC
  fills col 298 rows 6-9 (walk-through); col 299 rows 6-9 open = the exit.
- **King Totomesu = GB type $08** (the docs' old "type $08 = Batadon" guess was
  wrong). Spawn entry col 146 y 120 x_off 0 → fire cam 2144. Phys 09 33 C4.
  Natural cycle (captured): grounded at y=120 ~32f, then jump: −1px/f up to
  y=100, hold, +1px/f down, ~124f period; screen x essentially static; spits
  fire (SFX $dff8=$04) roughly once per cycle.

## Music discoveries (all four unknown ids resolved)

| id | role | trigger |
|----|------|---------|
| $0B | **BOSS BATTLE** | ObjectSpawnCheck $252F: spawning type's phys byte2 >= $C0 (score class 3 = the 5000-point bosses: types $08/$1A/$32/$48/$5B/$60/$61) → `$dfe8=$0B`. Fires exactly when the boss's spawn entry does. |
| $0F | **rescue walk** ("the 28s epic") | state $22 entry (the wipe/walk-out) |
| $12 | **"OH! DAISY" reveal jingle** | state $25 entry |
| $11 | NOT in 1-3 (state $31 "Mario rises" writes it when $dfe9==0 — the 4-3/real-Daisy path; future) |

## The sphere touch ($E1)

Tile-collision classifier $17DB: `cp $E1 → jp z,$175B` → (state<$0E) → $1B45 =
the STANDARD course-clear entry: walk-anim reset, state $07, and since
$d007==0: `$dfe8=$01` (clear jingle) + $ffa6=$F0 (240f freeze). The x-3 branch
downstream is chosen by the BCD stage in $ffb4 (low nibble 3) — with a
non-x-3 $ffb4 the same touch runs the plain door flow instead (verified both).
NO extra points for a sphere-skipped boss (film: score unchanged + tally only).

## The state walk (frames measured)

$07 239f (freeze; the boss KEEPS jumping) → $05 tally (~450f, tick $dfe0=$0A
every 2f; **at $05 ENTRY a live boss morphs type $08→$27 + BANG $dff8=$01**)
→ $06 37f → $1C 7f → $1D 64f → $1E 39f → $1F 16f ($1E/$1F: the ROPE opens
bottom-up, tiles rows 11,10,9,8 of col 298 → $2C, one per 8f, each with SFX
$dfe0=$0B) → $20 47f → $21 31f (Mario auto-walks right, off-screen) → $22
162f (track $0F starts; the screen is REPLACED column-by-column left→right,
1 col/8f, arena → rescue-room template) → $23 60f (room settles; Mario
re-enters walking from x=16 at 1px/f) → $24 300f (walks to x=76; "THANK YOU
MARIO." typed ~1 letter/16f at row 5; then "OH! DAISY" at row 9) → $25 64f
(track $12) → $26 533f (transform + flee) → $12/$13/$15/$16 = the BONUS GAME
(track $09) → State_08 → next level.

## The boss "death" (type $27, script $3870)

NO bridge collapse, NO falling body (the SMB1-axe memory was wrong): at the
tally start the live boss becomes a hopping EXPLOSION: phys 00 22 00 (free
mover), script alternates metasprite params $14/$15 every 8f (spinning
star/puff) while relocating across the boss/bridge area, ~40f total, then
F3 FF despawn. Bang $dff8=$01 at the morph. A star-killed boss simply isn't
there and the sequence skips nothing else.

## The rescue room (drawn by the wipe, NOT map data)

Template: HUD normal; checker bands $8E/$8F at BG rows 2-3 and 15-17 (floor);
everything else blank $2C. Mario stands (OAM y120/128) on the floor; the
CAPTIVE = 2x2 OAM tiles $49/$4E/$50/$51 attr $20 at x 87-95. Text rows 5 and 9.

## The fake-Daisy transform + flee (state $26)

3 puffs $dff8=$03 (16f apart) at entry; captive sprite swaps to the MOTH:
2x2 tiles $A2/$A3/$B2/$B3 (sitting) / $A0/$A1/$B0/$B1 (wings open), attr $20.
Rest ~56f → parabolic hop: 8f-sampled y walk 120,106,90,81,79,85,98,120
(41px high, 56f) drifting right ~25px/hop, wings open in flight, sitting
between hops (~40f rests), repeating until it exits the right edge. Mario
stays put. $26 runs 533f total then the bonus game takes over.

## PORT (2026-07-19): the ending machine

Replaces the l3_goal_chk stopgap (same position trigger = the pedestal walk
ends at the sphere; now also arms `ending13`). Structure:

- goal_phase 1-4 = the standard clear (jingle 240f / hold 64 / tally / 43f):
  at the TALLY START every live L3-kit slot becomes OBJ_BOOM (44f, the same
  $9D/$9E cloud the GB shows) + the bang $dff8=$01; the boss's head anchor is
  re-centered. Normal rendering runs through these phases.
- goal_phase 5 = `l3e_seq` (FIXED): E_BEAT1 71f -> E_ROPE (4 tiles bottom-up,
  8f apart, SFX $0B; cells blanked on screen AND mod-marked -- read_map_tile
  maps a modded $EC to blank -- so map-driven redraws can't restore them) ->
  E_BEAT2 47f -> E_WALKOUT (1px/f, the 3-pose walk cycle, blank-erased at the
  right edge).
- The room half lives in the **L13E overlay**: a bank-1 blob AFTER L11CODE
  (packer appends both before bank 1's level header; load_level offsets by
  __L11CODE_SIZE__+__L13E_SIZE__), copied to the shared RAM window at the
  wipe -- the L3CODE kit is retired once the sphere is touched. FIXED keeps
  ~350B (arena phases + the copy + enter_bonus); the room machine is 806B.
- E_WIPE: `e_own=1` (the machine owns frames like the bonus does), MUS_RESCUE
  ($0F) starts, 24 tile-columns left->right at 1 col/8f become the room
  template (checker rows 2-3; blank 4-14; checker 15-19 -- the SV playfield
  is 16px taller than the GB screen, so the floor band runs to the bottom).
- E_SETTLE 60f (captive drawn: 2x2 OBJ $49/$4E/$51/$50, x-flipped, at x80) ->
  E_WALKIN (Mario re-enters 8->68 at 1px/f; draw = 3x3 blank-box erase +
  draw_player with mario_vx fed manually) + "THANK YOU MARIO." types at
  1 char/16f (row 5) -> E_TEXT2 "OH! DAISY" (row 9) -> E_JINGLE: MUS_REVEAL
  ($12) + 64f -> E_PUFF: 3x $dff8=$03 thumps 16f apart, then the sprite swap
  to the moth ($A2/$A3/$B2/$B3 sitting, $A0/$A1/$B0/$B1 flying) -> E_FLY:
  rest 56f, then 56f parabolic hops (per-8f-segment y deltas -2-2-1 0 +1+2+2,
  +1px right every other frame, ~25px/hop, 40f rests) until off-screen ->
  E_OUT 60f -> enter_bonus (the same prize-ring + L11 overlay path as the
  top door; the jmp leaves the RAM window before the copy overwrites it).

Verified end-to-end in the harness: sphere at f2679 -> all phases at the
captured GB cadences -> bonus_phase=2 at f4791; screenshots per phase clean;
level-select + 1-1 (bank-1 header shift) + stomp + music 1431/1431 green.

## Hardware feedback round (2026-07-19, user-caught x4)

1. **The whole room was 32px left on hardware**: scroll_apply's @clampend pins
   the framebuffer at fbmax_col and rides the last 32 camera px on scroll_s —
   the arena ALWAYS sits at scroll_s = 32, and the harness dump ignored
   XSCROLL, so every sim screenshot silently showed the wrong window (the
   pause strip, drawn with the port's +scroll_s convention, was the tell:
   correct on hardware while everything else shifted). Fix: the room machine
   screen-anchors every draw (+scroll_s; s is always 0 or 32 here since
   cam_max = 0 mod 32, so byte alignment holds) with right-edge clips at the
   stride; dump_screen now applies scroll_vis with the line-16 split.
2. **Boss dissolved partially**: morphing his slot to the 16px cloud left his
   24px body — the cloud in a fresh slot now, and the dead slot's full tall
   rect is erased by the pipeline's own dead-object path.
3. **Walk/moth erases ate the floor + the gate stripes**: the 3-row blank
   boxes reached the floor row (now capped above row 15) and Mario's walk-out
   box ran past the fb stride at the gate (row-wrap stripes; now clipped).
4. **"Not a moth"**: bottom tiles were +2 (the Gao statue!) instead of +$10
   (one sheet row down). Also the moth's flight crosses the text row — the GB
   uses OAM sprites and never erases; the port repaints the text2 line +
   Mario after each moth blank.

LESSON (structural): a framebuffer-origin screenshot is NOT the screen — sims
must render scroll+split like the LCD does, or a constant 32px offset class
of bug sails through every visual check.

## Polish round 2 (2026-07-19, user-caught x4)

1. **Rope rows off by the HUD offset**: the captured BG rows 8-11 are WORLD
   rows 6-9 (+2 offset) — the port opened two rope rows and punched two holes
   in the wall below the gate. @rows now 9,8,7,6.
2. **The captive's left column vanished as Mario arrived**: MARIO_INX was 68,
   overlapping her at 80 by 4px (GB stops at 61) — his blank-box erase ate
   her edge. Stop at 60.
3. **Half explosion + edge flicker**: l3e_boom burst EVERY kit slot including
   off-screen-left leftovers, drawing partial clouds at the screen edge. The
   burst is now gated to slots whose screen x is 0-159; off-screen slots just
   free (silently, pipeline-erased if ever drawn).
4. **THE MOTH**: tiles $A0-$B3 sit in the per-world OBJ overlay region
   ($8A00+) and the rescue scene loads its OWN overlay there — the W1 sheet
   has different graphics at those indices (that "moth" was assorted 1-3
   sprites; +2 vs +$10 had also mixed in Gao). The real tiles were located
   by dumping VRAM at state $26 and byte-matching ROM: bank 2, file 0x8A32+
   (tops) / 0x8B32+ (bottoms); extract_gfx.py now emits build/gfx/moth.svt
   (8 tiles) and the port draws the moth from that sheet via l3e_mothtile.
   The composite is PAIR-SWAPPED mirrored (left = the higher tile index,
   each x-flipped), per the captured OAM.

## Polish round 3 (2026-07-19): the transition is a SCROLL + the missed windows

Re-examining the GB FILM (not just BG-map diffs) shows states $22/$23 are a
CAMERA SCROLL: ~222px at 1px/f rolling the arena out and the room in from the
right, Mario walking THROUGHOUT (he never exits), the captive entering with
the room. The port now drives the transition through the engine's own
scroller: cam_max/fbmax_col extended 224px (ends 0 mod 32 so the room lands
at scroll_s=0), read_map_tile's past-edge branch serves the room template
(checker rows 0-1 / sky $2C -- NOT tile 0, the '0' glyph! -- / floor 13+),
the streaming+shifts do the rest, and the captive is drawn ONCE into the fb
when her columns have streamed (the DMA shifts then carry her image,
pixel-exact, no redraws). Mario drifts to his mark (60; GB 61).

Also from the newly captured windows:
- The EXPLOSION is the GB's full 16x16 FOUR-QUADRANT cloud (attrs 0/$20/$40/
  $60) -- the port drew only the top mirrored pair ("half sphere"; this also
  finally un-parks the old Nokobon explosion nuance). o_pw -> $83.
- The superball hit sound is $dfe0=$06 (captured; was the wrong chirp id).
- The captive->moth TRANSFORM (state $25 tail, a window never OAM-logged
  before): a 16x16 four-quadrant SWIRL of tiles $06/$07 alternating every 8f
  for ~60f with the three thumps inside it, THEN the moth. Ported as
  l3e_swirl.

LESSON (why these were missed): verification only covered the instrumented
windows -- OAM was logged from $26 on (the transform lives in $25's tail),
the film was read as BG-diff columns (which cannot distinguish a wipe from a
scroll), and the port's existing boom renderer was trusted against a capture
that showed four quadrants. The rule going forward: for any cutscene, film
EVERY state at full rate AND diff the port's own film against the GB's,
state by state, before shipping.

## Polish round 4 (2026-07-19)

- The 16x16 cloud drew its bottom row BELOW the anchor; the pipeline's TALL
  erase covers one row ABOVE it (the Nokobon shell convention) -- the bottom
  halves persisted. The cloud now spans o_y..o_y+16 = exactly the tall-erase
  envelope (stored o_pvy = o_y+8, erase from o_pvy-8, two rows).
- Mario kept pedestal altitude through the transition scroll: he now falls
  2px/f to the room floor as the scroll begins (the GB shows him stepping
  off as the pedestal rolls away).

## Polish round 5 (2026-07-19)

The transition drop was unconditional, sinking Mario into the arena wall he
still stood on. Gated on his front foot's world x >= 2400 (the map edge):
he walks the wall top as it scrolls out, then steps down to the room floor.
