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
