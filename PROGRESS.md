# Progress Log

Running log of work on the Super Mario Land → Watara Supervision port.
Newest entries at the top. Every entry should be traceable to ROM bytes/code.

## Status board
- [x] Confirm ROM identity (header decode)
- [x] Establish disassembly toolchain (RGBDS 1.0.1 + cc65 2.18 + mgbdis 3.0)
- [x] Produce reassembling disassembly that rebuilds byte-identical ROM ✓ SHA1 match
- [x] Annotate / reverse-engineer subsystems (per-feature; docs/03..14)
- [x] Extract game data at build time (graphics, levels, tables, music/SFX — rule 5)
- [x] Document Watara Supervision hardware (docs/20-21)
- [x] Port to 65C02: WORLD 1-1 FEATURE-COMPLETE (enemies, goal+bonus game, death/
      game-over/time-up, title, audio: SFX + 7-track music engine, GB-exact movement
      physics incl. skid/glide/momentum) — user-verified on hardware
- [x] Multi-level foundation: 64K banked cart + level headers; WORLD 1-2 COMPLETE
      (Bunbun/arrow/falling stones, hidden blocks, block-bounce kill, table-driven
      platforms, 10 object slots, render budget) — user-verified on hardware
- [x] 1-3 PLAYABLE (Suu/spiky ball/Gao+fireball/Batadon+shots, hidden secret,
      water shimmer, track $03; L3CODE bank-2 RAM overlay) — boss arena pending
- [ ] King Totomesu + switch + rescue scene (dedicated GB machinery); then W2+
      (128K cart step), top-score on title, hard-mode toggle, over-HUD row-split

(2026-06-29 → 2026-07-09 work is logged in docs/ + git history rather than here:
rendering/perf rounds, blocks/powerups, enemies, goal+bonus game, death/title,
audio phase. See docs/22 + docs/23 and the memory index.)

## 2026-07-19 (later) — THE TRUE 1-3 ENDING SHIPPED (RE + port, docs/25)
The full x-3 rescue flow, every beat GB-captured then ported: sphere touch ->
clear jingle + freeze (the boss keeps jumping) -> tally (live enemies burst
into the $9D/$9E cloud + bang at its START -- no bridge collapse, no falling
body: the SMB1-axe memory was wrong) -> the rope opens bottom-up (4 tiles/8f,
SFX $0B each) -> Mario auto-walks out -> the arena wipes column-by-column
(1 col/8f) into the rescue room as track $0F starts -> the captive waits ->
Mario re-enters while "THANK YOU MARIO." / "OH! DAISY" type letter-by-letter
-> reveal jingle $12 -> 3 thumps and the fake Daisy becomes the moth, which
hops away off-screen (captured 56f arcs) -> the bonus game -> next level.
Port architecture: arena phases + glue in FIXED (~350B); the room machine =
the L13E overlay (806B, bank 1 after L11CODE, pulled into the shared RAM
window once the kit retires); rope cells mod-marked (modded $EC reads blank).
Harness end-to-end: sphere f2679 -> bonus f4791, all cadences GB-matched;
music/stomp/boot green. OPEN: hardware re-test; W2 next.

## 2026-07-19 — 1-3 ending phase 1: the boss battle music (RE'd + ported)
All four unknown track ids fell in one capture session (docs/25): $0B = BOSS
BATTLE (GB trigger: ObjectSpawnCheck starts it when the spawning type's phys
byte2 >= $C0 — score class 3, the bosses), $0F = the x-3 rescue walk, $12 =
the "OH! DAISY" reveal, $11 = the 4-3 path (future). Port: music tables are
now PER-TRACK BASED (mus_base latched in mus_start; offsets +512-biased vs
the high-byte sentinels) so the ending tracks + the drum table live in FIXED
(music2.bin, 309B+66B) instead of costing every bank; Totomesu's spawn starts
MUS_BOSS (sim: fires at cam 2145 = GB 2144, track playing). verify_music
1431/1431; stomp green; boot clean. Ending machinery itself = next.

## 2026-07-17 (closing) — bridge slop retuned 6 -> 3 (walking falls again)
The two-point foot probes shifted the stone-handoff timing; the 6px slop then
let WALKING cross the collapsing bridge (GB: running only — user-caught).
At 3px both gaits verified: run CROSSES (lands past the shaft), walk FALLS
mid-bridge at world x 1911. Third and final calibration point. (3cdc321)

## 2026-07-17 (night 2) — the L11 bonus overlay + ground probes + Totomesu snap/award
SPACE UNLOCK: the bonus game (~1.2K) moved from FIXED to L11CODE — a bank-1-only
blob (packer: [prefix][L11 @ TITLE0][header][level]), copied to the SHARED
overlay RAM $1500 at bonus entry (bank-switch + 8-page copy; the 1-3 kit uses
the same window — they never coexist, load_level restores the right one).
FIXED went from 1 byte free to ~1.1K. Spent on: TWO-POINT FOOT PROBES (GB
parity): grounded support and landing now probe both feet (+4/+12) — Mario
stands when his body is mostly over a ledge (user-caught at the pillar; edge
tests: centre 11px off = stands, 20px = falls). Totomesu: the cycle snap
double-subtracted 8 (o_vy already stores the adjusted base) — he rose 8px per
hop cycle ("stays midair", user-caught; my earlier test planted o_vy manually
and masked it); ball-kill award corrected to 5000 (user-verified on GB).
Bonus smoke: enters on bank 1, draws, runs, exits to next_level. OPEN: the
boss-battle music switch (no dff0/dfe9 hook fired on approach — a different
write path; RE with the ending phase).

## 2026-07-17 (final) — the fifth bridge stone: hidden on GB, dropped in the port
User side-by-side: the GB shows FOUR stones — the fifth (col 117/pos $8D, world
1880) sits ON the left pillar top and its sprite carries the OAM behind-BG
priority bit, so the bricks hide it completely. The port has no per-pixel
sprite priority and FIXED has 1 byte free, so instead of a draw-time map probe
the extractor now SKIPS that entry (SKIP_SPAWNS in extract_levels.py): it adds
no support Mario can use (the pillar is solid) and the port now matches the GB
pixel-for-pixel — the "stone inside the bricks" mangling is gone with it.
Verified: 4 stones at worlds 1888-1912, the run-across still lands past the
shaft, walking still falls (both GB thresholds hold).

## 2026-07-17 (later still) — the collapsing bridge is crossable (user-caught)
My earlier "verification" only rode the stones down — it never tested RUNNING
ACROSS, which was broken (user: falls after the first stone, can't mount the
far pillar). Mechanism: each stone Mario leaves has already sunk 1-4px, so he
steps off BELOW the neighbour's top, and plat_land only caught tops crossed
from above -> he fell through the row. Fix: a 6px catch slop in plat_land's
crossing test (descent-only, jump-through from below unaffected). Verified by
actually sprinting across: bridge run at stone-top height end to end, lands
past the shaft. (The "4 stones" the user counts = 5 objects with the two end
stones overlapping the pillar tops — GB pool + ROM list both say five.)
FIXED-byte golf: pass-3 erase height selector rewritten (ldy dedupe + shift
trick) to fit the slop bytes.

## 2026-07-17 (late night) — Totomesu refinements (four user-caught on hardware)
(1) The hop SHADOW: his 24px body needs more erase than the 16px tall rule —
o_pw bit6 = EXTRA-TALL (+1 erase row) in pass 3, mask $3F for the width. (2)
Sinking into the bridge: the bob's parity stepping could drift — every cycle
wrap now SNAPS o_y back to the base line (o_vy holds the spawn base). (3)
Backwards fire: the breath was aimed at Mario (even behind him) — now always
his facing (left). (4) Collision: only the FRONT half (head/forelegs, left
16px) hurts — Mario passes over the back/tail like the GB. Byte offsets: the
ball-kill corpse drift now follows mario_facing; the water veto's Mario check
is y-proximity only. Verified: bob 71..88 with exact snaps, all shots left,
zero pixels below the base after cycles. OPEN: the arch stepping-stones
("falling barrels") accuracy — the five single-tile stones bridge the shaft
at cols 235-239; awaiting a specific GB-vs-port difference description.

## 2026-07-17 (night) — KING TOTOMESU: identity, full sprite, 5-hit superball HP
The user's GB screenshot unmasked type $08: it IS King Totomesu (my "moai
flyer/Batadon" label and the "boss = dedicated machinery" theory were wrong —
he was in the pool at spawn col 2144 all along; his "bob" is the hop, his
"shots" the fire breath). Fixes: the half-missing head = his sprite is 32x24
in THREE rows (9 tiles; head $CD/$CE shared by both frames — my earlier OAM
windows clipped it); o_y now anchors at the head row so the tall erase covers
him; superball HP via o_hp (5 hits: 4 chirps, then burst + 2000 — GB capture
2800 = 800 arena-gao + 2000 boss; user-verified "5 or more"); draw_gao and
draw_gcorp merged into one flip-flagged loop to fit bank 2 (now 0 bytes free).
Still pending for the true ending: the switch + bridge collapse + rescue.

## 2026-07-17 (evening 2) — Gao corpse chain: the sfx_play X-clobber
User: "its corpse animation is missing" + "fireballs don't kill Gao" — ONE bug:
l3_gao_kill used X after sfx_play clobbered it, so the corpse-morph writes hit a
garbage slot (the flat squash stuck forever; the ball-killed Gao survived while
the ball expired). phx/plx around the thump fixes both; the ball branch also
lacked its 800 award. Verified: stomp = squash 47f -> falling corpse 47f ->
gone; superball = corpse chain + ball expires + score 000800.
HARNESS LESSON: any L3 proc touching slot fields after jsr sfx_play must reload
or save X (all other call sites already reloaded via ldx oi / find_free_obj).

## 2026-07-17 (evening) — Gao stomp: the inverted branch (user-caught with GB proof)
The column enemy in the user's screenshots was GAO, not the flower — and their
"800" score popup nailed it (Gao = class 2 = 800). upd_gao's stomp test used
bcc @hurt: carry CLEAR from l3_above means Mario IS above, so stomps routed to
the hurt path (death) and side hits to the squash. One-opcode fix (bcs @hurt);
lift top also reverted to the GB-exact o_y=8 per user preference (a33334a).

## 2026-07-17 (later) — 1-3 flower fixes: retract-clip, hold, side-only hurt
Type $02 is the pipe/column FLOWER (not "Suu the spider"): user-caught visible-
inside-the-column + death-on-stomp. GB truth: retracted body hidden via OAM
behind-BG priority (port: rim-clip, base in o_vy); stays down while Mario is
flush (held at 12px, emerges at 14 -> centre dx < 10); stomp-side contact is a
NO-EFFECT exit in the GB contact code (+0=0) so only side contact hurts —
applied via shared l3_hurt to flower/spiky ball/projectiles/moai. Lift polish:
bonk plays the emerge chime (dfe0 $07+$0B captured); stops one row lower so the
rider stays half-visible under the HUD (no over-HUD renderer yet). (63b2eed)

## 2026-07-17 — 1-3 fix: the hidden-block secret is a rideable LIFT
User-caught on hardware: "the elevator ascends alone" — the $13/$14 object is a
LIFT (the stone's ride-morph pattern: contact +0 = landed-on morph), not a
stompable. Landing on it now arms the rise and it CARRIES Mario ~64px to the
secret upper corridor, holds ~4s, pops (thump), rider falls. OBJ_GIFT
renumbered next to OBJ_STONE so the ride procs take the 8px-rideable pair as
one class. 1-2 stones/platforms regression green; port-verified lockstep ride.

## 2026-07-16 — WORLD 1-3 SHIPPED (minus the boss arena — next chunk)
The full 1-3 kit, all GB-capture-verified then port-verified (docs/12 "1-3 kit"):
Suu the spider $02 (200f bob cycle), the spiky ball $0C (~174f hang, 1px/f fall
through terrain), Gao $3F (137f fire cycle; aimed fireball $23: 1px/f x, 0.5px/f
y by Mario's side of the muzzle; stomp->flat 48f->thump corpse), Batadon $08
(32x16, 7-tile frames, bob 17px, shots $1E at ticks 64/121; star->explosion,
5000), and the hidden-block secret $07->$13->$14 (content $07 spawns object $13;
stomp -> floats to the top row + pops with the thump, NO score). Hidden multi-
coin: $5F cells brick-ify once live. Water shimmer: tile $5D's high plane swaps
every 8f (build-time alt tile; overlapped cells skip a tick). Music track $03
extracted + MODEL-VERIFIED in 1-3 (690/690 APU writes); SFX dff8=$04 extracted.
ARCHITECTURE: the kit lives in L3CODE — a bank-2-only blob linked to run at RAM
$1500, copied by load_level; every hook is a type>=OBJ_SUU range check. Freed
the space by moving the 1-2-only bunbun/arrow code to a bank-0-only L12 segment
(-470B in every other bank; banks now: b0 full, b1 2.0K, b2 83B, FIXED ~10B).
Verified: suu/rock/gao/bat/gift timings vs GB traces; walk to cam_max 2240 with
strip captures clean; 1-1 stomp/music/glide + 1-2 full walk + boot pixel-exact
all green. NOT YET: King Totomesu + the switch + rescue scene — the boss is NOT
a $D100 pool object (dedicated GB machinery, like the bonus game) = its own RE
phase, and the MAP HAS NO EXIT (the arena dead-ends at the wall + rope $EC;
GB-verified: a grounded Mario sticks at x=138 with no state change). STOPGAP
(l3_goal_chk, L3-resident, clearly marked): reaching the arena wall at max
camera runs the standard clear sequence -> wraps to 1-1, so the level is
completable on hardware until the boss ships.

## 2026-07-15 (late night) — round 10: stream-hit narrowing (the residual hiccups)
User: much better, hiccups remain at the platform/bee stretches. Profiling the
over-budget clusters: shift frames force-redrew EVERY sprite at fb x>=144 on all
5 streaming frames per shift, though each frame rewrites one 8px strip. Now
stream_one publishes its span and only overlapping sprites redraw (stream_hit);
blank trimmed to the 2 racing bytes; shift frames take 1 budget mover (pend
frames absorb the rest). worst 130->118%, shift median 91->82%, over 39->28/2400,
streak 3. What remains is real load (bees+arrows+platforms all moving, isolated
101-118% singles) — next lever = composite BG+sprite draw (big rewrite, parked).

## 2026-07-15 (night, latest) — round 9: THE root cause — the DMA shift bleed
User: pyramid-to-end flicker/corruption + invisible bonk outcomes, "identify the
root cause". It was in fb_shift8's contract all along: the linear whole-playfield
DMA copy fills each line's right 8 bytes with the NEXT line's left edge. The
original design streamed all 4 margin columns the same frame to mask it; the
1-col/frame amortization broke that, leaving garbage visible for up to 3 frames
whenever scroll_s>0 — invisible over the open-sky first half (white-on-white),
garbage bands over the dense second-half terrain. Fixes: blank_margin zeroes the
bled bytes 42-45 on shift frames (40-41 re-stream same frame; 46-47 can't reach
visibility before the queue drains); flush_stream drains a stale queue before a
second shift; find_free_evict lets block outcomes (coin/hop/mushroom/flower/star)
steal a cosmetic slot (popup/debris/squash/corpse) on a full pool — a brick break
fills the pool and made follow-up bonks consume blocks invisibly (GB block
machinery is outside the pool and never fails). Full detail: docs/22 round 9.

## 2026-07-15 (night, later) — round 8: debris trails (71a849e)
User: bonking a block with an enemy on it left debris crumbs. Root cause = a hole
in round 7's refresh-only rule: a budget-DEFERRED mover is 'clean' but HAS moved;
chain-marking it refresh-only drew it at the new spot without erasing the old image.
mark_slot_y now grants erase-free refresh only when position+token truly match.
Also dropped 1-2's unreachable rooms (empty ROM pipe list, 640 dead bytes in bank 0).
Repro lesson (x3): harness camera/Mario teleports pre-pollute the fb (unstreamed
columns) — every "residue" found in teleported scenes was the plume, not the engine.

## 2026-07-15 (night) — round 7: hiccups (aee9e9c)
Residual 2-4-frame over-budget streaks at kill clusters. Fixes: REFRESH-ONLY
chained redraws (propagation-dirtied objects are unmoved -> draw without erase;
bit2 in o_nfl), subx==0 blitter fast path, slot-staggered popups, 20px propagation
boxes for narrow sprite pairs. Busy half: worst 117%, p95 90%, max streak 1 frame.

## 2026-07-15 (later still) — round 6: the second-half slowdown (faa7fea)
User: corruption + barrels fixed, but the second half of 1-2 "hogs". The margin fix
was redrawing edge sprites EVERY frame (bees/arrows live there after spawning) =
chronic over-budget = sustained sub-61Hz. Fixes: margin redraw only on frames where
a column actually streamed (stream_flag); corpses move 2 steps every other frame
(slot-staggered, same trajectory) — a double-kill (2 corpses+3 arrows+2 popups,
all chained) was the 139% worst frame. Busy-half now p95 97%, longest streak 4f.

## 2026-07-15 (later) — round 5: the streaming-margin conflict (d5bf8b8)
User reported 1-2 visual corruption (trails/notches/garbled sprites) + the second
goal stone invisible until a nearby jump. Root cause: sprites drawn in the fb's
streaming margin (x 160-191, visible when scroll_s>0) get overwritten by streamed
map columns while marked drawn+clean — every right-edge spawn crosses that zone.
Fix: stream before sprites + force-dirty anything at fb x >= 144 (objects + Mario).
Walk-in goal shows both stones; all regressions green. Awaiting corruption re-test.

## 2026-07-15 — round 4: level select, the kill thump, shift-frame fold
- TITLE LEVEL SELECT (user request): Select cycles 1-1/1-2/... (shown top right,
  HUD font); Start launches straight in. Sound test moved to B. (18f8c35)
- Missing sound found via hooked GB capture: the kill THUMP = AI VM opcode F9 03
  ($dff8=$03) in the fly's $15 / bee's $44 corpse scripts (the decoder had been
  mis-reading F9/FA as velocities). Port: kill_flip plays it for fly/bee kills;
  stomped ones thump at squash-expiry (GB-exact delay). Chibibo/Nokobon kill
  chains verified silent. Arrow drops + stone rides verified silent.
- Flicker root cause #2: DMA-shift frames force-redrew every sprite (164% with
  2 bees). render_all pass 0 now folds shift_px into the stored positions; shift
  frames use the normal dirty test + budget. + inlined blitter masks.
  Real 1-2 bee-zone run: p95 90%, p99 106%, 16/900 over (was 176% typical).

## 2026-07-14 — round 3 USER-CONFIRMED on hardware: "flicker is gone, the ending
## area works fine" — WORLD 1-2 COMPLETE. (c68e5a1)
- Object pool 8 -> 10 (GB $D100-$D190): the 1-2 goal area really runs 9 objects
  (2 bees + 4 arrows + platform + 2 stones, GB-capture-verified) — 8 slots were
  silently dropping arrows + starving the 2nd stone.
- Bank swap: bank 0 = title + 1-2 (smallest); 1-1 -> bank 1 (packer); ~280B freed
  in the binding bank. 1-1-view harnesses read file[16K:32K].
- Render budget: rotated pass-1 origin + max 3 pure movers redrawn per frame
  (over-budget movers keep last frame's image; propagation/shift frames exempt).
  Natural end-area: worst 111%, p95 71%, 3/500 frames over.

## 2026-07-14 — feedback round 2: spawn retry, inert hidden cells, flicker perf (41b8be4)
- Full slots no longer eat spawn entries (the vanishing H platform / second goal stone).
- Unlisted $5F hidden cells are INERT (GB $187b: content 0 -> ret) — col 215's "hidden
  1-up" was a leftover marker; the real one (col 95, heart) works.
- Goal stones GB-live-verified: two adjacent one-shot ride-and-fall stones — port exact.
- Flicker (2+ bees): 30Hz staggered motion for bees/arrows + per-type anim tokens +
  a table-driven sprite blitter (2K boot-built shift tables; masks = M(shifted)).
  Worst synthetic frame 176% -> 130% of budget; realistic runs under budget.

## 2026-07-13 (evening) — 1-2 hardware feedback round (a6c0e53)
User hardware test caught four fidelity gaps, all fixed + py65-verified:
- Bunbun NEVER turns to chase (direction fixed at spawn; exits the screen) — the
  shipped per-cycle re-face was an unconfirmed disasm inference (RULE 0 lesson again).
- Arrow head at the BOTTOM (GB list: $BC base, $AC above), leading the fall.
- HIDDEN BLOCKS (tile $5F, blank + non-solid): bonk-from-below materializes the used
  block + pays the contents table (1-2: hidden 1-UP col 95; 1-3 has 3 more incl. a
  hidden multi-coin + unknown content value $07 — 1-3 round).
- BLOCK-BOUNCE KILL: hopping bonks kill the enemy standing on the block (dead-flip +
  class score). Also: dy*48 tables now built in RAM at boot (−320B from every bank).

## 2026-07-13 — Multi-level: 64K banked cart, World 1-2 shipped (1c4f533 + 7f62148)
Movement physics user-confirmed on hardware → started the multi-level phase (docs/24).
- RE: level id $ffe4 (State_08: +1, wrap 12; BCD display $ffb4 +1/+$0D), start segment
  $ffe5 = 3 for EVERY level (Jump_000_0dd3, PyBoy-verified), per-level music table
  bank0 $07CE (1-2 = track $07 = already ported; 1-3 = $03), $d014 = animated-tile
  flag (1-3/2-1/2-2/3-2/3-3/4-2), 1-2 checkpoints = the same 0/640/1280/1920 rule ✓,
  spawner X rule $249B: world x = fire + 192 + x_off*4 (matches 1-1's traced platforms).
- Port: 64K image [bank0][bank1][bank2][FIXED]; LEVELS = common prefix duplicated per
  bank by tools/pack_banks.py; TITLE0 = bank-0-only (banks 1+ overlay it with their
  level region); 18-byte level header + load_level (bank select via SYS_CTRL bits 7:5,
  header + small tables copied to RAM); next_level advances + wraps; HUD stage digits.
- 1-2 kit (all PyBoy-slot-capture-verified, then py65-verified against those numbers):
  Bunbun $42 (fly 1px/f×40 at spawn height, hover 33f, arrow at tick 57, re-face per
  cycle; stomp = flat $C8+$C9 pair + 800; corpse kind 3), arrow $45 (1px/f down, x
  frozen, no terrain, any contact hurts), stepping stone $36→$37 (rideable 8px; landing
  → 8f beat → 1px/f drop carrying Mario). Platforms now table-driven from the 5-byte
  spawn entries (V: spawn-y down 60px; H: spawn-x left 53px; 0.5px/f) — reproduces the
  1-1 dedicated-trace bounds exactly, hardcoded end-area spawner deleted.
- Regressions green throughout: physics T1-T5, stomp, music 1431/1431, 1-1 platforms,
  1-1→1-2→wrap. AWAITING user hardware test of 1-2.

## 2026-07-10
- **Turn-around skid corrected** (`cdc087e`): the real skid = **metasprite 5** (a
  distinct lean sprite, tiles $0A/$0B/$1A/$1B; big = idx 21) + an 8-frame BRAKE state
  ($1e48: input ignored, x frozen, OLD facing). Two earlier ships were wrong because
  the pose was "verified" from eyeballed OAM captures — the fix came from reading the
  code that WRITES $c203 (Player_HorizControl $1d1e). Walk cycle also corrected:
  **3 frames** (metasprites 1→2→3 every 4 moving frames, $1701), was 2-frame/8f.
  Pose tables now 6 small / 7 big entries (extract_tables.py).
- **Movement physics completed** (`3189577`): release GLIDE (neutral → speed idx 0,
  Mario keeps moving in the remembered direction while momentum $c20c decays: 6f ×
  0.5px ≈ 3px; same drift mid-air), persistent speed index $c20e (0/2/4; bump 0→2 at
  momentum 6 — mid-air too), B-rule (bank3 $4975: B+grounded → 2, run 4 at momentum
  ≥3; release → 4→2 even mid-air), duck clears momentum. The invented h_hold ramp is
  deleted. PyBoy captures REFUTED the bank3 jump path ($c20c=$30) — it never runs in
  gameplay; capture before porting disasm-only conclusions. py65 x-trajectories match
  the GB captures frame-by-frame. Full state machine: docs/08-player.md.

## 2026-06-27
- Project initialized. Only artifact present: `super-mario-land-gb.gb` (64 KB).
- Decoded cartridge header → identified as *Super Mario Land*, MBC1, 4 banks,
  no cart RAM. SHA1 `418203621b887caa090215d97e3f509b79affd3e`.
  Details in `docs/01-rom-analysis.md`.
- Wrote project overview + working rules in `docs/00-overview.md`. Recorded the
  central constraint: GB (LR35902) and Supervision (65C02) are not
  binary-compatible, so "1-1" = behaviorally identical (reuse data, reimplement
  CPU logic on 65C02, re-target video/sound I/O).
- Added **rule 5**: never ship copyrighted/ROM-derived material. Repo = code +
  extraction scripts only; user supplies their own ROM; assets extracted at build
  time. Added `.gitignore` enforcing this. Documented the build pipeline in
  `docs/00-overview.md`.
- Toolchain probe: **nothing installed yet.** No RGBDS (rgbasm/rgblink/rgbfix),
  no GB disassembler (mgbdis/ghidra), no 65C02 toolchain (ca65/cl65/acme/xa).
  Have: Homebrew, git, python3 3.9.6. Need to install: RGBDS (source-side
  assembler for verifying the disassembly) and cc65 (ca65/ld65 for the 65C02
  target). mgbdis (python) for the initial disassembly pass.
- Installed toolchain via Homebrew: RGBDS 1.0.1, cc65 2.18. Fetched mgbdis 3.0
  (+ instruction_set.py, hardware.inc) into `tools/`; installed pypng.
- **Phase 1 DONE & VERIFIED:** ran mgbdis → `disasm/` (4 banks, ~55.5k lines).
  `cd disasm && make` rebuilds a **byte-identical** ROM
  (SHA1 418203621b887caa090215d97e3f509b79affd3e). This is the ground truth.
  Recipe + invariant in `docs/02-disassembly-build.md`.
- Started Phase 2 (RE): surveyed bank 00 vectors/boot. Recorded verified facts in
  `docs/03-re-notes.md` — RST_28/30 jump-table dispatcher, interrupt vector
  wiring, main init at $0185, and a BCD score-add candidate at $0166 ($C0A0).
- Phase 2 progress — traced the full top-level architecture from real bytes:
  - **Main init ($0185):** IE/IF=$03, palettes, sound-on, clears WRAM/VRAM/OAM/HRAM,
    copies 12-byte OAM-DMA routine $3F92→HRAM $FFB6, seeds vars, MBC1 bank switch
    via **$2000**, boots into state $0E.
  - **Main loop ($0226):** per-frame bank-3 work, timers, attract logic, runs
    current state, then `halt` + wait on **$FF85** (frame-sync flag) set by VBlank.
  - **VBlank ISR:** draw/commit chain incl. `call $FFB6` (OAM DMA), `inc $FFAC`
    (frame counter), window-enable for state $3A, sets $FF85.
  - **STAT/LYC ISR ($0095):** status-bar raster split (rLYC/rSCX/rWY). PORT NOTE:
    Supervision has no LYC interrupt — must emulate differently later.
  - **Master state machine:** $FFB3 indexes a **62-entry** word table @ $02A6
    (states $00–$3D). Fully decoded → `docs/04-state-machine.md`.
  - Started the RAM/IO variable map (confirmed $2000, $FF85, $FFAC, $FFB3, $FFB6,
    etc.) in `docs/03-re-notes.md`.
- Established the **symbol-file RE workflow** (`docs/05-methodology.md`): jump-table
  targets aren't auto-traced by mgbdis, so we mark them code + name them in
  `symbols/sml.sym` (tracked — it's our RE knowledge, no ROM bytes). Added
  `tools/regen.sh` (one command: stage symbols → disassemble → build → verify
  byte-identical). gitignore updated to track `symbols/`, ignore working copy.
  Seeded sym file with all 56 bank-0 state handlers + named shared helpers.
- Traced early states from real bytes:
  - **State_0E** ($0322, boot): LCD off, clear WRAM, load VRAM graphics, score↔hi-score.
  - **State_11** ($0576): reset score, set up status-bar split (LYC/WY/WX), timer on,
    call level/actor init → candidate **gameplay/level start**.
  - **State_10** ($05CE): empty (ret).
  - Named shared subs: `Memcpy_HL_to_DE_BC` ($05DE), `Fill20_HL_A` ($056F),
    `FillBGMap0_2C` ($05CF).
- **Confirmed [FACT]:** `$C0A0` = score (BCD×3), `$C0C0` = high score (BCD×3).
- **Task #2 DONE — rendering/OAM subsystem** (`docs/06-rendering.md`):
  - OAM = shadow buffer **$C000** (40×4), DMA'd each VBlank via HRAM routine $FFB6
    (source $3F92: `ld a,$C0; ldh [rDMA],a; …`).
  - Mapped the 7-routine **VBlank rendering chain** in order: scroll-column update
    ($2258), VRAM-write queue ($1B86), 2-digit display ($1C33), OAM DMA ($FFB6),
    **score draw** ($3F39, BCD $C0A0-2→$9820, dirty flag $FFB1), 3-digit display
    ($3D6A), animated tiles ($2401). VRAM/status-bar map layout documented.
  - Named all in symbols/sml.sym; rebuild byte-identical.
  - Port note recorded: GB tile/OAM PPU → Supervision framebuffer (reproduce the
    logical draw model, change the mechanism).
- **Task #3 DONE — input/joypad** (`docs/07-input.md`):
  - `ReadJoypad` @ **`03:47F2`** (bank 3), called every frame by the main loop
    (confirmed via byte-pattern search → GB addr $47F2). Standard debounced GB read.
  - **`$FF80` = held**, **`$FF81` = newly-pressed** (edge). Bit layout (both):
    0=A 1=B 2=Select 3=Start 4=Right 5=Left 6=Up 7=Down. No separate "released" var.
  - Named in symbols/sml.sym; rebuild byte-identical. Port note: SV pad has the same
    8 inputs → clean 1-1 mapping (A→B1, B→B2).
- **Task #4 DONE (one sub-item spun out) — player/Mario physics** (`docs/08-player.md`):
  - Struct base **$C200**; **$C201=Y, $C202=X** (verified via scroll math), $C203=anim/
    facing, **$C207=vert state** (0 grnd/fall,1 ascend,2 bonk), **$C20A=on-ground flag**,
    $C20C=H-accel(0..6)/jump-force, $C20E/$C20F=H speed-table idx/toggle.
  - Horizontal: `Player_HorizControl` $1D26 + speed table **$1ECE** (sub-pixel toggle).
  - Jump trigger `Bank3_JumpControl_498B`: edge-A + grounded → $C20C=$30 force, $C207=1.
  - **Descent: $C201 += 3/frame, constant — NO acceleration, NO terminal velocity**
    (verified bank_000:4637-39). Landing snaps to tile; ceiling check $198C sets bonk.
  - Used a subagent for the deep trace, then verified the key constants against bytes myself.
  - Found+fixed a SYMBOL-FILE BUG: mgbdis silently drops any line with an inline `;`
    comment. Rewrote symbols/sml.sym so comments are on their own lines and re-applied
    ALL named labels (they weren't taking effect before). Still byte-identical.
  - One OPEN item → **task #10**: exact jump-RISE integration (bank-3 $490C-$495B is
    mis-aligned/unusual; the per-frame upward displacement constants are not yet
    extracted — left UNKNOWN, not invented, per rule 2).
- **Task #10 (jump-rise) — deep investigation, NOT solved; rescoped to dynamic trace.**
  Exhaustive `$C201`-write census across all banks + hand-disassembly of raw bytes:
  - DISPROVED the bank-3 `$490C-$495B` hypothesis (that region is a pointer helper,
    no `$C2xx` access). DISPROVED `$C20C`=vertical velocity (never added to `$C201`).
  - Found the only `$C201`-decreasing paths are State_30 (cutscene) and the `$2975`
    object ballistic engine (`$FFC1` vel / `$FFC7` accel from table `$3375`; moves
    `$C201` only when `$FFCB` set = riding). Neither is the normal jump.
  - CONCLUSION: gameplay jump-rise is indirect; static RE hit diminishing returns.
    Next step = run in an emulator with a write-watchpoint on `$C201` during a jump.
    Did NOT invent constants (rule 2). docs/08-player.md [OPEN] has full detail.
  - By-product: documented `PhysicsParamTable_3375` + `ObjectPhysics_Integrate`
    ($2975) — the enemy movement engine (useful for task #6). Named in symbols.
- **Task #10 SOLVED via dynamic trace (SameBoy).** Watchpoint `watch $c201 if new < old`
  broke at PC `$4928` with `BC=$C201`, `HL=$216F`. `$490D` IS the ascent — a generic
  ballistic axis-mover that moves Y through caller-supplied `BC`/`HL` pointers (so a
  literal `$C2xx` static scan never saw it; lesson recorded). Mechanism:
  `$C208`=index into **JumpArcTable @ $216D** (27 bytes), `$C207`=state (1 ascend Y-=t[idx]
  idx++, 2 descend Y+=t[idx] idx--), `$7F`=apex. Table (|dY|): 4,4,3,3,2×9,1×7,0,1,0,1,0,0,$7F
  — decelerating rise, symmetric accelerating fall (max 4) then constant +3 free-fall.
  Variable height = `$C208/$C209` hold-counters. Trace matched exactly (idx2 vel3, Y $86→$83).
  Renamed symbol $490D→Bank3_ApplyGravityArc; added JumpArcTable. Full detail docs/08-player.md.
- Installed emulators for the dynamic trace: **SameBoy** (/Applications, text
  debugger) and **mGBA** 0.10.5 (Qt, Lua scripting). Wrote `docs/09-jump-trace-guide.md`
  (verified SameBoy command syntax) and `tools/trace_jump.lua` (mGBA per-frame Y logger).
  Plan: SameBoy `watch $c201 if new < old` → break on a jump → `registers` reveals the
  ascent routine PC (unblocks the static RE); mGBA script captures the full Y arc.
  Awaiting trace data from the user to finish task #10.
- **Task #5 DONE — level/map format & loader** (`docs/10-level-format.md`):
  - Level data is in **bank 2** (gameplay `$FFFD`=2; bank 1 never selected). 12 levels
    (`$FFE4` 0-11), packed world-stage in `$FFB4`.
  - Tables: bank2 `$4000` = per-level segment-ptr table (indexed by `$FFE5`);
    bank2 `$401A` = per-level object spawn list (3-byte: col,type,param); bank0 `$2436`
    = per-level param byte.
  - **Column format** decoded + verified: per 8px scroll, a column = (cmd, tiles…)*
    where cmd = (hi nibble Y-offset, lo nibble run-len); `$FD`/`$FE`/`$FF` = end run/
    column/level; blanks = tile `$2C`; special tiles `$70/$80/$5F/$81` set metadata.
  - Loader: `LevelLoader_2442`, `LevelColumnStream` ($2198), `LevelSpawnSeek` ($245C),
    `State_08` (advance level). All named in symbols; rebuild byte-identical.
  - Fully specifies level extraction for rule-5 tooling (task #9).
- **Task #9 started — level extraction** (`tools/extract_levels.py`): reads the user's
  ROM (SHA1-checked), extracts all 12 levels (tilemap columns + spawn lists) to
  `build/levels/*.json` (gitignored, rule 5). Validates the level RE end-to-end.
- **Discovery via the extractor:** first run produced repeating data (levels 0/3/6/9
  identical) → exposed that **level data is banked BY WORLD**. `SelectWorldBank` ($0D6D)
  maps world (hi nibble $FFB4) → bank: W1→2, W2→1, W3→3, W4→1; sets $2000/$FFFD.
  Fixed the script → 12 DISTINCT levels (widths 420/919/268/137/305, varied spawns).
  Updated docs/10-level-format.md; named SelectWorldBank in symbols. Byte-identical.
  (Lesson reinforced: writing the extractor validates the RE and surfaces wrong assumptions.)
- Open refinements (later): the "main segment" start uses $FFE5 (starts at 3, not 0);
  some decoded widths include chained sub-areas — confirm segment delimiting per level.
- **Task #9 DONE — extraction tooling (rule 5)** built + validated:
  - `tools/extract_levels.py`: 12 levels (tilemaps + spawns) → build/levels/ (gitignored).
  - `tools/extract_gfx.py`: GB 2bpp → PNG tile sheets → build/gfx/. **Verified by eye**
    (Read the PNGs): W1 OBJ sheet = Mario/enemies/UI/"THE END"; BG sheet = font + Egypt
    tiles. Decoder + source addrs ($4032→$8000 256t, $5032→$9000 128t) confirmed.
    docs/11-graphics.md written.
  - Remaining bits spun out → **task #11** (music extractor blocked on #7; per-world
    gfx boundaries via $0DED/$0DF3 tables — refinement).
- **Task #6 DONE — enemy/object framework** (`docs/12-enemies.md`):
  - 10 object slots @ **$D100** (stride $10); 13 working fields → $FFC0..CC
    ($FFC0 type, C1 vel, C2 Y, C3 X, C4 script-PC, C7 accel, C8 move-state).
  - `EnemyUpdate_2491` = spawn-check ($249B, from level list when column hit) +
    AI update ($2648) + collision ($2568).
  - Per-type dispatch: **$349E** AI-script ptr table (~28 types $00-$1B);
    **$3375** physics params (2B/type); shared ballistic engine ($2676/$2975).
  - **Enemy AI = a data-driven script bytecode VM** ($3564..~$3790): PC=$FFC4,
    cmd byte→$D002, $FF=loop, $Fx=control, $Ex=set move-state, else vel/timing.
    (Explains why handlers disassembled as data — they're scripts.)
  - Corrected spawn-entry format to **[col, position, type]** (docs/10 + extractor).
  - Follow-up → **task #12**: decode the script opcode set + enumerate all ~28 types.
  - Named routines/tables in symbols; rebuild byte-identical.
- **Task #7 DONE — sound engine framework** (`docs/13-sound.md`):
  - Request vars: **$DFE0** (SFX id, e.g. jump=1), **$DFE8** (music id), $FFED, $DFE1.
  - `SoundDriver` @ **02:5844** per frame = GameTimerUpdate ($584B) + SoundUpdate ($5892)
    + cross-bank to bank-3 channel engine ($6ECD).
  - APU channel engine in **bank 3 ($67xx-$6Exx)**: per-channel NR-register updates
    (pulse1/2, wave, noise, panning); channel state in $DF00-$DFFF; note ptrs e.g $6787.
  - **Correction:** $DA00-02 = game TIMER (BCD countdown), $DA1D = time-up trigger
    (NOT coins). Fixed docs/06. Named sound routines in symbols; byte-identical.
  - Follow-up → **task #13**: decode music/SFX note bytecode + song table (unblocks #11).
- **Task #8 DONE — $58xx banked trampolines resolved**: states $14/$15/$17/$18/$19/$1A
  dispatch to $5832-$5841 = **jp trampolines in BANK 2** → real handlers $5A72/$5ABB/
  $5B65/$5BEB/$5C44/$5CDE (bank 2). Marked as code + named in symbols; now disassemble;
  byte-identical. Look like level-clear/bonus/ending screens (confirm in #1). docs/04 updated.
- **Task #1 DONE — state machine identified** (`docs/04` purpose table):
  - Boot/title/attract: **$0E** boot, **$0F** TITLE (Start=begin, Select=opt,
    A=pick start world $FFB4; attract demo via $4A94), **$10** empty, **$11** level-start.
  - Gameplay $00; level-advance $08; world-intro $05; cutscene $30; window screens $3A-$3D;
    bank-2 bonus/ending $14-$1A; transitions $01/$02/$06/$07/$0A/$12.
  - Granular sub-states $13/$16/$1B-$2D left as doc TODO (non-blocking).

- === MILESTONE: all original tasks #1-#9 complete. Phase 2 RE breadth done. ===
  Mapped: rendering/OAM, input, player physics (+jump arc), level format+banking,
  enemies framework, sound framework, state machine, MBC banking. Extraction tooling
  (levels+gfx) built & validated. Disassembly stays byte-identical; symbols/docs current.
  Remaining = deep-detail follow-ups: #12 (enemy AI script VM), #13 (music data format),
  #11 (music+per-world gfx extraction, blocked by #13).
- **Task #12 DONE — enemy AI script VM decoded** (`docs/12-enemies.md` opcode table):
  Interpreter $2676, PC=$FFC4. Opcodes: $00-$DF set velocity; $Ex set move-state;
  $F0 face/track; $F1 spawn; $F2 set-accel; $F3 morph-type/despawn; $F4 set $FFC9;
  $F5 cond; $F6 jump-PC; $F8 set-param; $FF loop. Built `tools/decode_ai_scripts.py`
  — decodes all 28 type scripts cleanly (validates the VM). Light remaining: name each
  type to its enemy. Byte-identical.
- **Task #13 — music/SFX data: framework + structure mapped** (`docs/13-sound.md`):
  SFX seqs in bank 3 ($6787/$68FD…), music in bank 2 ($860A…); channel init
  `SoundSeqInit_69C6` (A=priority, HL=ptr) → channel state block in $DF00-$DFFF;
  freq table `NoteFreqTable_6ECD`. REMAINING (deep, kept #13 in_progress): full
  note-sequence bytecode decode — recommend emulator validation (log NR-register
  writes + channel ptr per frame vs sequence bytes, like the jump-arc trace). Then
  write tools/extract_music.py + finish per-world gfx (#11).

- **Task #13 — music: structure LIVE-VALIDATED via emulator** (docs/13-sound.md):
  Watchpoints on rNR13/rNR14 in World 1-1 confirmed: 5 channel state blocks
  $DF00-$DF40 (field layout: +4/5 cur ptr, +0/1 loop ptr, +9/A freq), note data in
  bank 3, NoteFreqTable_6ECD note->freq CONFIRMED (seq $A7 -> $07A7). Fetch routines
  $6C30/$6C45, output $6DA0 named.
- **Task #13 DONE — music format fully decoded** (docs/13-sound.md): 4-level hierarchy
  — SongTable_663C (id→header), header (flag + 5 channel order ptrs), order list
  (pattern ptrs + $FFFF loop), pattern (note bytecode: $00 end / $01 rest / $9D cmd /
  $A0-$AF scale-note+dur / else direct-freq note via NoteFreqTable_6E74). Built
  `tools/extract_music.py` — parses all 19 songs to resolved notes (verified: $52→659Hz E5,
  $58→785Hz G5; live $A7→$07A7). Named song table/freq tables/parsers in symbols.
  Byte-identical. #11 music part done → #11 now just per-world gfx polish (low priority).

- **Task #11 DONE — per-world graphics extraction refined**: read SelectWorldBank's
  world-gfx tables WorldGfxTable1_8A00 ($0DED) / WorldGfxTable2_9310 ($0DF3) + copy-loop
  lengths (61/63 tiles). extract_gfx.py now emits per world: common OBJ/BG + world
  overlays. Verified: W3 overlay = sea-world enemy sprites. docs/11 updated. Byte-identical.

- === STATUS: 13/13 TASKS COMPLETE. PHASE 2 REVERSE-ENGINEERING 100% DONE. ===
  Fully RE'd + documented: rendering/OAM, input, player physics (+exact jump arc),
  level format + world-banking, enemies (+AI script VM), sound (+full music format),
  state machine, MBC banking. Extraction tooling for LEVELS, GRAPHICS, and MUSIC all
  built & validated (rule 5). Disassembly rebuilds byte-identical; symbols/docs current.
  Only remaining: #11 = per-world graphics-sheet boundary polish (low priority).
  Next: Phase 4 (document Watara Supervision hardware) → Phase 5 (65C02 port).

## Phase 4 — Watara Supervision hardware (DONE)
- Researched the target from primary sources (kevtris Supervision_Tech.txt,
  GrenderG/supervision_reveng_notes). Documented in `docs/20-supervision-hardware.md`:
  65C02 @ 4MHz; WRAM $0000-$1FFF, I/O $2000-$202F, VRAM $4000-$5FFF (160x160 2bpp
  LINEAR framebuffer), banked ROM $8000-$BFFF + fixed $C000-$FFFF (≤128K), bank via
  $2026 bits7:5; sound 2 square+DMA+noise; input $2020 (active-low); NMI ~61Hz tick.
- Wrote the **GB→Supervision port mapping** (`docs/21-port-mapping.md`): memory rebase,
  banking, software-render of the framebuffer (GB PPU→SV blit, reuse RE'd column-stream
  + shadow-OAM), APU→SV sound w/ pitch conversion, joypad bit-remap, NMI=frame tick.
  Tasks #14/#15/#16 complete.
- === Phase 4 DONE. RE + extraction + target hardware all documented. ===
  NEXT = Phase 5: 65C02 reimplementation (ca65/ld65 installed). Suggested first slice:
  ca65 project skeleton + SV ROM header/vectors + boot + NMI frame loop + input read.

## Phase 5 — 65C02 port (STARTED)
- **Task #17 DONE — project scaffold + first vertical slice, VERIFIED on hardware emu.**
  Set up the port project: `src/main.s` + `src/supervision.inc` + `cfg/supervision.cfg`
  (ld65 SV 32K memory map) + `Makefile`. `make` → `build/super-mario-land.sv` (32K).
  Slice = boot ($2026 display+NMI+bank, LCD size/scroll) + NMI frame loop + $2020 input
  read with GB-layout remap + full-framebuffer fill.
  **Verified booting+running on Potator (user) AND MAME (snapshot)** — clean uniform
  screen, animates, no artifacts.
  HARDWARE FINDING (verified): VRAM line **stride = $30 (48 bytes), 40 visible**; full
  framebuffer = 7680 bytes. Updated docs/20. Build+test workflow in docs/22.
  Installed MAME 0.288 (svision driver) for automated screenshot testing.
- Next: **Task #18 — software renderer** (GB planar→SV linear tile conversion, tile/
  sprite blit, background column-stream + X_Scroll, sprite blit from shadow-OAM).
- Port source (src/, cfg/, Makefile) is tracked; build/ + *.sv gitignored (rule 5).

## Phase 5 — renderer (Task #18, in progress)
- **GB→SV tile conversion**: added `sv_pack()` to `extract_gfx.py` → emits `.svt`
  (SV linear 2bpp) build artifacts. `src/gfxdata.s` `.incbin`s them (in the fixed
  bank, always mapped). Makefile extracts gfx from the ROM before assembling.
- **`blit_tile`** (opaque, byte/4px-aligned, stride $30) + **`draw_tilesheet`**.
  **VALIDATED on Potator**: the full World-1 OBJ tile sheet (Mario, enemies, UI,
  "THE END", "1UP") renders correctly on the Supervision framebuffer.
- **Hardware scrolling**: confirmed `XSCROLL` = pixel x-scroll, `YSCROLL` = scanline
  y-scroll directly. `scroll_with_dpad` pans the view with the d-pad (interactive
  test; spot-check in Potator by holding the d-pad).
- NOTE: MAME's `svision` driver renders blank for tile content (incomplete driver);
  **Potator is the visual ground truth**. MAME still used for crash/run testing.
- Next renderer pieces: transparent **sprite blit** (Mario/enemies, with pixel
  shifting) and **background tilemap** rendering from the extracted level data.

- **Transparent sprite blit + movable Mario** (built + MAME crash-tested; NEEDS Potator
  visual check): `sprite_blit_tile` (mask-based transparency), `draw_player`/`draw_quad`/
  `set_dst` (16x16 sprite from sheet tiles 0,1,16,17 at $4000+y*48+col), `move_player`
  (d-pad, clamped). Demo = blank bg + Mario you move with the d-pad. X moves in 4px
  (byte) steps for now; pixel-accurate X (sub-byte shifting) is a later refinement.
  TO VERIFY: load build/super-mario-land.sv in Potator — Mario near center, moves with d-pad.

- **Sprite flicker fix**: the flashing was the full-framebuffer clear every frame.
  Replaced with erase-old-position + draw-new, and only when the player actually
  moves (idle = no VRAM writes = no flicker). Added erase_player (clears the 16x16
  at prev_col/prev_y). Sprite renderer confirmed working on Potator (moves with d-pad).

- **Accurate standing Mario via OAM capture**: traced the metasprite engine
  (Bank3 $4823 + table $4C37) — a complex multi-indirect VM. Per the dynamic-trace
  lesson, captured Mario's real shadow-OAM ($C00C, via SameBoy `examine`) instead of
  risking a static decode: standing Mario = 4 sprites, tiles $20/$21/$30/$31 in a 2x2
  (no flip, OBP0 identity). Fixed draw_player to the real tiles. (Full metasprite
  engine + all poses/enemies = task #19, still open.)

- ✅✅ **MILESTONE: accurate Mario rendering on Supervision (Potator-verified).** Fixed
  the sprite column stride (a tile = 8px = 2 SV bytes; right-column tiles were placed at
  +1 byte instead of +2, causing overlap). Verified the extracted tiles decode to a
  pixel-perfect Mario (build/mario_check.png), so the bug was placement only. Mario now
  renders correctly (tiles $20/$21/$30/$31) and moves with the d-pad, flicker-free.
  Full pipeline proven: ROM -> GB->SV tile conversion -> captured real metasprite -> faithful blit.

- ✅✅ **MILESTONE: background renderer — real World 1-1 scene.** extract_levels.py now
  emits a flat SV tilemap binary (level_NN.bin, column-major 16 tiles/col). Added
  bg_chardata (BG tiles) + level0_map to the build (src/gfxdata.s, src/leveldata.s,
  LEVELS segment). render_background draws 20 cols x 16 tiles; get_tile_src selects
  BG set (tile<$80, $9000) vs OBJ/$8800 set (>=$80), per SML's LCDC.4=0 signed BG
  addressing. Static scene + Mario on the ground. Verified the render logic via a
  Python preview (build/bg_preview.png) = pixel-perfect 1-1 (pipe, pyramid, palms,
  ?-block, clouds). All assets fit the 32K ROM. NEXT: scrolling + sprite-over-bg.

- **Sprite-over-background compositing**: Mario now walks left/right on the 1-1 scene.
  move_player = L/R; restore_bg redraws the 3x3 bg tiles under his old position (so no
  black hole), then draw_player at the new spot. Static level (no scroll yet) — Mario
  walks within the visible screen. Built + crash-tested; needs Potator walk-test.

- **Jump physics (real arc)**: extract_tables.py pulls the jump-arc table ($216D, 27B)
  to build/data/jumparc.bin (rule 5); datatables.s incbins it. jump_player: A starts a
  jump (arc index seeded at 2, matching the game), ascend = spr_y-=arc / descend =
  spr_y+=arc walking the table, $7F=apex, land at ground_y. Mario jumps with the real
  decelerating-rise/accelerating-fall feel + L/R air control, bg composited. Standing
  pose for now (jump/walk poses = next). Built + crash-tested.

- **Mario animation**: identified the walk/jump frames in the OBJ sheet (clean 2x2
  metasprites: $20 stand, $22/$24 walk, $26 jump). Parameterized draw_player by
  mario_frame; animate_player picks the pose (jump in air, 2-frame walk cycle while
  moving via frame_count, else stand). Redraw now also triggers on pose change (so he
  doesn't freeze mid-stride). Built + crash-tested. TODO: X-flip for facing left.

- **Animation fixed with REAL captured poses** (small Mario, consistent): stand
  $00/$01/$10/$11, walkA $00/$01/$16/$17, walkB $02/$03/$12/$13, jump $08/$09/$18/$19
  (all from GB shadow OAM $C00C). Replaced the guessed-grid approach with a per-pose
  metasprite table (mario_poses); draw_player reads explicit TL/TR/BL/BR per pose.
  Earlier garble was from guessing the layout (broke "don't improvise" — re-learned).
  TODO(rule5/#19): extract mario_poses from the $4C37 metasprite tables at build time.

- **Sprite X-flip (facing)**: build_revpix builds a 256-byte pixel-reverse table at
  boot (reverses the 4 2bpp pixels in a byte). sprite_blit_tile_flip swaps the two
  row bytes and pixel-reverses each (dst[0]=revpix[src[1]], dst[1]=revpix[src[0]]).
  draw_player mirrors the metasprite (swap TL<->TR, BL<->BR) + sets do_flip when
  facing left; move_player sets mario_facing. Verified flip logic via preview
  (build/flip_check.png = clean mirror). Built + crash-tested.

- **Accurate movement speed**: extracted the walk speed table ($1ECE = [0,1,1,1,1,2]
  px/frame) via extract_tables.py (speedtab.bin, rule 5). Replaced the flat 4px/frame
  with real physics: spr_x tracked in PIXELS; move_player accelerates (h_hold ramp ->
  speed index 0/2/4) and reads speedtab[idx+toggle] (sub-pixel toggle = the game's
  $C20F), so ~0.5..1.5 px/frame. Fixes the too-fast walk + whole-screen jump (jump now
  ~75px since air speed = walk speed). Rendered at 4px granularity for now (choppy) ->
  sub-pixel sprite rendering is next for smoothness.

- **Sub-pixel sprite rendering** (smooth movement): Mario now tracked + rendered at
  PIXEL precision. sprite_blit_subpx unifies flip + sub-pixel: each row's 2 source
  bytes shift left by (spr_x&3)*2 bits into 3 dst bytes (sprite can spill a 3rd byte),
  transparency-merged; calc_mask_A shared. draw_player sets spr_subx; loop redraws on
  spr_x (pixel) change; restore_bg's 6-byte span covers the spill. Verified the shift/
  merge logic via preview (build/subpx_check.png = clean 1px steps). Replaces the old
  byte-aligned + flip blits. Built + crash-tested.

- **Status bar**: captured the GB BG-map status row ($9800) -> 2x20 tile layout
  (MARIO xNN lives, coin xNN, WORLD 1-1, TIME nnn). render_status_bar blits it into
  VRAM rows 0-1 (over the top sky, which Mario never reaches). Verified via preview
  (statusbar_check.png) = authentic SML bar. Static for now (values frozen at capture);
  TODO: dynamic time/score + rule-5 reconstruct from the draw code. Built + crash-tested.

- **BUGFIX (page-cross in blit +2 advance)**: all blits advanced the source/dest
  pointer with `inc a; inc a; bne :+; inc ptr+1`, which only carries on a wrap to $00
  (from $FE), NOT to $01 (from $FF). Tiles whose 16 bytes straddle a $xxFF boundary
  (e.g. status tiles $0D/$1D at $D6FD/$D7FD) read garbage in their 2nd half -> wrong
  glyphs (WORLD/TIME). Fixed all 5 pointer +=2 advances to clc/adc #2/bcc. Hardens
  every sprite + bg blit regardless of data placement. (User spotted the D/T glitch.)

## Scrolling / camera (Phase 5)
- Added a forward-scrolling camera matching SML (no backtrack):
  - `cam_x` (16-bit world scroll px). Mario walks freely until screen X = PIN_X (64),
    then his rightward motion feeds `cam_x` (pinned at center) until CAM_MAX
    = (420-20)*8 = 3200, where he walks to the right edge.
- SV scroll model: framebuffer holds 24 cols (48-byte stride; 20 visible + 4 in the
  8-byte off-screen margin). `XSCROLL` does the fine scroll across the 32px margin;
  when the camera passes a full margin we `fb_shift8` (VRAM-DMA shift left 8 bytes =
  4 cols) and `stream_cols` 4 fresh columns into bytes 40..47. `fb_col0` tracks the
  leftmost resident world column.
- Scroll is byte-aligned (4px steps, `scroll_s & $FC`) so the status bar + Mario stay
  pixel-exact while reusing the byte-aligned `blit_tile`. (Fine 0-3px pixel-delay TODO.)
- Status bar is global-scroll-immune by redrawing it each time `scroll_s` changes,
  offset by `scroll_s>>2` to cancel XSCROLL (no HW window layer on SV).
- Mario is a software sprite, so order each frame = restore_bg (erase, pre-shift) ->
  scroll_update (shift/stream/XSCROLL) -> draw_player at `mario_vx = spr_x + scroll_s`
  (so he composites pinned over the freshly-scrolled bg). `restore_bg`/`draw_player`
  now work in VRAM coords (`prev_vx`) and add `fb_col0` when indexing the level map.
- Refactored `render_background` into a reusable `draw_column(wcol,dbcol)`; renders 24
  cols at boot.
- VERIFIED (python sim of the bookkeeping): Mario pinned at screen X=64 throughout,
  fb_col0/scroll_s step correctly, displayed world tracks cam_x within 4px, level-end
  clean (0 anomalies over 3600 frames). NOT yet verified visually in Potator.
- RISK: `fb_shift8` uses VRAM->VRAM DMA (overlapping, ascending). If Potator doesn't
  emulate VRAM DMA / overlap, the shift fails -> add a CPU-copy fallback.

### Scroll smoothness upgrade (4px steps -> true 1px)
- Dropped the byte-align (`& $FC`): scroll_s is now the full 0..31 offset, so XSCROLL's
  pixel-delay bits (1:0) do the fine 0-3px and bits7:2 the coarse 4px part = smooth 1px.
- Mario already composited via the sub-pixel blit (mario_vx = spr_x + scroll_s), so no
  change there. The only thing needing sub-pixel was the fixed status bar:
  - sprite_blit_subpx gained a `blit_opaque` flag (mask = $FF$FF -> replace all 8px,
    masking still preserves neighbour tiles). draw_quad clears it (Mario stays transparent).
  - render_status_bar now draws each tile at VRAM pixel X = scroll_s (byte scroll_s>>2 +
    sub-pixel scroll_s&3) via the opaque sub-pixel blit, exactly cancelling XSCROLL so the
    bar sits pixel-locked at screen X 0. Verified: writes stay within the 48-byte stride
    (idempotent at the s=32 level-end edge), bar fully covers the visible row.

### Smooth-scroll attempt REVERTED (hardware limit)
- Tried full 1px XSCROLL + per-frame sub-pixel status-bar redraw. Result was janky:
  Mario flicker, status-bar shake, a violent hitch at each DMA-shift frame. Root cause:
  redrawing the whole HUD every frame with the (slow) sub-pixel blit overruns vblank, so
  the LCD scans the framebuffer mid-rewrite (beam racing). The shift frame (DMA + 4-col
  stream + HUD redraw) was the worst.
- HARDWARE FACT (docs/20 line 73, docs/03 line 38): the Supervision has NO LYC/STAT
  raster interrupt. The GB keeps its HUD fixed during a smooth 1px scroll via a STAT
  per-scanline split (rewriting SCX mid-frame); SV can't do that cleanly. Its only timer
  is a coarse periodic IRQ (÷256 / ÷16384 prescaler), not scanline-locked.
- => Reverted to byte-aligned (4px-step) scroll: HUD stays fixed (byte-shift redraw only
  on 4px change, fast, fits vblank), playfield scrolls in 4px steps. Stable.
- OPEN: true 1px smoothness needs a working mid-frame XSCROLL change via the timer IRQ
  (a raster split). Unknown whether Potator re-samples XSCROLL per scanline -> needs a
  cheap feasibility test before committing.

## Scrolling + pinned HUD — SOLVED (2026-06-28)
Final working solution after a long debug (smooth 1px scroll + fixed status bar):
1. **Fast framebuffer shift via VRAM-DMA**, restricted to the PLAYFIELD (lines 16..159).
   The DMA is a clean linear copy; shifting the whole framebuffer bled the blank HUD rows
   upward (the "creep"). stream_cols refills the playfield margins each shift, so no creep.
   DMA copy costs ~0 emulated cycles -> no hitch. (Potator DMA was never broken; my usage was.)
2. **Pinned HUD via a raster split** (needs the per-scanline Potator patch, see below):
   NMI sets XSCROLL=0 (HUD rows 0..15) + arms the timer to fire at scanline 16; the timer
   IRQ sets XSCROLL=scroll_s (playfield rows 16..159). HUD drawn ONCE -> no per-frame redraw,
   no shake, no lag. Timer enable = $2026 bit1; reload $2023=16 (period = data*$100, ~256
   cyc/scanline under the patched render loop).
3. **Draw order matters under per-scanline rendering**: erase+draw Mario BEFORE his scanlines
   (~112-128) render; stream the 4 new columns LAST (they land off-screen, can finish late).
   This removed the periodic shift-frame hitch.
4. **Potator patch** (~/Dev/potator, watara.c supervision_exec_ex): render scanline-by-scanline
   interleaved with the CPU, sampling XPOS/YPOS per scanline (was: whole frame after all CPU
   with one scroll value). Back-compatible for games that set scroll once/frame; enables the
   raster split. Built UNIVERSAL (x86_64+arm64) and installed over the RetroArch core (backup
   = potator_libretro.dylib.orig). NOTE: the pinned HUD needs this patched core under Potator;
   on real SV hardware the split works natively. Corrected $2026 bit map: bit0 NMI, bit1
   timer-IRQ, bit2 DMA-IRQ, bit4 prescaler, bits7:5 bank (our docs/inc were wrong; now fixed).

## Blocks/Coins (#2), Power-ups/Big Mario (#4), Dynamic HUD (#3) — DONE (2026-06-28)
Implemented behaviourally from RE (see docs/14-blocks-powerups-hud.md).
- **#2 Blocks & coins**: head-bonk dispatch in jump_player by tile VALUE — `$81` coin block
  (+coin), `$80` item block, `$82` brick. State tracked in a 640-byte RAM bitmap `tile_mod`
  (level map is ROM); read_map_tile applies the transform on the surface (`$80/$81→$7F` used,
  `$82→$2C` broken) so collision + redraw agree and blocks can't be re-bumped. redraw_one
  repaints the hit cell immediately. Cleared on level restart.
- **#4 Big Mario**: SML big = 16×16 POSE SWAP (not 16×24) — big poses fill the cell, drawn at
  the same feet so he grows upward. Extracted big metasprites [16,19,17,20,22] (+$20 parallel
  of small [0,3,1,4]) → build/data/mario_big_poses.bin. Grow on item block (direct, no mushroom
  entity yet); big-only brick break; duck (Down, grounded) = idx22 pose + no walk; death→small.
- **#3 Dynamic HUD**: draw_hud pokes live digit tiles over the template — score row1 c0-5,
  coins row0 c6-7, time row1 c17-19 (font: digit value = tile number). Clock counts down
  (tick_timer, starts 400). BCD via sed/cld; ISRs do no ADC/SBC so it's interrupt-safe.
- All three build clean (32768 bytes). Logic-reviewed; needs Potator verification by the user.
- Deferred (with the object engine / enemies): coin+mushroom bounce animations, mushroom
  entity, damage-shrink, time-up death, 1-up at 100 coins. Enemies still last.

## ?-block contents table + object engine (mushroom/coin entities) — (2026-06-28)
Fixes from user testing of the first cut:
- **Block contents are TABLE-driven** (bank3 $6536), not the tile value. The mushroom is at
  cols 42/115 (tile $81!), so the old "$80=item/$81=coin" was wrong. extract_levels.py now
  emits level_NN_blocks.bin [col(16),row,value]; find_block looks it up on hit. Unlisted = coin.
- **Used blocks no longer revert to ?** when stepped over / re-streamed: the used-tile transform
  now runs in restore_bg + draw_column too (both routed through read_map_tile), not only collision.
- **Real mushroom ENTITY** (not an instant grow): a ?-block with $28 spawns a mushroom object
  that emerges, slides + falls (gravity/floor via read_solid), and grows Mario only when he
  walks into it. Minimal OBJ_MAX=4 SoA object engine: update/erase/draw, world->VRAM via
  o_x-cam_x+scroll_s, erase mirrors Mario's DMA-shift compensation. Cleared on death/pipes.
- **Coin blocks launch a coin** (coin-pop entity, BG tile $5F) on bonk; coin/score still awarded.
- Lives ($da15) vs coins ($fffa) corrected earlier; coin = +100 score; 100 coins = 1-up.
- KNOWN GAP: mushroom sprite is placeholder OBJ $74-$77 (exact item tiles need a dynamic trace);
  no mushroom wall-collision; $2a/$2c/$c0 contents simplified to mushroom. All builds clean.

## Mushroom sprite identified via SameBoy dump; system NEEDS MORE WORK (2026-06-28)
- Found the real mushroom sprite: ran the original SML in SameBoy, paused with a mushroom on
  screen, dumped OAM (`x/160 $fe00`) + OBJ tiles (`x/512 $8800`). Only non-Mario sprite = tile
  $83 (8x8, sprites are 8x8 mode, LCDC $C3). It was already byte-identical in w1_obj_8000.svt —
  I'd just guessed the wrong index. Mushroom now drawn as OBJ tile $83 at the feet line (o_y+8).
- STATUS: blocks/coins/mushroom/coin-pop/big-Mario/HUD all build + run, but the user says it
  "needs more work" — to revisit later. Known gaps / polish TODO:
  * Mushroom emerge/slide feel + size/offset tuning; no wall collision; optional $83/$80 shimmer.
  * Coin-pop visual polish (it's a single BG $5F tile up/down).
  * $2a/$2c/$c0 block contents (star / superball / multi-coin) are stubbed as mushroom.
  * Other items / object types, and enemies, still to do (enemies remain LAST per the user).
  * Time-up death, damage-shrink, game-over at 0 lives, 1-up heart — all TODO.
