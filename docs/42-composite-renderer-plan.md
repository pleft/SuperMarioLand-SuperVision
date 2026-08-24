# 42 — the composite renderer (task #24): why, where the room is, and the plan

## Why (the user's remaining complaint)

With #30 at GB parity, the residual flicker in busy areas is the NMI landing
mid-render on the ~14% of worst-zone frames that still overrun the 65,574-cycle
budget: the loop is still in the PREVIOUS frame's logic when the NMI fires, so
the next render runs while the beam crosses the playfield, and any sprite is
ABSENT between its erase and its draw. Singles keep that window small
(erase+draw adjacent); the ENTANGLED group (overlapping enemies — the normal
case in a busy zone) erases the whole group before drawing any of it. 2-3's
parked flicker (#24's original body) is the same mechanism.

The cure: compose erase+draw per CELL — rebuild the background tile in a RAM
buffer, blit the sprite pixels over it, write the finished 16 bytes to VRAM
once. A sprite is then never absent from VRAM; a mid-region NMI shows a
half-moved sprite instead of a hole. Also cheaper: the old-image overlap is
written once instead of erase-write + read-modify-write draw.

## Where the room is (all current pools are full)

Measured 2026-08-23: FIXED ±2B, LEVELS prefix ~2B against the level-5-header
pin ($A600), kit window $7EE/$800, W3 far kit 419/431. The compose engine
(~500B+ code, prefix copy, tile slices) fits NONE of them.

**The MAGNUM map (Potator memorymap.c:164):**

    bankOffset = ((SYS_CTRL & $20) << 9) | (($2021 & $0F) << 15)

- $2021 selects a **32K page** (4 bits → 16 pages → 512K addressable).
- SYS_CTRL bit5 selects the 16K HALF of the page.
- Our 256K image uses pages 0-7, and ONLY THE LOWER half of each: the odd
  16K slots — 128K, half the cart — are $FF. Byte-verified slot survey:
  used = 0,2,4,6,8,10,12,14 (+15 = FIXED); free = every odd slot.

**Why the free 128K is NOT directly usable:** the odd halves need SYS_CTRL
bit5 — and EVERY SYS_CTRL write restarts the LCD scan (that is the raster-pin
trick, main.s:11456). Flipping it mid-frame as a bank switch would tear the
whole screen. Dead end.

**The usable room: grow to 512K.** $2021 is 4 bits; pages 8-15 are virgin, and
their LOWER halves map with a plain $2021 write — the exact mechanism w3_draw
already uses every frame (W3LINK). The cfg comment anticipated this ("going
past bank 7 means either a 512K image ...").

## The plan (increments, each gated by battery + svgold + the stray sweep)

1. **512K growth (mechanical).** pack_banks NPAGES 8→16, image 524288B;
   nothing moves. Gates must stay byte-identical (svgold reads pixels only).
   ⚠ REAL-HW GATE: the SuperPico firmware may hardcode 256K (UF2 size-verify
   law) — the user must confirm/flash before a 512K image ships as default.
   Until then the 512K build is a parallel artifact.
2. **The AUX page** (page 8, $2021=$08): pack lays it out as
   [common-prefix copy (bg sheets + engine-callable helpers at their normal
   addresses)] [the W3 overlay tile slice at its $B740 address] [AUXCODE].
   Everything the compose blitter reads is then intra-bank; the raw MAP is
   not, so cell tile-ids are gathered in phase A under the normal mapping
   (~12 bytes per sprite region).
3. **Compose path, W3 metasprites first** (worst flicker): phase A gathers
   map tile ids + dst pointers; phase B maps page 8, composes each cell
   (bg tile → buffer, sprite tiles masked over it via the shtab machinery
   retargeted at the buffer, 16B written to VRAM once), maps back. The old
   erase+draw stays for everything else until proven.
4. Extend to the entangled group + Mario; retire pass-3 erases for composed
   sprites; re-run the whole gate suite per step.

## Cheap parallel lever (independent of the arc)

restore_bg addressing: set_dst + mod_ptr + map addressing run PER CELL
(~8k/busy frame profiled). A mod-region gate (does the modified-block list
intersect this erase rect at all? usually no) + column-wise map pointer
stepping + dst stride bumps would cut ~2-3k from every busy frame — fewer
overruns, less flicker, no architecture change. Space for it must come from
the same 512K/aux room, or from further FIXED evictions.

## Hardware verification items

- SuperPico: 512K UF2 acceptance + $2021 values 8-15 honored.
- SYS_CTRL bit5 must NEVER be used for banking (LCD restart) — law-adjacent;
  add to docs/35 when the aux page ships.

## DESIGN PIVOT (2026-08-23, before implementation): SAVE-UNDER, not map-compose

Map-based composition dies on a mapping conflict: the compose phase needs the
LEVEL bank (map reads) and the aux page at once. The classic save-under
renderer needs NO map at all:

- Each composed object owns a CONTEXT: the pristine background bytes of every
  cell its sprite covers, saved from VRAM at the moment the sprite first
  covers the cell (correct by induction: the previous compose left pure bg
  everywhere else).
- Per frame: vacated cells get their saved bytes written back; new cells are
  saved; still-covered cells are rebuilt in a 16-byte buffer (saved bg +
  sprite tiles shifted via shtab/MASKTAB) and written once. Pure writes and
  buffered composes -- the sprite is NEVER absent from VRAM. Flicker-immune.
- Contexts live in the unused video RAM tail $5E00-$5FFF (fb ends $5DFF):
  3 contexts x ~170B (10 cells x 16B + meta). Objects beyond 3 fall back.
- The OLD bookkeeping (o_pdr/o_pvx/o_pw) is maintained for composed objects
  every frame, so ANY exit from composed mode -- entanglement, death,
  ineligibility, context shortage, stale bg -- falls back to the old
  erase+draw path, whose restore_bg is map-correct unconditionally.
- Staleness needs NO hooks: the DMA shift moves sprite pixels and bg
  together (contexts store ring positions; pass-0 folding applies); stream
  repaints only threaten the right margin, so eligibility simply excludes
  objects within 40px of the right edge; bonk effects spawn objects (bounce,
  shards, popups) whose overlap entangles the enemy and forces the fallback.
- Eligibility (checked in bank-6/kit code, zero FIXED bytes): single-quad
  $84-class params, no behind-armed tiles, not entangled, clear of the right
  margin, context available.
- Code homes: phase A (display-list walk stores tile pixels + offsets to RAM)
  in a BANK-6 pin (1KB free there, mapped during the walk); phase B (the
  composer) in the AUX page; kit window only pays the dispatch seams.

## HANDOFF (checkpoint, session end 2026-08-23)

DONE + committed (4e01196): 512K default image; page-8 aux proven on the real
core; the walk relocated to the W3X bank-6 pin ($BC00, window down to $6EB);
the save-under composer (aux_compose/aux_uncompose) passes bit-exact py65
unit tests (tools/test_aux.py: fresh / still+1px / moved-a-cell / uncompose).
Battery 10/10, svgold 9/9 identical throughout. NOT wired in-game yet.

NEXT (half 2 -- the stash + dispatch), with the decisions already made:
- w6_elig (W3X): eligibility (not entangled; CX_OWN free/ours -- steal from a
  dead owner without writeback; <=4 tiles; no behind tiles $87/$92/$EE; box
  <=3x3 cells inside scanlines 16..159 and ring bytes 0..39 (stream margin));
  prescan the list storing AXV box + AUX_TILES (flips applied at copy via
  revpix/row-reverse); RING IDENTITY: dcol is ring-relative and the DMA shift
  does NOT move ring_b (the pass-0 fold exists because of this) -- store
  fb_col0 in ctx+5 at compose, and at stash adjust ctx.dcol0 by
  (fb_col0 - ctx5)*2 bytes to absorb any missed shift frames.
- w3_draw (window): w3_bank(A=page) helper; C=1 from w6_elig -> dance 8,
  aux_compose; else if AXV_REL (we owned, lost eligibility) -> dance 8,
  aux_uncompose first, then dance 6, plain walk. Budget ~+45B window
  (cap $75F, now $6EB).
- KEY OPEN QUESTION found at checkpoint: erase_slot has exactly ONE caller
  (pass 3a, entangled-only). Singles apparently draw OVER their old image
  (moves <=2px keep the quad self-covering?) -- verify how singles erase
  before deciding whether composed objects can keep o_pdr=1 (which would let
  the existing dead-slot leftover erase self-clean a dead composed object's
  image; the plan currently assumes yes).
- Then: gates + flickermeter delta (baseline: cannons 14/199, tokotoko
  45/369, ganchan 2/26 flicker-frames) + stray sweep + ship.

## Singles-erase answer (session-end finding, verify next)

erase_slot's ONLY caller is pass 3a, gated on o_nfl bit0 + o_pdr. restore_bg's
other callers are Mario and the pipe paths. Therefore bit0 is NOT just
"entangled" -- it must be pass 1's "needs an erase" mark (moved/anim sprites),
with @spread ADDING overlap victims to the same bit; that is how singles stay
clean today. CONSEQUENCE for the composer: a composed object must keep bit0
CLEAR (or o_pdr=0) so pass 3a never erases it -- re-plan the o_pdr=1
bookkeeping idea from the handoff with this in mind, and VERIFY by reading
pass 1's classification before wiring anything.

## Pass-1 classification VERIFIED (reading the code, session end)

o_nfl bit1 = visible, bit0 = DIRTY (mover/anim/stream-hit; also set on an
invisible slot with o_pdr for the leftover erase). Pass 3a erases bit0+o_pdr.
So the composed contract is simply **o_pdr = 0**: pass 3a never touches the
object, dead-slot leftovers skip it too (no self-clean -- the composer's own
release rules from the handoff must cover death, which they do: eligibility
loss uncomposes while alive, corpses fall off-screen before culling). p4_one
sets o_pdr=1 after every draw, so the composed dispatch must CLEAR it again
(or return via a path that skips @wset) -- one stz in the window dispatch.
The dirty budget applies to composed objects unchanged (fine: compose cost
~= old draw cost). Everything needed for the wiring is now known.

## SHIPPED (v1, one context)

Wired end to end: w6_elig (bank-6 W3X + W3X2 pins) prescans the display list,
screens eligibility (ownership incl. dead-owner steal; 40px overlap radius vs
every slot + Mario; <=4 tiles; no behind tiles; box <=3x3 inside scanlines
16..159 and ring bytes 0..39; fb_col0 re-base with the stale-warp guard), and
stashes the AXV box + final tile pixels; w3_draw dispatches compose (page 8)
/ uncompose+plain; w3_step clears o_pdr for the composed slot each update.
Two real bugs found by the gates: shtab page 0 is the W3 column cache (the
identity shift must be computed, never read -- caught by poisoning the page
in the unit test) and the fb ring seam at $5FE0 (row stepping now wraps like
ring_next_dst -- caught by the stray sweep as a full-height garbage band).

MEASURED: a composed object is blank 1/197 object-frames vs 82/394 (21%) for
the plain pipeline -- the flicker is fully solved for whatever the context
covers. ONE context = one protected object at a time (every RAM pool is
exhausted; the window tail barely fits 152B). Stray sweeps: byte-identical
event lists vs the pre-compose build (no new artifacts); battery 10/10;
svgold 9/9 byte-identical; the roomscript was re-recorded via svauto (E23:
replays die at every engine-speed change).

NEXT for more coverage: a second context needs 152B of RAM from somewhere
(candidates: shrink the W3 column cache to 8 slots = 128B, still short; or
group-compose in the aux page, which also lifts the overlap restriction --
the real endgame for crowds and for 2-3).

## v1 VERDICT (user-tested, 2026-08-23 night): GATED OFF

The user saw no flicker improvement and FELT a slowdown; both verified by a
proper A/B (after a first invalid A/B -- `make` silently skipped rebuilds
across git checkouts and compared a ROM against itself; force-clean the god
objdir when building historical flavors):

    zone         pre   composed        (logic frames / 600, 585 = full)
    two-cannon   553   552
    tokotoko     458   411   <- the claim/release churn among overlapping
    ganchan      502   511      rollers; each release = a 9-cell writeback

Why invisible in play: ONE context (all RAM pools exhausted) + the overlap
and near-Mario exclusions mean the protected object is almost never the one
the player is watching. The 1/197-vs-82/394 blank measurement was real but
taken with Mario parked in the SKY watching isolated enemies -- a scenario
no player experiences. CX_EN (init 0) now gates the dispatch; everything
stays in the image, dormant.

What v1 leaves behind, all committed and unit-tested: the 512K image with
the page-8 aux mechanism, the bank-6 W3X/W3X2 pins, the walk relocation, the
save-under composer with the ring-seam wrap + the column-cache identity trap
solved, the stash/eligibility machinery, the flickermeter, and the traps
list. The group-compose evolution (compose overlapping CLUSTERS in one
region) is the only design on the table that would be user-visible: it
lifts both the coverage limit and the overlap exclusion, and would also fix
2-3's parked flicker. Cost estimate: a multi-sprite stash, region merging,
and 300+ bytes of aux code -- all of which now have room.

## v2 = GROUP COMPOSE, map-based (2026-08-24) -- SHIPPED ON

Design (replaces save-under): page 8 = the FULL bank-1 image (prefix, the W3
bg charset in the tail -- bgc resolves normally) with the W3 sprite slice
mirrored at $A600 and the composer at $A9C0 (the dead level-header region).
Each W3 object's draw runs the display-list walk in STASH mode (bank 6, W3X2)
recording its tiles/box into a per-slot stash (20B, $1C70 / $1FA0), makes
the map columns of old+new boxes cache-hot (w6_touch), then the composer
(page 8) rebuilds every cell of old+new boxes from the MAP (column cache ->
map_transform -> get_tile_src, sky fast path) with EVERY stash entry's
tiles overlaid (prefiltered per compose), one 16-byte write per cell (ring
seam wrapped). No contexts, no RAM squeeze, no overlap rule: overlapping
sprites compose together because the bg source is sprite-free. Plain-path
W3 objects (behind tiles, >4 tiles, HUD/bottom/right-margin boxes) get
OVERLAY-ONLY entries (bit6) so composed neighbours paint them rather than
bail. Composed objects hold o_pdr=0 (w3_step clears it each update AFTER
w3_ffc7 -- cs_entry clobbers tmpL2 which ffc7 consumes: that ordering bug
had broken the wall probe in both modes for a while); if o_pdr leaks on a
stagger frame, w3_width parks o_pvy=$F0 so the old erase is a no-op.
Unchanged objects early-out (identical stash + no foreign old image near).
Dead/invisible owners are marked DYING once per frame (w6_frame, with their
columns pre-touched) and their boxes recomposed without them (aux_sweep).

MEASURED (E31: Mario PLAYED into the scene by the svauto route, same build,
composer toggled by poking CX_EN=$1FE0):
    ROUTE   torn sprites  54 -> 3  of ~363 object-frames   logic 1489 -> 1310 (-12%)
    parked crowd (3 rollers, Mario in the sky): torn 5.5% -> 7.3%, blank 2.9% -> 3.1%
        (both dominated by screen-edge partials), logic 546 -> 470 (-14%)
    parked cannons: equal;  parked ganchan: torn 0 -> 7/29, logic -10%
"Torn" (a sprite drawn partially -- the NMI catching erase-then-draw) is what
reads as flicker; blank-rect counting had missed it entirely. Gates: battery
10/10 (roomscript re-recorded), aux unit tests (tools/test_aux2.py, all flip
combinations bit-exact), stray sweep clean (1 mask-edge false positive),
svgold identical except level 6.

Bugs the gates caught on the way: init's bpl loop >128 (stash left $FF ->
composer over 255x255 cells = freeze); composer scratch colliding with the
stack (physics chaos); page-8 layout clobbering the bgc charset in the
bank-1 tail; sweep restoring X from a reused temp (hundreds of column
fills per frame); the w3_step hook ordering vs w3_ffc7 (tmpL2).

OPEN: the -12% logic cost (compose ~= 3x a plain draw per moving object;
per-cell bg fetch + overlay tests dominate -- per-column id precompute and
an unrolled cell write are the next cuts); Batadon/corpse coverage (>4
tiles); 2-3 could get the same treatment (its own bank layout).
