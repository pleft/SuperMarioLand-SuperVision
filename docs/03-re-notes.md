# Reverse-Engineering Notes (Phase 2)

Annotations layered on the verified ground-truth disassembly. Each entry cites
ROM addresses. Confidence tags:
**[FACT]** = directly from bytes/opcodes · **[CAND]** = plausible, unconfirmed · **[UNKNOWN]**.

---

## 1. Restart (RST) vectors — bank 00
- **[FACT]** `RST_00`/`RST_08` ($00/$08): `jp $0185` (→ main init).
- **[FACT]** `RST_10/18/20/38`: unused (nops).
- **[FACT]** `RST_28` ($28)+`RST_30` ($30): **jump-table dispatcher**. Caller does
  `ld a,<index>; rst RST_28` immediately followed by an inline `dw` table; it
  computes `2*A`, reads `table[A]`, and `jp`s there. Used by the state machine and
  other dispatch tables throughout.

## 2. Interrupts
IE/IF use $03 → **VBlank + LCD-STAT** enabled (timer/serial/joypad off in play).

### VBlank ISR ($40 → `JoypadTransitionInterrupt`, $0040-area)
**[FACT]** Per-frame "draw/commit" chain (push af/bc/de/hl, then):
1. `call $2258`
2. `call $1B86`
3. `call $1C33`
4. **`call $FFB6`** — OAM DMA routine resident in HRAM (see var map)
5. `call $3F39`
6. `call $3D6A`
7. `call $2401`
8. `inc [$FFAC]` — frame counter++
9. if `$FFB3==$3A`: `set 5,[rLCDC]` (enable window)
10. `rSCX=0; rSCY=0; $FF85=1` (signal frame done); `pop…; reti`

### LCD-STAT ISR ($48 → `$0095`) — raster status-bar split
**[FACT]** Waits for PPU mode, then drives a mid-frame split using `rLYC`($FF45),
`rSCX`($FF43), `rSCY`, and (in state $3A) the window `rWY`($FF4A). Maintains
`$C0A5` (split phase), `$C0DE`/`$C0DF` (alt SCY enable/value), `$FFA4` (SCX value),
`$FFFB`. This reproduces the fixed status bar / level-intro window scroll.
→ **Port note:** Supervision has no LYC/STAT raster interrupt; this effect must be
emulated another way on the target (documented for the port phase).

## 3. Main init ($0185)
**[FACT]** Sequence:
- `di`; `rIF/rIE=$03`; `rSTAT=$40` (LYC select); `rSCY=rSCX=$FFA4=0`; `rLCDC=$80`.
- wait `rLY==$94` (vblank) → `rLCDC=$03`.
- palettes: `rBGP=$E4`, `rOBP0=$E4`, `rOBP1=$54`.
- sound on: `NR52($FF26)=$80`, `NR51($FF25)=$FF`, `NR50($FF24)=$77`.
- `sp=$CFFF`.
- clear **WRAM** $C000–$DFFF, **VRAM** $8000–$9FFF, OAM/$FE00-area, **HRAM** $FF80–$FFFE.
- copy **12 bytes from $3F92 → HRAM $FFB6** (the OAM-DMA routine; run via `call $FFB6`).
- seed vars: `$FFE4=0,$FFB4=$11,$C0A8=$11,$C0DC=2,$FFB3=$0E (initial state),`
  `$FFB3 dispatch=$0E`, `$C0A4=3,$C0E1=0,$FF9A=0`.
- **bank switching via `$2000`**: `ld a,3; ld [$2000],a` selects ROM bank 3, then
  `call $7FF3`; switch to bank 2; `$FFFD=current bank`.

## 4. Main loop ($0226)
**[FACT]**
- if `[$DA1D]==3`: set `$DA1D=$FF`; `call $09F1`; `call $1736` (soft-reset path?).
- save bank→$FFE1, bank=3, `call $47F2`, restore bank (per-frame bank-3 work).
- if `$FF9F==0`: `call $07DA`; if `$FFB2!=0` skip to halt.
- decrement countdown timers `$FFA6`,`$FFA7` if nonzero.
- attract/demo handling via `$FFAC`,`$C0D7`,`$FF80` bit3,`$FFAC&0F`,`$FFB3`.
- `call $02A3` — run current game state (see `04-state-machine.md`).
- `halt`; wait until `$FF85!=0` (set by VBlank ISR); clear it; loop.
  → **`$FF85` is the frame-sync flag.**

---

## 5. Memory map — confirmed registers / variables
### MBC / banking
| Addr  | Meaning |
|-------|---------|
| **$2000** | **[FACT]** MBC1 ROM-bank select (write bank #) |
| $FFFD | **[CAND]** shadow of current ROM bank |
| $FFE1 | **[FACT]** temp save of bank around a bank-3 call |

### Frame / state control (HRAM)
| Addr  | Meaning |
|-------|---------|
| $FF85 | **[FACT]** frame-done flag (VBlank ISR sets=1; main loop waits/clears) |
| $FFAC | **[FACT]** frame counter (VBlank ISR `inc`); low nibble used for timing |
| $FFB3 | **[FACT]** master game-state index (0..$3D), dispatch table @ $02A6 |
| $FFB6 | **[FACT]** 12-byte OAM-DMA routine resident in HRAM (src $3F92) |
| $FFB2 | **[CAND]** skip-update flag |
| $FFB4 | **[CAND]** init $11 |
| $FFA4 | **[FACT]** SCX value applied by STAT ISR |
| $FFA6/$FFA7 | **[FACT]** general countdown timers (main loop decrements) |
| $FF9F | **[CAND]** pause/freeze flag (gates updates; read at $0166,$023C,$0264) |
| $FF9A | **[CAND]** init 0 |
| $FFE4 | **[CAND]** init 0 |
| $FFFB | **[CAND]** used by STAT split |
| $FF80 | **[FACT]** held buttons (0=A 1=B 2=Sel 3=Start 4=R 5=L 6=Up 7=Down). See `07-input.md` |
| $FF81 | **[FACT]** newly-pressed buttons this frame (same bit layout) |

### WRAM
| Addr  | Meaning |
|-------|---------|
| $C0A0 | **[FACT]** score, BCD little-endian, 3 bytes ($C0A0..$C0A2). Reset to 0 in State_11; added via `$0166`; compared to hi-score at $03C5. |
| $C0C0 | **[FACT]** high score, BCD, 3 bytes ($C0C0..$C0C2). State_0E: if score>hi, copy score→hi. |
| $C0A4 | **[CAND]** init 3 |
| $C0A5 | **[FACT]** STAT-split phase flag |
| $C0A8 | **[CAND]** init $11 |
| $C0DC | **[CAND]** init 2 |
| $C0DE/$C0DF | **[FACT]** alt-SCY enable / value (STAT ISR) |
| $C0D7 | **[CAND]** attract/demo countdown |
| $C0E1 | **[CAND]** init 0 |
| $DA1D | **[CAND]** mode/reset trigger (main loop: ==3 → reset path) |

### Hardware registers used (from hardware.inc)
rLCDC $FF40, rSTAT $FF41, rSCY $FF42, rSCX $FF43, rLY $FF44, rLYC $FF45,
rBGP $FF47, rOBP0 $FF48, rOBP1 $FF49, rWY $FF4A, rWX $FF4B, rIF $FF0F, rIE $FFFF,
NR50 $FF24, NR51 $FF25, NR52 $FF26.

---

## 6. Shared subroutines (named in symbols/sml.sym)
- **[FACT]** `Memcpy_HL_to_DE_BC` ($05DE): copy BC bytes `[HL]→[DE]` (VRAM/general).
- **[FACT]** `Fill20_HL_A` ($056F): fill 20 ($14) bytes at `[HL]` with `A` (one BG-map row).
- **[FACT]** `FillBGMap0_2C` ($05CF): fill `$9800..$9BFF` (BG map 0) with tile `$2C` (blank).
- **[CAND]** `$05E7`, `$060F`, `$05CF`-family: more VRAM setup helpers (used by State_11).

## 7. Early states (partial)
- **[FACT]** `State_0E` ($0322, boot): LCD off; clear `$C000..$C09E`; load graphics
  to VRAM (`$791A→$9300`, `$7E1A→$8800`, more); compare score vs hi-score and update
  hi-score; build a small BG-map layout (tiles $94/$95/$96/$8C/$3F/$4C/$4D at $9804/$9822/$982F).
  → candidate: top-level boot / title-or-screen setup. Confirm what screen it draws.
- **[FACT]** `State_11` ($0576): if `$FF9F==0` reset score `$C0A0..$C0A2`=0 and `$FFFA`=0;
  run VRAM setup; clear BG map1 `$9C00` (95 bytes) with tile $2C; set `rLYC=$0F`,
  `rTAC=$07` (timer on), `rWY=$85`,`rWX=$60`, `rTMA=0`; init `$FFA7/$FFB1`; call level/
  actor setup (`$2442`,`$3D1A`,`$1C1B`,`$1C56`,`$0D6D`). → candidate: **start-level / gameplay init**.
- **[FACT]** `State_10` ($05CE): `ret` (empty / no-op state).

## 8. Method / invariants
Work outward from entry & ISRs via `symbols/sml.sym` (see `docs/05-methodology.md`).
**Every change keeps the rebuild byte-identical** — verify with `tools/regen.sh`.
Next: identify what State_0E/State_11 screens are; trace the per-frame VBlank chain
routines ($2258,$1B86,$1C33,$3F39,$3D6A,$2401) and input reading.
