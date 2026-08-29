# World 4 (levels 9-11 = 4-1, 4-2, 4-3) -- plan and RE inventory

Written 2026-08-29, before any code. Method as always: RE the GB first, then
port, then gate (battery31 + svgold + an auto-route that completes).

## What the levels actually contain

From `build/levels/level_09..11.json` (spawn lists, hard-mode bit 7 masked off)
cross-referenced with the W3 kit's `w3_typetab` and the engine's own roster:

| level | spawns | already ported | NEW types |
|---|---|---|---|
| 4-1 (9) | 82 | $00 $02 $04 $0A $0B $0C $36 $38 $39 $49 | **$55, $56** |
| 4-2 (10) | 70 | $00 $02 $04 $06 $09 $0B $36 $3A $3F $49 $4B | **$54, $55** |
| 4-3 (11) | 77 | $06 | **$4D $52 $53 $54 $59 $61** |

So 4-1 and 4-2 are mostly a LEVEL-DATA job: two new enemies each, everything
else is already running in W3. 4-3 is the boss level and brings six.

Every new type has a real AI-VM script ($349E table), so the W3 kit runs them
as data -- no new engine code, the same reason W3 went in as fast as it did.

### the new types, from the ROM

* **$55** -- 8x8, not standable, NOT stompable (contact $3186: stomp $00, side
  $FF = hurts, ball $00). Script $3BE0: bobs on the spot, alternating params
  $5F/$60, one 1px/tick step down and back. A pure hazard.
* **$56** -- 16x16, stompable -> morphs to **$57**, side hurts, Superball kill
  -> $15. phys0 $B4 (bit2 = reverse at walls): a wall-reversing walker.
* **$54** -- 8x8, not standable, not stompable, side hurts.
* 4-3's six ($4D $52 $53 $59 $61 + $54) include long scripted arcs ($53 is a
  60-step velocity program) and a spawner ($52 fires a child $50); $61 is the
  level's boss.

## The constraint that decides the shape of the work

The W3 sprite overlay has **68 tile slots** ($A0-$E3). Regenerating the kit's
data with the new types:

    + $55,$56            35 scripts, 1200B, 68 tiles   FITS
    + $54,$55,$56        36 scripts, 1227B, 68 tiles   FITS
    + all of World 4     9 out-of-range tile ids, 7 free slots   OVERFLOWS

So 4-1 and 4-2 go in under the existing single-blob design; **4-3 needs a
per-world tile slice** (or freed slots) before it can be built. That is the one
architectural decision World 4 carries, and it is deferred until 4-1/4-2 are
playable.

## Order of work

1. **4-1**: SEED += $55,$56; give level 9 a bank (MAGNUM pages 9-14 are free)
   and extend `lvl_bank_tab` + the three `cmp #9` level-count checks; build;
   auto-route; differential vs the GB; playtest.
2. **4-2**: SEED += $54; same loop.
3. **4-3**: solve the tile budget (per-world slice), then the boss.

Before writing a line of it, walk docs/35 (the port laws) -- A2/A3 (erase boxes
and the straddle row) and B1/B2 (contact rules) are the ones W3 paid for twice.
