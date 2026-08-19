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
level) contact ALWAYS hurts, whatever the vertical relation. The shared
walker helpers (`l3_hurt`, `enemy_contact`) implement the walker rule and must
not be reused unmodified there.

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
*(Cost: W3's HUD instability -- 22/frame, then still 9/frame after a partial
fix, because the DRAW path also switched.)*

**D2. Measure the switch rate in REAL play** (enemies on screen, no camera
teleport) before claiming a switching fix works. A quiet test frame proves
nothing.

**D3. The RAM map is full.** ZP full; BSS ends at $11FC with RCODE at $1200;
$1500-$1CFF is the kit window; $1D00-$1F7F the HUD shadow; $1F80-$1FFF is the
map-column cache. BOOT6 ($1500 image, 2048) has ~1.8K spare for ONE-SHOT boot
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

## F. GB capture recipes

- **Warp to a level**: poke `$ffe4 = target-1` AND `$ffb4` = the predecessor's
  BCD stage (State_08 increments both), then `$ffb3 = $08`.
  2-3 -> (4, $22); 3-1 -> (5, $23); 3-2 -> (6, $31); 3-3 -> (7, $32).
- **Reach an ending without fighting the boss**: glide `$C0AB` to the arena,
  then enter the clear state directly (`$ffa6 = $F0`, `$ffb3 = $07`).
- **Autoplay assist**: `$C0D3 = $F8` (star), `$DA15 = 5` (lives), and lift
  Mario when `$C201 > 0x96` so pits do not end the run.
