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
