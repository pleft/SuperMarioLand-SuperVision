# Rendering / OAM Subsystem (Task #2)

How the screen is composed each frame. All [FACT] unless tagged. Addresses are GB.

## VRAM layout (observed)
| Region        | Use |
|---------------|-----|
| $8000–$8FFF   | sprite (OBJ) tiles; some BG tiles too (loaded in State_0E to $8800) |
| $9000–$97FF   | BG tile patterns (animated tiles updated at $95D1, see #7) |
| $9800–$9BFF   | **BG map 0** (32×32 tilemap); status bar uses top rows |
| $9C00–$9FFF   | **BG map 1** = window layer (used by state $3A and others) |

### Status-bar tile positions in BG map 0 (top row area)
- $9806/$9807 — 2-digit BCD display from `$DA15` (#3)
- $9820       — score digits, from BCD `$C0A0..$C0A2` (#5)
- $9831–$9833 — 3-digit BCD display from `$DA00..$DA02` (#6) = **game TIMER** (see docs/13)

## OAM (sprites)
- **[FACT]** Shadow OAM buffer at **`$C000`** (40 entries × 4 bytes = 160).
  Game logic writes sprites here; it is DMA'd to hardware OAM each VBlank.
- **[FACT]** OAM-DMA routine lives in HRAM at **`$FFB6`** (copied from `$3F92`
  during init). Body: `ld a,$C0; ldh [rDMA],a; ld a,$28; .wait: dec a; jr nz; ret`.
- **[CAND]** Parallel BG-map shadow/metadata array at **`$C800`** (= `$9800`+$3000;
  `$2258` writes `[h+$30]`=meta alongside each map tile). Used for collision/tile-type.

## The VBlank rendering chain (runs inside the VBlank ISR, in this order)
VRAM is only safely writable during VBlank, so all VRAM commits happen here:

| # | Addr  | Name (symbols)            | Role | Gate |
|---|-------|---------------------------|------|------|
| 1 | $2258 | VBlank_ScrollColumnUpd    | draw the next BG-map column from 16-byte buffer `$C0B0` as the level scrolls; column cursor `$FFE9` cycles `$40..$5F` | `$FFEA==1` |
| 2 | $1B86 | VBlank_ProcessVRAMQueue   | apply queued single-tile VRAM writes (cmd in `$FFEE`, target ptr, values like $7F/$2C) — block-break/coin pickups | cmd-driven |
| 3 | $1C33 | VBlank_UpdateDisp_DA15    | write 2-digit BCD `$DA15` → map `$9806/$9807` | `$FF9F==0`, `$C0A3` |
| 4 | $FFB6 | (OAM DMA)                 | DMA `$C000` → OAM | always |
| 5 | $3F39 | VBlank_DrawScore          | BCD score `$C0A0..2` → tiles `$9820..` (blank leading zeros with $2C) | `$FFB1` dirty |
| 6 | $3D6A | VBlank_UpdateDisp_DA00    | 3-digit BCD `$DA00..2` → map `$9831..33` | `$C0A4==0`, state<$12, `$DA00==$28` |
| 7 | $2401 | VBlank_AnimateTiles       | copy an 8-byte tile pattern → `$95D1` every 8 frames (animated tiles); source `$3FC4`+idx or `$C600` | `$D014`, state<$0D, `$FFAC&7==0` |

After the chain the ISR: `inc $FFAC`; if state==$3A enable window (`set 5,rLCDC`);
`rSCX=rSCY=0`; `$FF85=1` (frame done); `reti`.

## Key variables (rendering)
| Addr  | Meaning |
|-------|---------|
| $C000 | **[FACT]** shadow OAM (40×4) → DMA each VBlank |
| $C0B0 | **[FACT]** 16-byte BG column buffer for scroll updates |
| $C800 | **[CAND]** BG-map shadow/metadata array (tile-type/collision) |
| $FFB1 | **[FACT]** score-display-dirty flag (set by score-add `$0166`, cleared by `$3F39`) |
| $FFE9 | **[FACT]** scroll column cursor ($40..$5F) |
| $FFEA | **[FACT]** scroll-update enable / phase |
| $FFEE | **[CAND]** VRAM-write queue command byte |
| $DA15 | **[CAND]** value shown at $9806/$9807 (2-digit) |
| $DA00–$DA02 | **[FACT]** game TIMER (BCD countdown); $DA1D = time-up trigger (docs/13) |

## Port implications (Watara Supervision)
- Supervision has a **linear framebuffer LCD**, not a GB tile/OAM PPU. The whole
  "shadow OAM + DMA" and "BG tilemap + scroll-column" model must be re-expressed as
  framebuffer blitting on the target. The *logical* structure here (what to draw,
  when, from which buffers) is what we reproduce 1-1; the mechanism changes.
- The status-bar split (STAT/LYC ISR) has no Supervision equivalent — revisit in
  the port phase (tracked separately).

## TODO / open
- [ ] Confirm $C800 meta-array purpose by xref from collision code.
- [ ] Confirm $DA00/$DA15 identities (coins / timer / lives) via the gameplay code.
- [ ] Document where game logic builds the $C000 OAM buffer (sprite assembly).

## ATOMIC erase+draw for sprites that overlap nothing (2026-08-28)

The port's sprite pipeline is: erase every dirty sprite, then draw them all
(pass 3a / pass 4), because one sprite's erase must never land on another's
fresh pixels. That leaves every sprite BLANK from its own erase until its draw
-- and on the real machine the display is not synced to the render (61Hz NMI vs
~50.8Hz LCD), so the beam samples that gap. User, on 3-3's boss: *"it still
flickers a lot even with 1 boulder ... we only have mario, boss and one boulder
on the scene"*.

The whole split is only needed for sprites that actually OVERLAP:

* `@spread` already box-tests every pair (and Mario vs every slot). It now marks
  **bit3 of `o_nfl`** on any pair where BOTH are dirty -- "entangled" -- and
  `m_dirty` bit1 for Mario. Only j is marked in the slot loop: the loop visits
  (j,i) too and marks i there on the same terms.
* pass 3a: a dirty sprite that is **visible and not entangled** is drawn RIGHT
  AFTER its own erase (`jsr p4_one`, then bits 0+2 cleared so pass 4 skips it).
  Its blank window is one blit instead of the whole render.
* Mario, isolated, has his erase moved down beside his own draw; entangled, it
  moves to the END of the erase phase (it only has to precede the DRAWS).

Measured (instrumented build, counters removed before shipping): **30% of the
boss arena's sprite draws and 44% of the 3-3 lift ride's are now atomic**;
Mario takes the tight path in 13% of lift-ride frames (in the arena he is
usually within the coarse 32x28 box of the boss, and that box IS the right test
-- his erase rect is 24px wide).

Space: FIXED had 3 bytes. `draw_obj_sprite`'s 21-entry `cmp/bne/jmp` chain was
replaced by an RTS jump table (`@dtab`), which freed 76 -- gold-identical on all
nine levels by itself.

Two traps this hit, both caught by svgold:
1. **A dead slot is dirty too** (its leftover image still needs the erase) and
   is NOT visible. Drawing it ran the type-0 dispatch -- into address $0001.
   The guard is `and #$0A / cmp #2` (visible AND not entangled), and table
   entry 0 now points at an `rts`.
2. **A dirty slot with no old image** (a fresh spawn) has no box to test, so
   Mario was left "isolated" and his late erase clipped 2-2's score popup. Such
   a slot now holds him in the group.

Note: `o_pdr` (drawn-flag) feeds the kits' slot-reuse guard, so drawing earlier
can change which slot a spawn takes. Scenes stay correct but REPLAYS diverge --
re-record routes on this build (E23).
