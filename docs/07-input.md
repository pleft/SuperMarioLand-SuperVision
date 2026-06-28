# Input / Joypad Subsystem (Task #3)

## Routine: `ReadJoypad` @ `03:47F2` (bank 3)
**[FACT]** Called once per frame by the main loop (`call $47F2` after mapping bank 3).
Standard GB joypad read with hardware debounce:

```
ld a,$20 ; ldh [rP1],a          ; select D-pad row (P14 low)
ldh a,[rP1] ; ldh a,[rP1]       ; read twice (settle)
cpl ; and $0f ; swap a ; ld b,a ; active-high, move to high nibble
ld a,$10 ; ldh [rP1],a          ; select buttons row (P15 low)
ldh a,[rP1] x6                  ; read six times (settle)
cpl ; and $0f ; or b ; ld c,a   ; combine -> c = full button state
ldh a,[$ff80] ; xor c ; and c   ; pressed = cur AND NOT prev
ldh [$ff81],a                   ; $FF81 = newly pressed THIS frame
ld a,c ; ldh [$ff80],a          ; $FF80 = currently held
ld a,$30 ; ldh [rP1],a ; ret    ; deselect
```

## Button bitfield (both `$FF80` and `$FF81`)
**[FACT]** active-high; derived from the read above:

| bit | mask | button |
|-----|------|--------|
| 0 | $01 | A |
| 1 | $02 | B |
| 2 | $04 | Select |
| 3 | $08 | Start |
| 4 | $10 | Right |
| 5 | $20 | Left |
| 6 | $40 | Up |
| 7 | $80 | Down |

(Confirmed consistent: main-loop attract logic tests `$FF80` bit3 = Start to leave demo.)

## Variables
| Addr  | Meaning |
|-------|---------|
| $FF80 | **[FACT]** held buttons (current frame), bit layout above |
| $FF81 | **[FACT]** newly-pressed buttons this frame (edge: held & ~prevHeld) |

There is **no separate "released" bitfield**; release is detectable as
`prev & ~cur` but the game only stores held + pressed.

## Port implications (Watara Supervision)
- Supervision input is read from its own controller register (memory-mapped on the
  65C02 bus), with **6 buttons**: D-pad (4), B1/B2 (A/B), Select, Start — actually
  the SV pad has Up/Down/Left/Right + B1 + B2 + Select + Start (8 inputs), a clean
  1-1 match to the GB's 8. Map: A→B1, B→B2, the rest identically. (Verify exact SV
  controller register + bit order in the target-hardware doc, Phase 4.)
- Reproduce the same `held` + `pressed` derivation so all game logic that reads
  `$FF80`/`$FF81` ports unchanged in behavior.

## TODO
- [ ] Find all readers of `$FF80`/`$FF81` to confirm no other input state exists.
- [ ] Confirm Supervision controller register/bit order (target doc).
