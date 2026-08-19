# The 2-3 ending: sphere -> rescue scene, W2 flavor (RE + port, 2026-08-18)

All PyBoy-captured (tools/cap_ending23.py: nav to the sphere on the iddqd ROM,
then state walk + per-8f position/cam samples + BG map diffs + OAM through the
room scenes + music/SFX hooks + VRAM dump for the creature hunt).

## The GB state walk (frames measured, sphere touch = f0)

$07 239f freeze -> $05 ~327f tally -> $06 37f -> $1C 7f -> $1D 64f -> $1E 39f
-> $1F 16f -> $20 59f -> $21 31f -> $22 162f -> $23 60f -> $24 300f -> $25 64f
-> $26 533f -> $12/$13 -> the BONUS GAME ($15/$16, track $09) -> next level.
Same skeleton as 1-3 (docs/25), and the beats are the SAME lengths ($1C+$1D =
71f; $22 162f, $23 60f, $24 300f, $25 64f, $26 533f).

## What differs from 1-3 (everything else is byte-identical machinery)

1. **The sub stays through the freeze + tally** (OAM at touch+120: quad
   $70-$73 still drawn; at tally+8 it's still there while every enemy is
   already a $9D/$9E cloud). Mario replaces it when the walk states begin
   ($06 -> $1C).
2. **The rope is at world col 358** (1-3: 298), same rows 9,8,7,6, same
   bottom-up $EC -> $2C at one tile per 8f with SFX $dfe0=$0B, opening during
   $1E. Same screen position (the arena pins with the rope 144px in).
3. **The walk-out choreography**: Mario auto-walks right at 1px/f during $20
   (137 -> 192, out through the rope hole), holds off-screen for $21, and the
   $22 "transition" runs the room in with the camera while his world position
   parks -- his screen x slides 176 -> 16, then $23 walks him 16 -> 76
   (final OAM x 69/77 = visual 61, the SAME mark as 1-3).
4. **The creature**: the fake Daisy becomes the WORLD-2 creature -- same tile
   INDICES $A0-$A3/$B0-$B3, same pair-swapped mirrored composite, same
   sit/fly swap, same parabolic hop arc (rest y120, peak 79, ~4px right per
   8f) -- only the PIXELS differ. Located by VRAM dump + ROM byte-match:
   bank 1, file 0x4032 + n*16 (tops) / 0x4132 + n*16 (bottoms).
5. **The tally burst**: boss alive at the sphere -> at $05 entry the dragon
   (one slot on GB) + Tamao + the in-flight shot all morph to type $27 with
   ONE bang. The GB's single dragon cloud sits at the slot anchor
   (lower-middle of the 16x32 body).

Everything in the room half matches 1-3 exactly: captive $49/$4E/$50/$51 at
x 87-95, swirl tiles $06/$07, texts at the same rows/cadence, music $0F at
$22 / $12 at $25 / 3x $dff8=$03 thumps in $25's tail, bonus track $09.

## PORT

The 1-3 machine (goal phases + l3e_seq + the L13E room overlay) is reused
whole. The 2-3 deltas, placed where bytes existed (FIXED had ONE spare byte):

- **Arming** (kit, W2FAR `veh_arm`, called from veh_clear at the sphere):
  `ending13 = 2` (the flavor tag) + `e_cap = <358` -- l3e_rope_tile now reads
  the rope column's LOW byte from e_cap (both levels' high byte is 1; the
  arm sites own the value: l3_goal_chk sets <298). e_cap is free until
  E_ROPE and only later re-purposed by @towalk for the captive gate.
  That indirection cost FIXED exactly +1 byte -- the last free byte.
- **The handover** (kit, W2FAR `sub_step`, wired as OBJ_SUBV's step row --
  a 0-byte table swap): the sub idles through play/jingle/tally (GB-true:
  the hull is visible the whole time, veh_vec keeps draw_player off), and at
  the LAST phase-4 frame it kills the hull, clears veh_vec, and resets
  Mario's pose -- the sub/Mario swap lands exactly at the GB's $06 -> $1C.
  (During goal phases the main loop bypasses the whole player block, so
  veh_step never runs -- the sub's own step is the only kit hook alive.)
- **The burst**: l3e_boom's upper bound became a constant 47 (0 bytes),
  covering the 2-3 kit types 36-46. Known cosmetic divergence: the pinned
  dragon is TWO port slots (head + DRGB), so a boss alive at the sphere
  bursts into two stacked puffs where the GB shows one (at the DRGB spot).
- **The creature sheet**: extract_gfx emits build/gfx/creature23.svt (8
  tiles, same port draw order as the moth); pack_banks pins it at bank 6
  $B900. The room machine's @pdone (L13E, bank 1 had 89 bytes free) maps
  bank 6, copies the 128 bytes over the RAM moth_tiles, and maps bank 1
  back -- one-shot by construction (it runs once, when the swirl ends),
  gated on ending13 == 2. 1-3 keeps its moth untouched.
- **The walk-out transient** is the 1-3 style (Mario stays on screen and
  drifts to his mark during the scroll) rather than the GB 2-3 exit-and-
  re-enter -- same divergence the user approved for 1-3; the final tableau
  (Mario 61, captive 79) is GB-exact for both.

After the bonus game next_level wraps to 1-1: there is no World 3 yet.

## The tile_mod overrun (found by the ending harness, bigger than the ending)

The end-to-end nav kept swimming THROUGH the sphere. Measured cause: the
sphere cell read as "modded" -> the vehicle mod transform serves $2C, and
dumping the mod bitmap showed cols 336-359 covered in pseudo-random churning
bits AT LEVEL ENTRY. `tile_mod` was 680 bytes = 320 surface cols + the room's
40 -- but 2-3 is 360 cols wide: its arena cols 340-359 indexed PAST the array
into the OBJECT SLOT arrays. Every tile probe in the last 320px of 2-3 read
live enemy fields as mod bits (rope/bricks/sphere randomly blank or "used"),
and every mod WRITE there (arena coins, the tunnel bricks) OR'd a bit into an
enemy slot -- a real corruption source in the boss arena. Fix: tile_mod is
720 bytes (cols 0-359); the room's 20 cols key at +640 = cols 320-339, dead
aliasing since no room level exceeds 320 surface cols and 2-3 has no rooms.

## Verification

- GB side: full state walk + OAM + music captured (this doc's numbers).
- Port sim: real steering into the sphere -> arm asserts (ending13/e_cap/
  hull alive) -> phase walk with slot dumps at the burst -> handover asserts
  (veh_vec=0, hull gone, pose reset at the last phase-4 frame) -> rope ->
  scroll -> room-copy BYTE-ASSERT vs the bank-1 blob -> creature BYTE-ASSERT
  vs the bank-6 sheet -> texts/swirl/fly -> bonus_phase=2. Screenshots per
  phase via the scroll_vis-aware dump.
- 1-3 regression: the same run green with e_cap=$2A, moth bytes UNTOUCHED.

Two more lessons the harness taught:
- **Screenshots must be RING-aware**: the fb is a 48x170-byte ring; the
  visible window starts at (ring_y, ring_xb) + scroll (calc_view). A dump
  from byte 0 showed both rooms "shifted" (1-3 by -24, 2-3 by +24) when the
  hardware view was pixel-correct in both. Extends the docs/25 lesson: not
  just scroll -- ORIGIN.
- The sub gets the tally-burst dodge one frame early (phase 2, goal_tmr 1),
  not at the burst itself: l3e_boom runs from goal_seq BEFORE update_objects,
  so the sub's step never sees phase 3 in time.
