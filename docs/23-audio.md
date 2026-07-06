# 23 — Audio: the SML sound engine RE and the SV port

(Reconstructed: the first version of this file was committed empty — a `cat`
heredoc that never received its body. Lesson logged at the bottom.)

Rule 5 reminder: this file documents FORMATS and ADDRESSES, never content.
All extracted audio data lives in gitignored `build/audio/`, produced at build
time from the user's own ROM by `tools/extract_sfx.py` / `tools/extract_music.py`.

## 1. The GB engine (bank 3, timer-IRQ driven)

- Timer ISR: TAC=$07 (16384 Hz), TMA=0 → overflow every 256 counts = **64 Hz**.
  Everything below "per tick" means 64 Hz.
- Entry: bank3 `$7FF0` → main tick `$6662`. Order per tick: pause handling,
  effect mailboxes, `MusicStart_6AB5`, the sequencer walk `$6CBE`, echo `$6B09`.
- Four request mailboxes, consumed the same tick (polling them from outside
  races and lies — hook the handlers instead):
  - `$dfe0` square effects, `$dfe8` music/jingles, `$dff0` wave effects,
    `$dff8` noise effects. `$dfe9` = the live music id, `$dfe8=$10` = stop.
- Channel ownership flags `$df1f/$df2f/$df3f/$df4f` bit7: an active EFFECT owns
  the channel; the music skips its register writes there and resumes after.
- Pause (`$ffdf`=1 enter, 2 leave): enter = full APU/driver reset call `$6A54`,
  mailboxes cleared, `$ffde=$30`. While `$ffde`>0 the sequencer is FROZEN and
  `$ffde` counts down, playing the pause ding-dong at values $28/$20/$18/$10
  (note structs at `$66EE/$66F2`). Leave: `$ffde=0`, sequence resumes where it
  stopped. (The port mirrors this minus the ding-dong: freeze + silence.)

## 2. The complete 1-1 sound map (all user-verified by ear via the title-screen sound test)

| mailbox | value | sound | port hook |
|---|---|---|---|
| $dfe0 | $01 | jump | @startjump |
| $dfe0 | $02 | superball throw | try_fire |
| $dfe0 | $03 | stomp | award_stomp |
| $dfe0 | $04 | powerup pickup (mushroom eaten / flower) | grow + superball grant |
| $dfe0 | $05 | coin | award_coin |
| $dfe0 | $06 | shrink (big Mario hit) | hurt_mario big branch |
| $dfe0 | $07 | block thud (unbreakable bonk) | solid bonk + small-Mario brick |
| $dfe0 | $08 | 1UP | add_life_snd |
| $dfe0 | $0A | goal-tally tick ($0CB6: fires when the ones bit0 is clear) | goal_seq @tally |
| $dfe0 | $0B | item emerge from block | spawn_item_snd |
| $dff0 | $01 | wave effect, not a 1-1 action | UNHOOKED (revisit multi-level) |
| $dff8 | $01 | Nokobon explosion | upd_bomb |
| $dff8 | $02 | brick smash (noise shards) | break_brick |
| $dff8 | $03 | fly (Goombo) death | enemy_contact type 4 |
| $dfe8 | $02 | death jingle | @die / pit / time-up |
| $dfe8 | $04 | underground room music | extracted, UNWIRED |
| $dfe8 | $07 | 1-1 LEVEL MUSIC | mus_start at level start/respawn |
| $dfe8 | $0C | star music | extracted, UNWIRED |
| $dfe8 | $0F | goal fanfare (one-shot) | goal_check |
| $dfe8 | $11 | NOT hurry-up: written by routine $12F1 when $dfe9==0 (context unidentified) | extracted, UNWIRED |
| $dfe8 | $12 | bonus game music | extracted, UNWIRED |
| $dfe8 | $10 | stop music | (port: mus_stop) |

Level→track table: bank0 `$07CE`.

## 3. SFX: capture + stream replay (`tools/extract_sfx.py`)

NR13/14 are WRITE-ONLY: state sampling cannot recover pitch. The extractor
scans bank3 for `ldh [c],a` / `ldh [n],a` write sites, hooks them all in PyBoy
(`hook_register` + `register_file.A/.C`), triggers each effect via its mailbox,
and logs every APU write. Off-line it then SIMULATES the four hardware
behaviors a write log doesn't show — envelope (64 Hz), sweep (128 Hz/period,
ch1 only), length counter (256 Hz, armed only by retrigger/NRx1 reload), duty —
and re-encodes the audible result as SV register streams:
`delay(1) mask(1) payload`, mask b0/b1 = ch1/ch2 full (FLO FHI VOLDUTY),
b2 = noise (FREQVOL), b4/b5 = vol-only rows; delay $FF = end; delay 0 = same
frame. Jingles capture tonal channels only (owned={1,2,3}) — the "drums" in a
captured jingle are the silenced level music's percussion still being serviced.
The 3 GB tonal voices reduce to 2 SV squares by dropping onset-rhythm
doublings first (wave preferred), then energy rank. Noise volume ×0.5 is the
single non-RE mix decision. `sfx_chmask` (per-effect channel claims) is
emitted so the port can arbitrate against music up-front, like the GB's
ownership flags.

Conversions: square hz = 131072/(2048−X); wave = 65536/(2048−X);
noise = 262144/(r·2^(s+1)), r=0 → 0.5. SV tone F = 125000/hz − 1 (11-bit);
SV noise N minimizes |4e6/(8<<N) − gbfreq|.

## 4. The MUSIC: sequence-engine port (this is the big one)

Stream-looping was measured unfit (the "949-frame loop that diverges" — see
§4.3 for why), so the port interprets the ORIGINAL's sequence data directly.

### 4.1 Format (RE'd from `MusicStart_6AB5` + walker `$6CBE`, bytes verified)

- `SongTable_663C[track-1]` → song header:
  `[b0] [len-table ptr → $df01/02] [ch1 list] [ch2 list] [ch3 list] [ch4 list]`
- Per-song attribute table `$6B2F + (id-1)*4`: `[$ffd8, $ffd6, NR51 pan, $ffda]`
  (echo/pan config; not needed for the port's 2-square mapping).
- A channel is a **list of 2-byte phrase pointers**. Control by entry HI byte
  (handler `$6C7F`): `$FFxx` = the next word is a list address to JUMP to
  (the loop point — track 7 loops to entry 2, entry 1 is a play-once intro);
  `$00xx` = END → `$6CB1` stops the WHOLE song (so an unterminated sibling
  list, e.g. track $0F ch2, is normal: ch1's stop kills it first).
- Phrase bytes:
  - `$00` — next phrase from the list
  - `$01` — hold cell (no retrigger; the running envelope continues)
  - `$9D e d c` — instrument: e = GB NRx2 envelope (vvvv d ppp), d = never
    seen in any register write (unknown, unused), c = GB NRx1 (bits 7:6 duty)
  - `$A0-$AF` — cell length := len-table[x], in 64 Hz ticks (track 7's table:
    2,4,8,16,32,64,12,24,48,5,10,1,0,5,10,20)
  - even bytes ≤ $98 — note: the byte indexes `NoteFreqTable_6E74` (2B LE,
    byte-addressed); write freq + retrigger; consumes one cell
- Noise channel (ch4): note indexes 5-byte drum structs at `$6F06` (not yet
  ported; drums also self-randomize via rDIV — why captures never loop).
- Duration = cell length; there is NO other timing. Tick = 64 Hz exactly.

### 4.2 Validation (rule 0b)

1. Python decode of the ROM data vs a PyBoy write-log capture of track $07:
   ch2 = 77/77 note events matched in order; frames = ticks × 60/64 within
   ±0.5f (ch1's "misses" are same-pitch retriggers invisible to a freq-change
   comparator). Instrument check: captured NR12/NR11 values = the $9D params.
2. The same decode run on the PORT'S OWN `music.bin` (byte-identical walk to
   the 65C02 player): matches the capture the same way.
3. The built ROM under py65 with APU-write trapping (`tools/verify_music.py`):
   ch1 = 33/33, ch2 = 60/60 note frequencies EXACT, timing within 0.9 frames.

### 4.3 Why stream-looping failed (now explained from first principles)

The loop body is 1017 ticks = 949 frames — the old capture analysis' mystery
"949-frame skeleton". It "diverged after 813 writes" because entry 1 of each
list is an intro phrase the loop never returns to, and the drums re-randomize
per pass. The sequence engine loops perfectly by construction.

### 4.4 The port player (`src/main.s`)

- `tools/extract_music.py` emits `build/audio/music.bin`: SV-converted note
  table (0x98 × 2B, index = GB note byte × 2), then per track: len-table,
  phrase blob, ch1/ch2 lists (16-bit offsets; `$FFFF+target` = jump, `$0000` =
  end). Six tracks: $07 level, $04 underground, $0C star, $0F goal, $11
  hurry-up, $12 bonus ≈ 1.3 KB total.
- `mus_start` (A = MUS_* index) / `mus_stop` / `mus_tick` (every frame + every
  internal wait loop). 64 Hz from the 61 Hz frame by Bresenham (+3/61).
- Two channel state blocks (ZP, stride 12, X=0/12; Y=0/4 selects the SV
  square's registers). Runtime envelope at tick rate = the GB's 64 Hz env
  clock, both directions. Duty: GB bits 7:6 → VOLDUTY bits 5:4 unchanged.
- Arbitration: an active SFX claims channels via `sfx_chmask` at `sfx_play`;
  music advances but skips claimed channels' registers, reclaiming on the next
  env step/note after the stream ends (= the GB ownership-flag design).
- Wiring: level start/respawn/next_level → MUS_LEVEL; death/time-up →
  `mus_stop` + the jingle stream; goal → `mus_stop` + MUS_GOAL (one-shot, ends
  itself); pause → freeze + silence squares, resume on unpause.
- **Hurry-up (RE'd, bank2 $5851)**: SML has NO hurry-up track. At time 100 the
  game sets TMA=$30 (driver ticks 64→78.8 Hz) and at time 050 TMA=$50 (93.1 Hz):
  the SAME tune plays ~23%/~45% faster. TMA resets to 0 at level init, death and
  goal ($0769/$09FD/$0C5D...) so jingles are normal-speed. $da1d = stage 1/2/3
  (3 = time up → the death path at $0226). Port: `mus_rate` = the Bresenham add
  (3/18/32), set in tick_timer at the same BCD boundaries, reset in
  mus_start/mus_stop. (Deviation: the GB speedup also affects SFX timing; the
  port speeds up music only.) Track $11 was previously MISLABELED "hurry-up" —
  its real trigger is routine $12F1 (plays $11 whenever no music is live there;
  context unidentified, likely a later-level auto-scroll sequence).
- **Goal-tally tick (RE'd, $0CB6)**: during the time tally the GB plays
  $dfe0=$0A on every unit whose BCD ones bit0 is clear. Port: hooked in
  goal_seq @tally; the $0A stream is now captured (15 SFX total).
- NOT yet wired: underground ($04, pipe rooms), bonus ($12), star ($0C),
  drums/wave, pause ding-dong.

## 5. SV hardware truths (Potator-source-verified)

- Tone: freq = 125000/(F+1), 11-bit F split FLO/FHI; `CHx_VOLDUTY` bit6
  enable, bits5:4 duty (GB 2-bit duty maps 1:1), bits3:0 volume; the port
  runs continuous mode (LEN=$FF).
- Noise `CH4_CTRL $202A`: **bit4 = ON** (docs elsewhere wrongly say bit3),
  bit3 left, bit2 right, bit1 continuous. Freq = 4 MHz/(8<<N).
- All channels mix at equal raw weight 0-15.

## 6. Hard lessons (each cost a debugging round)

1. Write logs miss hardware behavior: envelope/sweep/length/duty must be
   simulated or the streams are wrong (the "death jingle sucks" era).
2. The length counter counts ONLY when armed (retrigger/NRx1 reload).
3. 0-delay rows apply the SAME frame or multi-channel sounds time-stretch.
4. sfx must tick inside every internal wait loop, or jingles stall mid-phrase.
5. Compare NOTE ONSETS, not raw rows, when detecting doubled voices.
6. A new sfx_play must silence the previous stream's channels (orphaned noise
   drones forever).
7. Mailbox polling races the 64 Hz consumer: hook handlers, not memory.
8. PyBoy captures carry a ~350 Hz drone artifact (ring-buffer boundary
   suspected) — blocks FFT validation of QUIET sounds; loud sounds verify.
9. `cat >> file` without its heredoc body hangs — and worse, an interrupted
   one can leave/commit an EMPTY file. Always `wc -c` a doc after writing it,
   before committing. (This file was lost that way once.)
10. A list terminator can legitimately NOT exist (track $0F ch2) — parse ROM
    structures with boundary sets, not just sentinels.
