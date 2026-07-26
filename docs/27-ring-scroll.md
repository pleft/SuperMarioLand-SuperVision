# 27 — Ring-buffer scrolling (zero-copy)

The scroll rewrite that removed the per-32px framebuffer shift (and its
hitch) entirely. Verified facts it stands on:

- **The LCD scan is a ring.** The scan address wraps at $1FE0 = 8160 =
  170 lines x 48 bytes (Potator watara.c "SSSnake" wrap; hwtest14 confirmed
  the same on real hardware: Up-walking YSCROLL wraps seamlessly, and
  8160 % 48 = 0 preserves line phase).
- **The scan origin is byte-precise**: scan = XSCROLL/4 + YSCROLL*48, the
  XSCROLL low 2 bits delay pixels 0-3 clocks (1px scroll). Sampled per
  scanline on real hardware; per frame in stock Potator; per scanline in
  OUR patched core (the user's RetroArch — see memory patched-potator-core).
- Outside 0..8159 the real address masks at $1FFF and phase breaks
  (hwtest14 Down-from-0) — the port keeps every origin value in range.

## Design

- `ring_b` (+ its (line,byte) split `ring_y`/`ring_xb`) = the WINDOW ORIGIN,
  a ring byte offset. The old "shift the framebuffer 8 bytes left" is now
  `ring_b += 8` (mod 8160) — nothing is copied, ever. fb_col0/scroll_s/
  margin/stream semantics are unchanged (the window is now a diagonal
  48-byte-stride band of the ring; the 8-byte/line fetch gap is the margin).
- `set_dst` maps window cell (dy, dcol) -> $4000 + ((ring_b + dy*48 + dcol)
  mod 8160): every blit funnels through it. Row-marching blits advance via
  `ring_next_cur`/`ring_next_dst` (48 + the same wrap).
- View registers (calc_view, at frame start): vyp/vxp from origin + scroll_s;
  the NMI writes YSCROLL + XSCROLL=vxph (subpixel MASKED) so the HUD rows are
  byte-stable; the line-16 timer IRQ switches to vxp (1px-true playfield).
  On real hardware the split line wanders (NMI 61Hz vs LCD 50.8Hz, unsynced):
  worst case a <=3px subpixel shear mid-screen; v2 = SYS_CTRL restart trick.
- **HUD**: lives in a WRAM shadow ($1D00, 16 rows x 40 bytes); put_hud/
  render_status_bar draw there. `hud_flush` copies it into ring rows 0..15
  at the view position whenever the origin moves a byte or a digit changed —
  the ring slides under the screen, so screen-fixed content is repainted.
- **Seam echo**: $5FE0-$5FFF mirror $4000-$401F every frame (hud_flush tail):
  the seam scanline's linear over-fetch (hwtest14's tick line) then shows
  exactly what the wrap shows. Blits crossing the seam wrap properly and
  never write the echo bytes.
- The helpers live in RCODE: an always-resident RAM blob at $1200-$14FF
  (below the $1500 overlay window), copied from bank 6 by boot6_init —
  FIXED and BANK0 are both full.

## Costs

- Steady per-frame: echo 32B; set_dst +~20cyc/blit; marchers +12cyc/row.
- On 4px view-byte crossings: hud_flush 640B copy (~9k cyc).
- The ring wraps once per ~32K world px (cumulative across levels) — the
  seam machinery (echo + split rows in hud_flush) covers it.

Deleted: fb_shift8 (both the illegal-DMA and CPU variants), draw_tilesheet
(unreferenced dev tool). The 1141 bytes it freed paid for everything.

## v2 restart-trick verdict (2026-07-26, REAL PANEL): DO NOT SHIP

Restarting the LCD scan every NMI (61 Hz) is ELECTRICALLY hostile to the
panel: the second field pass gets truncated at a different line each frame
(thick scanline banding) and the LCD's AC drive loses balance (pale, washed
out image). sml17 was unplayable on hardware. REVERTED to the no-restart
split: the HUD shows a <=3px subpixel wobble on real hardware (the NMI
free-runs against the scan, so HUD lines usually latch the playfield's
subpixel bits). The emulator (patched core v2) is exact for the no-restart
game: restart_slice resets to 0 each frame and only moves on SYS_CTRL
writes (level loads).

The CORRECT future fix (designed, not yet built): ONE restart per level
load to define scan phase, then a self-correcting timer-IRQ chain locked
to the field period (615 ticks = exactly 4 fields; per-field slots at
line 16 / line ~120 (repaint window) / field end) — zero further restarts,
zero drift (CPU and LCD share the crystal). Needs the emulator core to
render at real field boundaries to stay truthful. A full session's work;
until then the wobble is the accepted cosmetic.
