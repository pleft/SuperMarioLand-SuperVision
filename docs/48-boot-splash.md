# 48 — the ELEFAS boot splash

An original pre-title boot splash, in the spirit of the Watara Supervision /
Travellmate boot logo (studied from the TOSEC set: "TRAVELL" slides up-left and
"MATE™" slides in from the right, black-on-white, then the game title). Ours:
the author tag **ELEFAS** rises smoothly from the bottom of a white screen to
the centre while a rising **C‑E‑G‑C** major arpeggio chimes on square 1; it
holds, then the screen clears and the normal SML title runs. Nothing is copied —
original layout, original jingle, the porter's nickname.

## Why it needed infrastructure

The port's ROM banks are full (FIXED and BANK0 each have only a couple of free
bytes), so a ~200-byte splash could not simply be added. It also needs the HUD
font (`bg_chardata`, bank 0) and the LCD on, so its code must run somewhere
always reachable with bank 0 mapped. The solution mirrors `boot6`/`w3aux`:

- **Stored** in a free 512K page (13). `make_512k` pastes `build/intro.bin` at
  page 13's `$8000`; `pack_w4` uses pages 9–12, so 13 is untouched.
- **Built** as a standalone blob (`src/intro.s` + `cfg/intro.cfg`, linked at
  `$1500`) after the main link, against the engine ABI (`build/w2abi.inc`, which
  gained `frame_flag`, `blit_blank`, `bank_set`, `title_screen`). It calls the
  always-mapped FIXED primitives (`set_dst`/`blit_tile`/`get_tile_src`/
  `blit_blank`) exactly like the W2/W3/E43 overlays.
- **Reached** from `reset` with just two instructions — `lda #13 / jsr bank_set`
  then `jsr $8000` — to stay inside the FIXED budget. `bank_set` is the FIXED
  twin of `set_bank`; the LEVELS-resident `set_bank` would unmap itself when
  switching to a page with no prefix copy.
- **Self-relocating.** Running at page 13's `$8000`, the blob's stub copies one
  page into the `$1500` RAM window and jumps into that copy (page 13 has no
  prefix, so the code cannot execute there once bank 0 is mapped back). It then
  maps bank 0, clears, animates, and — to keep `clear_vram`+`title_screen` off
  the FIXED bank — clears and tail-calls the title itself before returning to the
  boot flow. The blob must stay ≤ 256 bytes (the stub copies one page); it is
  currently 210.

## Gameplay-neutral

`reset` net change is +2 FIXED bytes (the two-instruction bootstrap replaces the
moved `clear_vram`/`title_screen`), paid for by a `mod_test` 65C02 `(zp)` tweak.
The splash silences square 1 to its full boot state (`FLO/LEN/VOLDUTY = 0`)
before the title, and uses `tmpH3` (not `b_i`) for its counter, so no state
leaks into the level — svgold levels 0–8 are byte-identical to the pre-splash
build and battery31 passes. It runs in both flavors (each rebuilds its own blob
against its own ABI). The title screen (level-select, sound test) is unchanged.
