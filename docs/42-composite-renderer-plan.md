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
