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

## The bank design (settled 2026-08-29, first two steps landed)

Measured facts that decide it:

* bank 1 (W3 resident) has **25 bytes** free; its tail runs to the far kit.
* bank 6's cold region ($8400-$A7C0, 9152B) holds W3's three maps + rooms +
  spawns in 8860B -- **292 bytes** free. Level 9 alone needs ~3.7KB more.
* MAGNUM pages 9-15 are entirely free in the 512K image.

So each WORLD gets a bank PAIR, exactly as World 3 has (1, 6):

| world | resident bank | cold bank |
|---|---|---|
| 3 (levels 6-8) | 1 | 6 |
| 4 (levels 9-11) | **9** | **10** |

*Resident* = the LEVELS prefix + the level headers (pinned at `W3HDR + (lvl-6)*24`,
so the engine's existing lookup works unchanged), pipes/blocks, the loader stub,
the world's BG charset, and the far kit at $BE50.
*Cold* = maps/rooms/spawns + the kit's pinned data (scripts $B200, display lists
$B540, tile slice $B740, the bank-resident walk $BC00) + the window image.

Two engine changes were needed and are **done and gated** (svgold 9/9,
battery31 10/10):

1. `cur_bank` -- load_level records the level's page; the kit's cold-bank
   detours (`w3_read`'s column fill, `w3_draw`'s tail) return to it instead of a
   hardcoded bank 1. Without this every W3-kit level was pinned to bank 1.
2. `w3_cold` -- a byte in the kit's window image holding the world's COLD page
   (6 for W3). pack_banks patches it in each world's copy, so one kit image can
   serve several worlds.

### what is left for 4-1

* `gen_w3data.py` per world (SEED, tile order, overlay source) -- World 4's
  sprite overlay is `w4_ovl_8A00.svt`, not W3's, so the slice must be built from
  it; this is also what gives 4-3 its own 68 slots later.
* the kit assembled per world (its tables live in the window image).
* `pack_banks.pack_w3` generalised to (levels, resident page, cold page).
* `NUM_LEVELS` 9 -> 10 and `lvl_bank_tab` += page 9.

## Pionpi ($56/$57) -- stomp behaviour (user report, fixed 2026-08-29)

GB rule: a stomp knocks a Pionpi FLAT ($57) for ~3 s, then it gets up ($56).
Stomps never kill it; only a Superball (or a star) does.

The port killed it after a few stomps. Two independent bugs, both fixed:

1. `w3_hp` and `w3_fcv` shared `$0128` (law E33). The gravity floor-probe
   verdict overwrote the Superball hit counter, so a knocked-down Pionpi
   incremented its own kill count once per knockdown. `w3_hp` moved to `$0132`.
2. `w3_ffc7`'s `@fall` re-keyed the probe cache to the new y (law E32), so an
   airborne object never re-probed and fell through the floor until the y>=168
   cull freed the slot. A Pionpi stomped MID-HOP therefore vanished ("died")
   on the second stomp; one stomped while grounded survived. This was a
   cross-world bug: any W3 object that left the ground was affected.

Verified after the fix (god build, Mario dropped on the first Pionpi at
x448 y112 every 110 frames): 6 knockdowns over 12 stomps, ~184 frames flat
each, still alive at f1399. Gates: battery31 10/10, svgold 9/9 identical.
