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
