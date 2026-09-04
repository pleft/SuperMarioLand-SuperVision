# THE PORT LAWS — read this BEFORE starting any new world or level

Every law here was paid for with a user-caught bug, most of them TWICE. If a
new world is being started, walk this list first and check the new code
against it. Adding a law is cheap; re-discovering one costs a playtest round.

## A. Drawing and erasing

**A1. The visual-8 anchor.** An object's `o_y` is its visual y MINUS 8. The
engine's erase anchors at `o_y + 8` (`o_ndy`). Any kit draw must use `o_y + 8`
as its base or the sprite sits 8px above its own erase box and smears.
*(Cost: 2-3's torpedo trails; W3's Batadon smear.)*

**A2. The erase box must cover the WHOLE metasprite.** Check every param's
extent (min/max dx, dy) against the box the kit returns from `ovl_width`, not
just the one sprite you happened to look at. Metasprites reach LEFT of the
anchor (`-8`) and can be 24 or 32px tall.
The engine's width byte: bit7 = +1 row, bit6 = +1 row, bit5 = +2 rows,
low 5 bits = 8px columns; the erase starts at `o_pvy - 8`.
`ovl_width` is called AFTER the pipeline stores `o_pvx`/`o_pvy`, so that hook
is where a bigger box gets its corrected origin.
*(Cost: W3 Hiyoihoi + the stomped-$25 chain smearing the background.)*

**A3. A 16px sprite at an arbitrary y straddles THREE tile rows.** Erase rows
= ceil(height/8) + 1. Two rows for a 16px sprite leaves a sliver whenever the
y is not tile-aligned.

**A4. Screenshots must be RING-aware.** The framebuffer is a 48x170-byte ring;
the visible window starts at (`ring_y`, `ring_xb`) + scroll. A dump from byte 0
shows a shifted screen and has twice sent me chasing phantom bugs.

## B. Contact and kills

**B1. Vehicle levels have NO stomping.** In 2-3 (and any future vehicle
level) contact ALWAYS hurts, whatever the vertical relation, AND the lethal
hit must despawn the hull (`sub_off`) or Mario's corpse plays beside a
submarine that is still on screen. The walker rule lives in `w2_foe` (the
shared W2 resolver) as well as `l3_hurt` -- gate BOTH. *(Cost: the sub
"stomping" a skeleton fish from above, and the hull surviving the death.)*

**B2. `l3_above` returns C=0 when Mario is on the STOMP side** (4+px above).
Branch on `bcs` to hurt, `bcc` to stomp. Getting it backwards stomps enemies
from the side and makes Mario fall through heads he should bounce off.

**B3. The GB contact table is at $3186 with a FIVE-byte stride.** Column +0 is
the stomp result (reached from the stomp test at $08C7); `$00` there means
"not stompable". A 4-byte stride reads a neighbouring type's row and looks
plausible -- verify the stride before trusting a row.

**B4. Kill chains are types.** A stomp/ball result is another enemy type with
its own script; port it by morphing, never by hand-animating the corpse.

## C. Registers, state and the shared kit

**C1. The shared helpers clobber X.** After `l3_cull`, `l3_box`, `l3_above`,
`mario_dx`, `hurt_mario` and friends, reload the slot with `ldx oi` before
touching any `o_*,x`. *(Cost: a W3 enemy turning into a score popup.)*

**C2. `x_step` branches on the caller's A flags** -- keep them intact (`ora #0`
before the call if anything intervened).

**C3. Never store kit state in `o_pdr`/`o_pvx`/`o_pvy`/`o_pfr`** -- the engine
owns them. Kit-owned per-slot bytes: `o_st`, `o_tmr`, `o_hp`, `o_vx`, `o_vy`.

## D. Banks, RAM and the LCD

**D1. EVERY write to SYS_CTRL restarts the LCD scan.** Doing it once per frame
already produced unplayable banding (sml17). So: **no bank switching during
play** -- not per tile read, not per sprite draw. Data a level touches every
frame must be RESIDENT in the bank that is mapped while it runs. If it cannot
be, the switches must be batched to a single bracketed window per frame, and
even that is a compromise the user can see.
*(Cost: W3's HUD instability -- 22.5/frame, then 9/frame after a partial fix
because the DRAW path also switched, then 5.8, now **2.95/frame**. See D1b.)*

**D1b. W3's switches are a CACHE-POLICY problem first, a layout problem
second.** Measured in 3-1 (count PC hits on every `STA/STZ $2026` site):

```
                       before   after   what it is
map column cache        3.03    0.14    w3_read misses
w3_draw (per enemy)     1.84    1.84    display lists + tile sheet, bank 6
w3_fetch (per byte)     0.96    0.96    AI script bytes, bank 6
                        -----   -----
                         5.83    2.95   per frame (worst frame 22 -> 18)
```

The cache was 7 slots with ROUND-ROBIN replacement, which evicts the column
you are about to re-read: 1.5 misses/frame against a working set of only 5.7
distinct columns. **Direct-mapped over 16 slots is the compulsory floor**
(0.13/frame -- a column only misses when the camera first scrolls it in). Its
256 bytes of tile data live in `shtab_lo`'s page 0, which is the identity
shift and therefore dead once the blitter computes that case instead of
looking it up; being page-aligned makes a slot's address `(slot << 4)` with a
constant high byte. Verified: 3-1 and 3-2 render BIT-IDENTICALLY before and
after (gold hashes only cover levels 0-5, so W3 needs its own comparison).

The REMAINING 2.8/frame scales with the enemy count and needs residency, not
caching: the display lists (490B) and the enemy tile sheet (896B) that
`w3_draw` reads, plus the AI scripts (811B) `w3_fetch` reads a byte at a time.
Bank 1 -- the bank mapped while 3-X runs -- has 451 bytes free, so that is a
ROM-layout change (shrink the 8833-byte shared prefix), exactly as D1 says.

**D2. Measure the switch rate in REAL play** (enemies on screen, no camera
teleport) before claiming a switching fix works. A quiet test frame proves
nothing.

**D3. The RAM map is full.** ZP full; BSS ends at $11FC with RCODE at $1200;
$1500-$1CFF is the kit window; $1D00-$1F7F the HUD shadow; $1F80-$1F9F holds
the W3 cache TAGS (its 256 bytes of column data live in shtab_lo's dead page 0
at $0200 -- see D1b; shtab_hi's page 0 at $0600 is free for the same reason). BOOT6 ($1500 image, 2048) has ~1.8K spare for ONE-SHOT boot
code -- that is the place for boot-time initialisation when FIXED is full.

**D4. Anything the TITLE draws must be initialised before the title runs.**
The title precedes `load_level`, so header-derived state (e.g. the bg charset
pointer `bgc`) is still zero there. *(Cost: garbled level-select digits.)*

## E. Verification discipline

**E1. Gold VRAM hashes** (`/tmp/goldcmp.py`): every existing level must stay
BIT-IDENTICAL across any engine/layout change. This is the cheapest and most
valuable gate in the project -- run it after every structural change.

**E2. Per-type GB tick diffs** for scripted enemies: force both sides to the
same script offset and compare (pc, velocity, param, dy, |dx|). A gate that
can pass on zero samples is not a gate -- require a minimum event count.

**E3. The sim cannot see**: the LCD scan (so bank-switch damage is invisible),
NMI-timing effects (the harness has no NMI), or hardware DMA timing. Anything
in those classes needs a hardware playtest -- say so instead of implying the
sim covered it.

**E4. Camera drift poisons GB captures.** Let the camera settle (200+ frames
after releasing input) before treating screen-relative deltas as object
motion, and convert to WORLD coordinates ($C0AB/$C0AC are 16px columns).

**E5. When a measurement disagrees with the port, suspect the instrument
first** -- twice the "bug" was my sampling box or my reference capture.

**E6. Sim state pickles embed the WHOLE 64K -- the fixed bank included.** A
saved state restores $C000-$FFFF as well as the $1500 kit window, and the
harness only re-maps $8000-$BFFF from the new ROM. So after ANY rebuild --
kit, engine, blitter, anything -- the pickle must be regenerated
(`mkstate23.py`) or the test silently runs the OLD code. This has burned twice:
once "proving" a fixed bug was still there, once reporting three optimisations
in a row as having changed nothing (the numbers were byte-identical, which was
the tell).

**E9. The sim runs NO NMI and NO IRQ, so anything those handlers apply does not
reach the hardware registers.** The playfield scroll is written by the
raster-split IRQ (`vxp`/`vyp` -> `XSCROLL`/`YSCROLL`) and the HUD's by the NMI
(`vxph_ap`/`vyp_ap`). Rendering a sim frame from `$2002`/`$2003` therefore shows
an UNSCROLLED view -- which looks exactly like the game failing to scroll, and
sent me measuring a non-existent autoscroll bug. Render from the engine's
shadow variables instead. Same class as E6: the instrument, not the port.

**E10. Cross-correlate against STATIC scenery, not the whole frame.** Measuring
the GB's scroll rate over the full playfield gave 0.3 px/frame because moving
objects biased the match; the seabed band alone gave a clean 0.500 with ~0%
residual, matching the port exactly.

**E8. A sprite is invisible while it is erased, and the beam does not wait.**
Frame cost above ~38% of the budget (the vblank fraction) means the renderer is
drawing while the beam is over the playfield. Any sprite whose erase and draw
straddle the beam is simply MISSING that frame. Measure the erase->draw gap
(`/tmp/gap23.py`) and the beam-caught count (`/tmp/beam23.py`) -- do not
measure only frame cost, which does not distinguish "slow" from "flickering".
See docs/36.

**E7. Enemy timings must be measured from SPAWN, in world coordinates, with
the object's own cull in mind.** 2-3's school fish had a 144-frame left leg
against the GB's 112: the extra 32 frames pushed it past the cull margin, so
it was FREED before its turn and looked like a plain right-to-left swim.

## F. GB capture recipes

- **Warp to a level**: poke `$ffe4 = target-1` AND `$ffb4` = the predecessor's
  BCD stage (State_08 increments both), then `$ffb3 = $08`.
  2-3 -> (4, $22); 3-1 -> (5, $23); 3-2 -> (6, $31); 3-3 -> (7, $32).
- **Reach an ending without fighting the boss**: glide `$C0AB` to the arena,
  then enter the clear state directly (`$ffa6 = $F0`, `$ffb3 = $07`).
- **Autoplay assist**: `$C0D3 = $F8` (star), `$DA15 = 5` (lives), and lift
  Mario when `$C201 > 0x96` so pits do not end the run.

**E11. Verify on the REAL core, driving the game's own level select.** The py65
harness cannot see the NMI, the raster IRQ or the LCD (E3/E9), and the old gold
gate lived in `/tmp` and evaporated. `tools/svshot.c` runs the real Potator core
(N taps of SELECT = level N, then START), dumps sampled framebuffers AND 8K of
RAM per sample, and takes an input script (`"R150,U80,D120"`) so the port and a
PyBoy GB run can be driven by the SAME input and compared frame for frame.
`tools/svgold.sh` is the gold gate rebuilt on top of it -- levels 0-8, hashed.
This is what finally reproduced "mario dies unexpectedly" and "the sub
disappears" without a playtest.

**E12. Compare the DRAWN sprite, not the state variable.** Every coordinate
claim in this project that turned out wrong came from trusting a variable's
name. The GB's OAM ($FE00, y-16/x-8) is hardware truth for where a sprite IS;
the port's equivalent is the object's `o_x - cam_x` and `o_y + 8`. Cut a
template out of one side's frame and search for it in the other's -- an
exact-zero match proves the art is identical and pins the offset. That is how
the Marine Pop's 2px and the school fish's 16px were measured.

## G. The frame: GB coordinates -> port coordinates

Established for 2-3 by OAM measurement (2026-08-20) and true wherever a kit
transcribes GB constants. **Get this right BEFORE porting a level's player.**

```
GB $c202 = hull/sprite LEFT  + 15        port spr_x = sprite LEFT  + 7 (kit) 
GB $c201 = hull/sprite TOP   + 22        port spr_y = sprite TOP       (engine)
```

- **A probe offset does NOT carry across unchanged.** The GB writes `$ffad =
  c201 + d` and reads the tile row `($ffad - 16) >> 3`, so the screen y it tests
  is `spr_y + d + 6`. The port's `vrowset` tests the row containing the y it is
  given. Passing `spr_y + d` reads ONE TILE ROW HIGH -- 2-3 shipped that way in
  all three probes (h/up/down).
- **Clamp constants must be converted through the same frame**, then checked in
  pixels: hold each direction for 260 frames on the GB and read OAM. 2-3's true
  box is hull left [-1, 145], hull top [25, 126]. The kit had [1,145] x [34,134]
  -- the sub could sink 6px into the seabed and could not reach the ceiling.
- **A "clamp" in the GB source may not be the reachable limit.** 2-3's left step
  decrements twice while the autoscroll runs and only the FIRST dec is guarded
  ($5008 vs $5012), so the reachable minimum is 2 below the stated $10.

**E13. PyBoy hooks fire only at CALL/JUMP TARGETS, not on every PC match.**
Proved by probing every instruction of one routine: `$09f1` (a call target)
fired 9 times while `$09f4`, `$09f5`, `$09f6`, `$09f8`, `$09fa`, `$0a04`,
`$0a09` and `$0a0f` -- all inside it, with no branch between them -- fired ZERO.
The same effect earlier made `$515e` fire and `$5161` not, which I wrote off as
noise.

Consequences, both of which bit in this session:
- You CANNOT trace control flow inside a routine with hooks. "I hooked the
  branch targets and the damage path runs" is not evidence; only the entry is.
- A hook CAN read registers (`pyboy.register_file.HL`) and memory at the moment
  it fires, which is how the enemy slot behind a collision was finally
  identified ($d113 = slot 1's x byte).

For anything mid-routine use a real debugger with watchpoints (mGBA/SameBoy --
see [[re-dynamic-trace-lesson]]), or hook the entry and re-derive the rest from
memory state.

**E14. A sprite's TILES must be read from OAM, and OAM must be printed WHOLE.**
Every sprite in 2-3's boss arena was drawn with tiles the port had guessed
(docs/40): the dragon's shot was three rows of his own torso, tamao was two
halves of two different tiles, and the dragon had only one of his two frames.
The single capture that fixed all of it printed y, x, TILE and ATTR for all 40
OAM slots -- and the attrs (`04/22/40/62` on one 16x16) are what proved tamao is
one tile flipped four ways rather than four tiles. An earlier partial dump in
the same session, printing only what I came for, read every id one off and I
believed it. Print every field.

**E15. VRAM is not the sheet you extracted.** The arena's `$E2/$E3` are a
striped BG pattern in the common OBJ sheet -- the port drew exactly those
stripes. The real ball lives in a SECOND 256-tile OBJ sheet (bank 2 file
`0x8032`, one bank above the common `0x4032`). Before sourcing a tile, dump the
GB's live VRAM at the moment it is on screen and byte-search the ROM for it: the
match is unique, and it names the bank and offset for the extractor. Never
assume the sheet you already have covers a new scene.

**E16. Check what the shared draw helper does to your tile id.** `draw_16q`
silently adds `foe_frame*4` (a 16-frame wing flap). Passing it a base whose
animation is driven some other way lands 4 tiles further on -- for tamao, inside
the dragon. If a sprite's cadence is not the helper's cadence, take the helper's
no-animation entry point.


**E17. Every bank switch must use `set_bank`'s encoding: a PLAIN bank number.**
Under MAGNUM `$2021` bits 3:0 are the page and the page number IS the bank
number (docs/37). One inlined copy still wrote the pre-MAGNUM SYS_CTRL layout,
`(bank << 5) | sysflags`, so its bits 3:0 carried the FLAGS and it mapped page
11 -- which does not exist in a 256K image. The reads came back `$FF`, and the
2-3 rescue's fake Daisy rendered as a solid black square for months. When a
banking scheme changes, grep every writer of the register, not just the routine
you renamed: `sta LINK_DDR` had three callers and one was stale.

**E18. A sprite's DRAW origin and the engine's erase origin are two different
conventions -- check which one the draw helper actually honours.** The engine's
law is "visual top = `o_y` + 8" (`o_ndy`), and `draw_dshot` adds the 8 by hand.
`draw_subv` does not: its quad table is `0,0,8,8`, so its `o_y` IS the drawn top.
The sub's `o_y` was being set as if the law applied, and the hull floated a tile
above where the GB draws it -- for long enough that a correct torpedo height
looked like the bug. To settle where a sprite is really drawn, match its own ROM
tiles against the framebuffer (diff 0 at a known offset); ink-row extents are not
frame-stable and will mislead by a few px.

**E19. A time-integrating accumulator must know every state that FREEZES the
thing it drives.** 2-3's autoscroll banks elapsed frames so the camera keeps the
GB's exact 0.5 px/frame across an irregular game loop. `mario_grow` freezes the
action for 80 frames and the GB scrolls none of them -- so the accumulator
banked all 80 and spent them the instant the sub finished growing: a 41px camera
jump in one frame, with the background 5 tiles behind the collision map. Clamp
the elapsed delta (2 = a dropped frame still compensates, a freeze cannot bank),
and never let the accumulator apply its surplus by writing the driven variable
DIRECTLY -- the caller's step is usually a protocol (here: cam_x, the spr_x
give-back, and the background column fed off that move), and bypassing it moves
the map without drawing the picture. No scripted run in a whole session of
captures ever grew, shrank, or paused; only a human picking up a mushroom found
it. When you add an accumulator, enumerate the freezes.


**E20. Anything that CLIPS on one side must clip on the other.** `restore_bg`
refuses to blit past tile col 24 (the 48-byte framebuffer row); `draw_player`
had no such check and folded mod 48 back into view. A sprite parked off-row --
2-3's crush death sits at x 240, the GB's wrapped `c202 >= $ED` -- therefore drew
every frame at x 48 with no erase behind it, painting a solid column up the
screen. Erase and draw must agree on the clip, or the difference IS the bug.

**E21. Two build flavours must share no artifacts.** `GODMODE=1` only changes
`ASFLAGS`, invisible to the `.o` rules, so incremental builds mixed objects, and
a `godmode` target writing the shared ROM name left godmode content in the
normal file. Give each flavour its own object dir and its own output name
(`build/god/`, `-god.sv`); then both stay incremental and neither can be the
other. And verify a test build BEHAVIOURALLY on a path that the flag actually
changes -- 1-1's hold-right death is a PIT, which never calls `hurt_mario`, so it
"passes" identically on both.

**E22. Every object updater must retire its slot when the camera leaves it
behind -- an object with no way to die eats the table, and the table fails
SILENTLY.** The walkers had the rule (`o_x + 20 < cam_x`); the RIDEABLES did
not: `upd_stone`, `upd_platv` and `upd_plath` freed a slot only by falling off
the bottom of the screen, so 3-1's six $36 stepping stones and both $0A lifts
stayed live for the rest of the level. `find_free_obj` then returned "table
full" and `spawn_check` DROPPED the spawn without a sound -- the moving platform
the player is supposed to ride simply never appears, which reads to the player
exactly like "I fall through the platform". GB-measured (PyBoy capture of the
$D100 slots, 3-1): the six stones are freed one by one as each one's screen x
goes negative -- slot 2 at cam 384, 3+4 at 416, 5 at 432, 6+7 at 464. Audit for
this by listing every `.proc upd_*` and grepping each body for a cull; anything
without one must justify how else it dies (a timer, an arc that leaves the
screen, a contact). And when a spawn can fail, say so at the call site: a
silent `bcs @full` is how a whole level section goes missing.

**E23. Compare the two engines CLOSED-LOOP, not by replaying one's input on the
other.** Feeding the GB's recorded script to the port drifts: ten pixels of
phase and a scripted jump lands on the wrong side of an obstacle, after which
every frame differs and the report is noise (measured on 3-1: the port stalled
against the $70-$73 block at world x 242 purely because it arrived 13px late).
Run the SAME search on both sides instead -- `tools/gbauto.py` on the GB,
`tools/svauto.c` on the real Potator core, both greedy over save states with a
two-horizon score -- and compare how far each gets. A place the GB's search
sails through and the port's cannot is a port bug, with its world x printed;
anywhere both stall is a limit of the search, not of the port.

**E24. `o_y` is a BYTE: every object needs a VERTICAL cull, and its window must
be derived from the port's y ORIGIN, not guessed.** W3 shipped with no vertical
cull at all, so a stomped corpse fell past the bottom, wrapped through 255 and
rained down the screen again and again (user-reported on 3-1's first enemy and
on a stomped missile; captured as `o_y` 0->255 then 255->0). 2-3 had had the
guard since its own anomaly sweep -- gated `.ifdef MAR23`, so the next world
inherited nothing. Two numbers, both measured, not chosen: the port's floor is
168 because the GB frees its $3D corpse at GB y 192 and `port o_y = GB y - 24`;
the ceiling is 232 because 3-1's high-ledge Batadon legitimately peaks at GB y
18 = port -6 = 250 and comes back down, so 232..255 is a NEGATIVE y and must be
kept alive. Cull the band between them and nothing else. When a guard is added
for one world, ask immediately which builds it is compiled out of.

**E25. Read the GB's own tables for CLASS flags before hand-listing the members.**
"Mario can stand on it" is bit 7 of PhysicsParamTable byte 1, with the collision
box in the same byte (hi nibble - 8 = width/8, lo nibble = height/8). The port
instead hard-coded the four rideables it happened to know (`OBJ_PLATV/PLATH/
STONE/GIFT`), so every World-3 member of that class -- the rising pipe cannon,
the moai ledges -- was solid on the GB and thin air here, and the level's big
pit (lift -> ledge -> lift) became uncrossable. When a behaviour applies to "some
types", find the BIT that decides it; a hand-written list is a bug with a delay
fuse. The same table's bits also told us the box dimensions we would otherwise
have measured sprite by sprite.

**E26. A "defensive default" is an invented behavior.** The port's block
dispatch defaulted unlisted ?-blocks to "a coin" because it seemed harmless;
the GB's own dispatch says an unlisted $80 IS a brick (jp $19E1) while an
unlisted $81 pays the coin. The default was wrong for exactly one tile id and
survived three worlds because W1's unlisted blocks all happen to be $81. When
the reference has a dispatch, port the dispatch -- including its fall-through
-- and never paper over an unknown case with something plausible: write the
unknown case to fail loudly or measure it.

**E27. A helper that reads globals must have them LOADED at every call site.**
`restore_bg` reads `rb_vx/rb_y/rb_cols/rb_rows`; render_all loads them before
calling, `pipe_animate` did not, and the pipe descent erased a stale rectangle
every frame -- Mario stacked copies of himself up the pipe. When extracting a
helper, either pass its inputs explicitly or grep every caller for the load.

**E28. A register-passed argument dies at the first `jsr` -- audit the call
chain the day you write it.** `w3_behind` keys on X = the tile id;
`draw_quad` called `set_dst` first, and set_dst's `ldx dy` replaced the tile
with the row number. The priority gate therefore armed at random from the day
it shipped, the cannon's hide-in-pipe worked only by coincidence of row
values, and THREE verification passes sampled lucky frames and called it
fixed. When a helper reads a register argument, read the code between the
argument's producer and the consumer -- every jsr in between is a suspect --
or pass through a zero-page byte. And when a fix "holds at the spots you
checked" but the user keeps seeing the bug, suspect the mechanism is
nondeterministic-by-accident, not that the user is wrong.

**E29. Code reachable while a data bank is mapped must live in FIXED.**
`w3_draw` maps BANK 6 (display lists + the W3 tile slice) around its whole
walk, so everything `draw_quad` can reach during it -- every jsr, transitively
-- must live in $C000+ (FIXED) or the always-mapped RAM window. `flip_to_buf`
was placed next to its corpse-draw sibling in the banked common prefix; the
first time a bit5 (Y-flip) control byte armed it, the jsr landed in TILE DATA
at $98E9 and executed it, and the Ganchan froze mid-hop with its whole slot
"pinned" by a blit spraying deterministic garbage. The freeze looked like a VM
bug for three bisections. Before adding a call inside w3_draw's window, check
the target's address in rom.lbl: $8000-$BFFF means it is data during the draw.
(The inverse trade paid for it: `carry_x1_rt` is only ever called under the
normal mapping, so it moved OUT of FIXED to the common prefix.)

**E30. The two 3-1 boulder enemies are not one enemy; name them by their GB
types.** $31 = TOKOTOKO, the six placed ground rollers: phys1 $22 (bit7
CLEAR, not standable), landing on one is a STOMP -> morph $40, +400, crack,
crumble to $0D. $47 = GANCHAN, spawned forever by the six $03 sky spawners
(cols 155-215, y 56): phys1 $A2 (bit7 SET, standable), unkillable, side
contact $FF, and it CARRIES its rider -- Mario's x moves with the object's
every step (w3_carry_rt/lf; "You can ride these boulders over spike pits",
the Player's Guide). Its 2nd animation param $47 is the SAME four tiles
rotated 180 deg via display-list control bit5 = Y-flip. A session's worth of
measurements filed under the wrong names survived the swap only because every
number was tagged with its TYPE ID; keep tagging measurements with type ids,
never nicknames.

**E31. Validate a perceptual win in a scenario the player actually plays.**
The composite renderer's metric -- object-frames blank while Mario is parked
in the sky -- showed a 40x improvement; the player, whose Mario is always
NEAR the enemies being watched (exactly the objects the eligibility rules
exclude), saw nothing, and the churn cost him ~10% logic rate on top. The
instrument was honest, the scenario was not. Before shipping anything whose
value is "the user will see it": measure with Mario played into the scene by
input, near the action, on the NORMAL build -- and A/B against the previous
build with forced-clean rebuilds (make silently reuses stale objects across
git checkouts; the first A/B compared a ROM against itself).

**E32. A probe cache must be keyed to the state the probe was MADE in --
never re-key it from the code path that moves the object.** `w3_ffc7`'s
floor-probe cache is (feet_col, o_y) -> verdict. The `@fall` path, meaning to
help, re-keyed `w3_fcy` to the NEW y after moving 1px down; next frame `o_y ==
w3_fcy` matched, the cache hit with the stale "open" verdict, and the probe
never ran again. Every W3 object that left the ground therefore fell through
solid floor until the y>=168 cull freed its slot -- 4-1's Pionpi, stomped
mid-hop, "died after some stomps" (user report). A grounded object never
showed it: its first probe says solid and it never enters `@fall`. The cache
is correct with the re-key REMOVED: `@probe` already stores the y it tested,
so the changed `o_y` is exactly what forces the next re-probe.
Symptom to recognise: same column, same y, different verdict on different
frames -- the object's own history, not the map data, decided it.

**E33. Two arrays at one address is not a coincidence you can outrun.**
`w3_hp` (Superball hit counter) and `w3_fcv` (floor verdict) were both
declared at `$0128`, 10 bytes each. The gravity probe rewrote the hit counter
every frame for any knocked-down object; a Pionpi bumped its own kill count
once per knockdown. Grep every new `= $` RAM declaration against `rom.map`
before adding it (see the ram-layout-traps memory).

## E34: any FIXED code-size change is an E23 engine-speed change for World 4

The w3_ballt relocation removed 16 bytes from FIXED. svgold stayed 9/9
byte-identical (levels 0-8 have frame-budget slack), battery31 passed -- and
4-1's completing route died at x807. Cause: page-cross cycle penalties moved,
and 4-1's render walk runs close enough to the frame budget that the NMI race
resolves differently: at f1622 the pipe piranha's o_tmr is one tick apart
between builds and every W4 object phase drifts from there.

Rules this adds:
- E23's "engine-speed change" includes PURE CODE MOTION: adding, removing, or
  moving bytes anywhere in FIXED (or the W4 kit) invalidates W4 routes, even
  when no instruction semantics changed.
- Consequence: record a level's route only on the FINAL build of its kit.
  4-2/4-3's roster extension will re-phase 4-1 -- expect to re-run the chain.
- Diff discipline: to compare two builds' runs, diff BEHAVIORAL state
  (o_type/o_xl/o_xh/o_y, Mario, cam), never the raw 8K -- the kit window copy
  and the zp render temps legitimately hold shifted code addresses.

## E35: one generated file, two producers = build-order roulette

build/w3ball.inc was written by BOTH gen_w3data.py runs (world 3, then world
4) and assembled once into FIXED, indexed by w3_ti -- a PER-WORLD index. The
shipping ROM held World 4's rows, so World-3 Superballs passed through their
real targets (indices 6/7/8/15) and hit wrong ones. No gate caught it: svgold's
R900 never fires a ball, battery31 had no Superball test. Fix: per-world
tables at one pin ($B520) in each world's own resident bank; the mapped bank
selects the table, w3_ball itself is unchanged, and the packers byte-assert
the paste. When a generator runs once per world, EVERY file it writes must be
world-suffixed -- grep for unsuffixed open() calls in any new generator.

## E36: a FIXED routine that maps a non-prefix page must not call prefix code

set_bank is in the LEVELS prefix. cold_copy (FIXED) called it to map the cold
page: the rts returned into cold data (the prefix is not mapped there) and 3-1
froze at its first respawn. Anything that runs under bank 6 / page 10 must be
FIXED- or RAM-resident and must do the $2020/$2021/$2026 dance inline, as the
kit's w3_bank does.

## E37: "free RAM" at $1F80-$1FEF is only free AFTER the kit stub has run

The W3/W4 stub relocates its loader to $1F80 and executes it there; its image
reaches ~$1FE9 (and grows with every stub edit). himod ($1FA0), the composer's
CX_*/CS_B and any new variable placed there are clobbered at every kit level
load and must be (re)initialised by the kit init, which runs after the loader.
Never store INTO that range from the stub itself (self-modifying its own tail).
A grep of rom.map does not show any of this: the kit's RAM equates live in
kit_w3.inc / w3aux.s -- grep those too (E33 amendment).

### E38. A kit's blob-local state must live in RAM it can write
2-3's vehicle kept `vfire/vacc/...` as `.byte` lines in its $1500 window
(RAM). Copied into 4-3's SKYFAR segment -- ROM in page 11 -- the same lines
assembled fine and were constants: the autoscroll accumulator never moved.
Any `.byte`/`.res` state in a far segment is a bug; use kit-RAM equates.

### E39. The RAM map is the equate list, not a comment's opinion
w3_hp was homed twice on "clear" bytes that were not: $0128 (w3_fcv) and
$0132 (do_yflip/mus_seen); himod was homed on CS_B. Before homing ANY
variable, grep every equate (`= *\$01..`, `= *\$1[C-F]..`) in src/*.s and
src/*.inc and w3aux.s. The map as of 2026-09-04:
  stack page: $0100 w3_ph0, $010A w3_ph1, $0114 w3_fcc, $011E w3_fcy,
    $0128 w3_fcv, $0132 do_yflip, $0133 mus_seen, $0136-$0153 CXS_*,
    $0160-$016D AX_*, ... $01C6-$01CF CXA_*; the stack itself seen to $01DF.
  window: $1500-$1BFF kit code (W2WIN capped), $1C00-$1C3F himod,
    $1C70-$1CFB CS_A, $1D00-$1F7F HUDSHADOW, $1F80-$1F9F W3CTAG,
    $1FA0-$1FDB CS_B, $1FE0-3 CX_*, $1FE7-$1FEB 4-3 vehicle state,
    $1FF0-2 spawn window, $1FF3 quad_top, $1FF4-$1FFD w3_hp, $1FFF W3CMB.
  (E37 still holds: $1F80-~$1FE9 is the loader during a level LOAD.)

### E40. Superball vs a VM foe uses the GB's box, at the W3BOX pin
ball_hits' generic |dx|<10,|dy|<10 is not the GB's ball test (docs/12,
docs/38 s12). For type 36 in worlds >= 3, FIXED calls `w3_ballbox` at $B000
(first in every EAS3 kit's W3TAB paste; the kit asserts the address). A kit
that puts anything before it in W3TAB breaks every Superball kill.

### E41. OBJ-behind-BG priority is per pixel, never per cell
The GB hides a priority sprite only under non-zero background PIXELS. Any
port rule that decides per quad/cell ("skip the quad if a sample is non-white")
will delete the sprite under decorations (4-1's poles behind every pipe plant).
The blit's `bmerge` is the only correct place; `w3_behind` just sets the flag.
