# 47 — the smooth flavor (flavor b, "gameplay-accurate")

The port builds in two flavors from one source. The default (`make`) is
**near-100% original-accurate**; the smooth flavor (`make smooth` →
`build/super-mario-land-smooth.sv`) is **near-100% gameplay-accurate**. Every
difference is `.ifdef SMOOTH`-guarded, so the default build stays byte-identical
(the `svgold` pixel gate confirms it after every change).

## Why

The default flavor pins the HUD (status bar) at the top of the screen exactly as
the Game Boy does. On the Supervision there is no hardware window, so this is a
**raster split**: the NMI sets `XSCROLL` for the HUD rows, arms a timer IRQ at
scanline 16, and the IRQ switches to the playfield scroll for the rest of the
frame (docs/27, docs/36). That split is 1:1 with the original but has two costs:

- the timer IRQ + a per-frame HUD copy (`nmi_hud_copy`) burn CPU every frame;
- on real hardware the NMI is not LCD-synced (~61 Hz vs ~50.8 Hz), so the split
  line wanders — a ≤3 px shear on the top playfield rows.

The smooth flavor trades the always-on HUD for a single, whole-screen scroll.

## What SMOOTH changes

- **NMI/IRQ.** No raster split: the NMI writes `YSCROLL`/`XSCROLL` once from the
  playfield view (`vyp`/`vxp`) and arms no timer; `irq` is a bare `rti`. This is
  the Kabi-no-Susume "one scroll for the whole screen" model.
- **HUD on pause.** During play nothing is drawn in the top rows. Pressing
  Start flushes the HUD shadow pinned to screen rows 0–1 (`pause_strip` →
  `nmi_hud_copy`); unpausing blanks it again.
- **Blank strips.** The ex-HUD top 16 scanlines and the lower 16 (the SV's two
  extra ground rows) are blanked to sky, for a symmetric letterbox. `draw_column`
  redraws scanlines 16–159 every column, so the lower strip is covered by
  `render_background`; the top strip is not, so `smooth_clear_strips` blanks
  **both** on every level/scene entry (else a prior level/ending's leftovers
  persist there).
- **Reclaimed budget.** With no split, the per-frame `hud_check` (a 32-byte seam
  echo + repaint bookkeeping that only fed the split) is dead and is gated out.
- **Sprites in the top rows.** With no HUD to hide behind, `draw_player`'s
  HUD-band occlusion (`spr_y < 16`) is lifted under SMOOTH, and `restore_bg`
  blanks VRAM rows 0–1 so Mario is visible (and cleanly erased) when a lift
  carries him up into the old HUD band.

## Measured effect

On this emulator a sprite only "flickers" when a frame overruns (its erase and
draw land on opposite sides of a frame boundary — docs/36). Freeing the split +
HUD budget lets more frames finish, so fewer sprites blank. On the 3-1 crowd
(god builds, real Potator core):

| | default | smooth |
|---|---|---|
| logic-complete (frames finished) | 79.3% | **85.5%** |
| tokotoko flicker | 12.1% | **7.3%** (−40%) |
| two-cannon flicker | 8.4% | **6.1%** |

The gain is purely headroom — the freed cycles are left free so the *existing*
render finishes; nothing new is drawn (that would make flicker worse, not
better). It applies to every scene automatically.

## Scope / not done

- The gain is global and free; further flicker reduction hits the machine's edge
  (the erase pass is already per-column-cached and batch-banked; Mario is already
  atomic-interleaved; W3 sprites are already composited — see docs/42, docs/36).
  A blanket active-enemy cap was tried and reverted twice (it removed
  platforms/standable enemies). The remaining lever is targeted per-spot thinning.
- **Open cosmetic:** the blanked strips are white (palette value 0) while the sky
  is value 1, so there is a faint shade seam at the strip edges. The proper fix
  is to extend the playfield to the full 160-line height.

## The "1px line" at the top strip (fixed)

Symptom (user): a garbage line along the bottom of the blank top strip, growing
rightward as the level scrolls, worst when Mario jumps up into the band.

Cause — a ring downward-spill at the sky/playfield seam (docs/27). The display
(`watara.c`) reads each scanline as 40 bytes starting at the XSCROLL byte
(`vxp>>2`, which sweeps 0..47 in the ring) from PHYSICAL line `vyp+i`. Once the
scroll passes 8 bytes, on-screen scanline 15 spills past line 15's 48-byte end
into the first playfield line (physical `vyp+16`) and shows terrain where sky
belongs. A VRAM dump proved it: physical line 15 was all-zero; the garbage is
line 16's terrain bytes read through the spill. Every playfield line spills the
same way, harmlessly, because the next line IS its horizontal continuation — the
seam is the one place where the continuation is a different kind of content.
The bottom strip is immune because `draw_column` draws it as sky per column, so
its spill lands in more sky. Blanking line 15 (the obvious fix) does nothing.

Fix — in the render loop, after `render_all`, blank physical line `vyp+16`'s
bytes `[0..X-1]` (X = `vxp>>2`), which only scanline 15 reads (scanline 16 reads
`[X..47]`). Addressed via `row48_lo+16,x`/`row48_hi+16,x` (the displayed
physical line), NOT `set_dst`, whose ring mapping lands on the visible bytes and
erases the playfield (measured: scanline 16 dropped to 0). Result on the ship
build (1-1, 240 frames of run+jump): scanline 15 160 px → **0 px**, scanline 16
intact, bottom band clean. Smooth-only; ~30 bytes.

### Paying for it: the flavor-a cycle law

FIXED (and bank 0, the level prefix, RCODE) are full, and the real budget is
CODE ≤ $2FFA (CHARS must clear the vectors at $FFFA). The bytes came from:
`smooth_hide_hud`/`smooth_clear_strips` inlined at their single call sites, the
redundant bottom-strip blank dropped, five cycle-neutral `jmp`→`bra`, and six
`ldy #0`+`lda (zp),y`→`lda (zp)` reclaims in the blit paths.

Those last ones are **gated `.ifdef SMOOTH`**, and that is a law now: the
default flavor keeps the raster split, so its picture depends on the exact CPU
cycle count per frame — a shared reclaim that changes cycles (dropping a
`ldy #0`, `jsr`+`rts`→`jmp`) silently changed the svgold hashes of levels
0/1/3/5. Smooth has no split and is cycle-insensitive. So a shared reclaim must
be cycle-neutral (`bra` = `jmp` = 3 cycles: svgold-clean), or gated smooth-only.
`lda (zp)`/`sta (zp)` themselves are fine (the core implements $B2/$92, equal to
the `,y` forms with Y=0); it is purely the timing.
