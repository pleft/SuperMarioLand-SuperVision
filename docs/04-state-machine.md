# Master Game-State Machine (`$FFB3`) — Reference

**[FACT]** The main per-frame routine `Call_000_02a3` ($02A3) dispatches on the
1-byte state index in **`$FFB3`** through a word table at **`$02A6`** via `RST_28`:

```
Call_000_02a3:
    ldh a, [$ffb3]   ; A = current game state
    rst RST_28       ; jump to StateTable[A]  (RST_28 doubles A, indexes dw table)
StateTable: dw ...   ; 62 entries, $02A6..$0321
```

**[FACT]** 62 entries, indices `$00`–`$3D`. Table ends at `$0322` (= the state-14
target, the first byte after the table). Boot enters at state **`$0E`** (init does
`ld a,$0E; ldh [$ffb3],a`).

Targets `$58xx` are in the **currently-mapped switchable bank** (likely small `jp`
trampolines, 3 bytes apart); all others are in bank 0. Names below are
**[UNKNOWN]/[CAND]** until each handler is traced — listed for navigation only.

| Idx | Target | Bank | Notes (to confirm) |
|-----|--------|------|--------------------|
| $00 | $0627 | 0 | |
| $01 | $06BC | 0 | |
| $02 | $06DC | 0 | |
| $03 | $0B8D | 0 | |
| $04 | $0BD6 | 0 | |
| $05 | $0C73 | 0 | |
| $06 | $0CCB | 0 | |
| $07 | $0C40 | 0 | |
| $08 | $0D49 | 0 | |
| $09 | $161B | 0 | |
| $0A | $162F | 0 | |
| $0B | $166C | 0 | |
| $0C | $16DA | 0 | |
| $0D | $2376 | 0 | |
| $0E | $0322 | 0 | **boot/initial state** |
| $0F | $04C3 | 0 | |
| $10 | $05CE | 0 | |
| $11 | $0576 | 0 | |
| $12 | $3D97 | 0 | |
| $13 | $3DD7 | 0 | |
| $14 | $5832 | banked | trampoline? |
| $15 | $5835 | banked | trampoline? |
| $16 | $3EA7 | 0 | |
| $17 | $5838 | banked | trampoline? |
| $18 | $583B | banked | trampoline? |
| $19 | $583E | banked | trampoline? |
| $1A | $5841 | banked | trampoline? |
| $1B | $0DF9 | 0 | |
| $1C | $0E15 | 0 | |
| $1D | $0E31 | 0 | |
| $1E | $0E5D | 0 | |
| $1F | $0E96 | 0 | |
| $20 | $0EA9 | 0 | |
| $21 | $0ECD | 0 | |
| $22 | $0F12 | 0 | |
| $23 | $0F33 | 0 | |
| $24 | $0F6A | 0 | |
| $25 | $0FFD | 0 | |
| $26 | $1055 | 0 | |
| $27 | $1099 | 0 | |
| $28 | $0EA9 | 0 | (same target as $20) |
| $29 | $1116 | 0 | |
| $2A | $1165 | 0 | |
| $2B | $1194 | 0 | |
| $2C | $11D0 | 0 | |
| $2D | $121B | 0 | |
| $2E | $1254 | 0 | |
| $2F | $12A1 | 0 | |
| $30 | $12C2 | 0 | |
| $31 | $12F1 | 0 | |
| $32 | $138E | 0 | |
| $33 | $13F0 | 0 | |
| $34 | $1441 | 0 | |
| $35 | $145A | 0 | |
| $36 | $1466 | 0 | |
| $37 | $1488 | 0 | |
| $38 | $14DC | 0 | |
| $39 | $1C7C | 0 | |
| $3A | $1CE8 | 0 | special-cased in ISRs (window enable, see below) |
| $3B | $1CF0 | 0 | |
| $3C | $1D1D | 0 | |
| $3D | $06BB | 0 | |

## State `$3A` is special-cased in both interrupt handlers
- **[FACT]** VBlank ISR: `if $ffb3==$3A: set bit5 of rLCDC` → enables the **window**.
- **[FACT]** STAT ISR: `if $ffb3==$3A:` runs the `rWY`($FF4A)-based raster split.
  → state $3A is a screen that uses the window layer (candidate: a specific
  menu/map/bonus screen). Confirm by tracing $1CE8.

## Resolved: the `$58xx` banked state handlers (task #8)
States `$14/$15/$17/$18/$19/$1A` dispatch to `$5832–$5841`, which are **`jp`
trampolines in bank 2** (the ambient bank is 2 when these states run). Real handlers:
| State | tramp | → bank-2 handler |
|-------|-------|------------------|
| $14 | $5832 | `$5A72` `State14_handler_b2` (uses rDIV randomness, `$C030` buffer) |
| $15 | $5835 | `$5ABB` `State15_handler_b2` (input/`$DA27`/`$DA22` — interactive) |
| $17 | $5838 | `$5B65` `State17_handler_b2` (starts music `$DFE8=$0A`) |
| $18 | $583B | `$5BEB` `State18_handler_b2` |
| $19 | $583E | `$5C44` `State19_handler_b2` |
| $1A | $5841 | `$5CDE` `State1A_handler_b2` |
(Likely the level-clear / bonus / ending sequence screens — confirm exact roles in #1.)

## State purpose identification (task #1)
From reading each handler's head. Confidence: [F]=firm, [C]=candidate, [?]=unknown.

### Boot / title / attract flow (the task focus)
- **$0E [F] BOOT** — LCD off, clear WRAM, load VRAM graphics; entry state; → title.
- **$0F [F] TITLE screen** — reads pressed (`$FF81`): **Start(bit3)** = begin game,
  **Select(bit2)** = option, **A(bit0)** = increment start world-stage `$FFB4`
  (SML's start-level select). Attract/demo plays via the `$4A94` demo player when idle
  (gated by `$FF9F`), replaying recorded inputs into `$FF80/81`.
- **$10 [F]** — empty (`ret`), no-op/placeholder state.
- **$11 [F] LEVEL START** — reset score, status-bar split setup, timer on, level+actor init.

### Gameplay / progression
- **$00 [F] GAMEPLAY (main)** — column stream + player + enemies + collision per frame.
- **$0D [C]** — gameplay variant (gated by `$FFB2`; paused/special gameplay).
- **$08 [F] LEVEL ADVANCE** — `$FFE4`++ (wrap 12), update world-stage `$FFB4`, reload.
- **$05 [C]** — world/stage check (`$FFB4`) → world-intro / map screen.
- **$09 [C]** — move Mario Y to a target (`$C201` vs `$FFF8`) — pipe-entry / fall.
- **$03 [C]** — Mario sprite/OAM assembly sub-state (death-fall?).

### Transitions / timed (mostly `$FFA6/$FFA7` countdown waits)
- **$01,$06,$07 [C]** — timer-wait transition delays.
- **$02,$0A,$12 [C]** — screen setup/clear transitions (LCD off + load/clear VRAM).
- **$04 [C]** — animated sequence (`$C0AC` counter). **$0B,$0C [?]** — timed effects.
- **$30 [F]** — cutscene "Mario rises" (scripted, `dec $C201` until Y=$58). **$31 [C]** — its continuation.
- **$3A [F]** — window-layer screen (enables window in both ISRs; map/bonus). **$3B/$3C/$3D [C]** — window/transition states.

### Bank-2 screens (run with bank 2 mapped; see "Resolved $58xx" above)
- **$14/$15/$17/$18/$19/$1A [C]** — level-clear / bonus-game / ending sequence screens
  (use rDIV randomness, input, music triggers).

### Remaining
- **$13, $16, $1B–$2D [?]** — menu/transition sub-states; granular per-state tracing
  is ongoing (not blocking — the boot/title/attract/gameplay backbone is identified).

## TODO
- [ ] Finish granular tracing of `$13/$16/$1B–$2D` sub-states as they become relevant.
