# 48 — the ELEFAS boot splash

An original pre-title boot splash, in the spirit of the Watara Supervision /
Travellmate boot logo (studied from the TOSEC set: "TRAVELL" slides up-left and
"MATE™" slides in from the right, black-on-white, then the game title). Ours:
on a white screen the author tag comes in as two words — **ELEFAS-** slides in
from the left edge and **RETRODEV** from the right, both on the screen's middle
row, one 4 px (byte) step every 2 frames, and meet in the centre (~1.2 s); then a
rising **C‑E‑G‑C** major arpeggio chimes on square 1; it holds, then the screen
clears and the normal SML title runs. (Horizontal steps are 4 px because the
blitter is byte-aligned; a tile whose column is off-screen or past the ring
margin is skipped, which is what lets the words enter from beyond the edges.) Nothing is copied —
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
  maps bank 0, clears, animates (one shared `words` routine draws or
  white-fills both words, clipping off-screen tiles), and — to keep `clear_vram`+`title_screen` off
  the FIXED bank — clears and tail-calls the title itself before returning to the
  boot flow. The blob must stay ≤ 256 bytes (the stub copies one page); it is
  currently 226 (15 tiles, cols 2–16; the HUD font's `-` is `$29`), and the
  source asserts the limit.

## Gameplay-neutral

`reset` net change is +2 FIXED bytes (the two-instruction bootstrap replaces the
moved `clear_vram`/`title_screen`), paid for by a `mod_test` 65C02 `(zp)` tweak.
The splash silences square 1 to its full boot state (`FLO/LEN/VOLDUTY = 0`)
before the title, and uses `tmpH3` (not `b_i`) for its counter, so no state
leaks into the level — svgold levels 0–8 are byte-identical to the pre-splash
build and battery31 passes. It runs in both flavors (each rebuilds its own blob
against its own ABI). The title screen (level-select, sound test) is unchanged.

## Game over restarts from the splash (decision)

`game_over` ends in `jmp reset`: a game over restarts the ROM from the boot
splash, exactly like power-on. A title-only re-entry was built and shipped for a
day (`go_title`: clear + title + score/lives reset + `next_level`'s init) and each
round of testing found another piece of state the boot path had been clearing
for free — the level's `scroll_s` still in `XSCROLL` (title shifted left), ring
lines 160–169 never cleared (a sliver on the title's last row), `bgc` still
pointing at the last level's charset (garbled level-select digits) — until the
user called it: the boot path re-initialises stack, ZP, WRAM, ring and VRAM in one
place, so it cannot carry anything over, and the splash replaying on a game over
is the cheaper price. Two side fixes from that work stay because they are correct
on their own: `clear_vram` clears the whole 8K (the ring's slack lines 160–169
included), and `next_level` is unchanged in behaviour.

**svgold note:** level 8's R900 hold runs blind into 3-3's opening and loses all
three lives by ~f400, so its gate frame (900) is after the game over — i.e. in
the reboot, mid-splash/title. Its hash therefore moves with any splash change;
levels 0–7 are the real regression gate. Current level-8 value: `08272978eb98`.
