# Sound Engine (Task #7) — framework

Verified from code. GB APU = 4 channels: pulse1 (+sweep) NR10-14, pulse2 NR21-24,
wave NR30-34, noise NR41-44, control NR50-52.

## Request → driver → APU
Game code requests sound by writing an ID to **request variables**, then the
per-frame **SoundDriver** consumes them and updates the APU via the bank-3 channel
engine.

### Request variables (written by game logic)
| Var | Role |
|-----|------|
| **`$DFE0`** | SFX request id (e.g. jump sets `$DFE0=1`; block-hit, coin, etc.) |
| **`$DFE8`** | music (BGM) request id |
| `$FFED`     | SFX/state flag used by the bank-2 SFX path |
| `$DFE1`     | current sound/priority state |

### Driver: `SoundDriver` @ `02:5844` (bank 2, called each frame from gameplay states)
1. `GameTimerUpdate` ($584B) — decrements the **BCD game timer `$DA00–$DA02`**;
   on expiry sets **`$DA1D`** (time-up → death trigger). (Note: `$DA00` is the
   TIMER, not coins — corrects the earlier guess in `docs/06`.)
2. `SoundUpdate_5892` ($5892) — per-frame SFX/channel state update (uses `$FFED`,
   a ring buffer via `$DA0B`, per-channel state `$DA03–$DA0E`).
3. cross-bank into **`SoundChannelEngine_6ECD`** (bank 3) for the actual APU writes.

### Channel engine (bank 3, ~`$67xx–$6Exx`)
Per-channel update routines that write the NR registers from note data:
- pulse1: `NR10/12/14` (+ sweep), pulse2: `NR21/22/24`, wave: `NR30/32/34`,
  noise: `NR41/42/44`, panning/volume: `NR51/NR50`.
- Channel working state in the **`$DF00–$DFFF`** region: current data pointer
  (`$DFE4/$DFE5`), per-channel flags (`$DF1F`, bit7 = active), etc.
- Note/sequence data pointers live in bank 3 (e.g. `$6787`, `$678C`).

## Music/SFX data structure (task #13 progress)
- **SFX sequences** live in **bank 3** (`$6787`, `$68FD`, `$6902`, `$6907`, … — short
  per-effect note lists). **Music (BGM)** sequences live in **bank 2** (e.g. `$860A`).
- A channel is started by **`Call_003_69C6`** (priority in `A`, data pointer in `HL`):
  it writes a per-channel **state block** in the `$DF00–$DFFF` region (current data
  pointer `$DFE4/$DFE5`, priority, flags). Up to ~5 logical channels (the `cp $E5/$F5/
  $FD` on the state address selects channel slots).
- Per frame, the bank-3 channel-update routines read the next sequence byte(s),
  advance the pointer, and write the NR registers — pitch via a **frequency table at
  `$6ECD`** (data, not code).
- `$69C6` = channel initializer; the per-frame readers (`$67xx–$69xx`) consume the
  note bytecode.

## Live capture (mGBA/SameBoy, World 1-1 overworld theme)
Validated against the running game (watchpoints on `rNR13/rNR14`):
- **5 channel state blocks**: `$DF00, $DF10, $DF20, $DF30, $DF40` (16 bytes each).
  Layout (from the live dump of `$DF10`): `+4/+5` = **current sequence data pointer**,
  `+0/+1` = **loop/base pointer**, `+9/+0A` = cached note freq (lo/hi), `+8` = trigger.
- The playing channel had base=`$76EF`, current=`$7794` → its note data is in **bank 3**.
- **`NoteFreqTable_6ECD`** is the note→11-bit-GB-frequency table. CONFIRMED: a sequence
  byte `$A7` produced `rNR13=$A7, rNR14=$87` (freq `$07A7`) = table index 10. So the
  `$Ax` sequence bytes select notes from this table.
- Note output (`$6DA0`): `ld a,[hl]; or $80; ldh [c],a` — writes `NR13` then `NR14`
  with the `$80` trigger, from the cached freq in the channel block.
- Sequence fetch: `Call_003_6C30` advances a channel's 16-bit data pointer; `$6C45`
  dereferences it. Channel data starts with a small header/sub-table at the base
  pointer, then raw note/duration bytes (e.g. at `$7794`: `4A 01 4A A5 01 A6 01 A1 …`).

## Music data format — FULLY DECODED (task #13)
Four-level hierarchy, all in bank 3. Extractor: `tools/extract_music.py` (parses all 19 songs).

1. **Song table @ `$663C`** — music id (1–19) → song-header pointer. Index = `(id-1)*2`.
   (Live: id read from `$DFE8`, must be `< $14`.) Selector routine `Call_003_6AB5`.
2. **Song header** — `1 flag byte` + **5 channel order-list pointers** (channels:
   master, pulse1, pulse2, wave, noise). Parsed by `Call_003_6B8C` into blocks `$DF00…$DF40`.
3. **Channel order list** — sequence of **2-byte pattern pointers**; `$FFFF` then a
   2-byte **loop target** (an order address) = loop.
4. **Pattern** — note/command byte stream (interpreter dispatch at `$6CD7`):
   | Byte | Meaning |
   |------|---------|
   | `$00` | end of pattern → advance order list |
   | `$01` | rest / tie |
   | `$9D aa bb cc` | command (instrument / note-base / envelope → NR regs) |
   | `$A0–$AF` + dur | **scale-degree note** (low nibble = degree via note-base ptr `$DF01/2`), then a duration byte |
   | other | **direct-frequency note** — byte indexes the freq table at **`$6E74`** → 11-bit GB frequency |

### Frequency tables
- **`$6E74`** = master note-frequency table (byte value → 11-bit GB period/freq). Verified:
  byte `$52` → `$739` → 659 Hz (E5); `$58` → 785 Hz (G5). LIVE-confirmed earlier: `$A7`→`$07A7`.
- **`NoteFreqTable_6ECD`** = a slice of `$6E74` (offset `$59`), used as a scale base for `$Ax` notes.

## Status
- ✅ **COMPLETE.** Framework + full data format decoded, live-validated, and a working
  extractor (`tools/extract_music.py`) parses all 19 songs into songs→channels→
  order-lists→patterns with resolved note frequencies. Minor open nuance: exact
  duration handling for `$Ax` vs direct notes and the `$9D` command sub-types (the raw
  bytes are all captured faithfully, which suffices for the 1-1 port / rule-5 reuse).
- ⏳ REMAINING (task #13, the last deep decode; unblocks music extraction #11):
  fully decode the **note-sequence bytecode** — the exact per-byte semantics the
  channel readers interpret (note on + pitch index → `$6ECD`, duration, rest, tempo,
  loop/jump, envelope/volume, end). **Recommended:** validate with an emulator —
  load known SML music, log writes to the NR registers + the channel data pointer per
  frame, and correlate to the sequence bytes (same approach that cracked the jump arc).
  Then write `tools/extract_music.py` and refine the per-world gfx (task #11).

## For the port (Watara Supervision)
The SV sound hardware differs (2 pulse + 1 noise/DMA, no GB wave channel exactly).
Reproduce the request→driver→channel model and the note data 1-1 where the SV APU
allows; the GB wave channel + exact envelopes map onto the closest SV equivalents
(revisit in the port phase — the *data* and *sequencing logic* are what we keep).
