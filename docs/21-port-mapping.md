# Game Boy → Watara Supervision — Port Mapping (Phase 4→5 bridge)

How each reverse-engineered GB subsystem (docs/02–13) maps onto the Supervision
hardware (docs/20). "1-1" = behaviorally identical: reuse extracted DATA, reimplement
LOGIC on 65C02, re-target HARDWARE I/O.

## CPU / logic
- **LR35902 → 65C02**: reimplement every routine in 65C02 asm (ca65). The control
  flow, state machine (`$FFB3` 62-state table), and all constants we documented port
  directly; only the instruction encoding changes. No 16-bit regs on 65C02 → use
  zero-page pairs + X/Y for what GB did with HL/DE/BC.
- GB RAM variables → relocate into SV WRAM `$0000–$1FFF`. GB **HRAM** ($FF80+) hot
  vars (input `$FF80/81`, frame flag `$FF85`, state `$FFB3`, …) → **zero page** (fast).

## Memory & banking
| GB | Supervision |
|----|-------------|
| WRAM `$C000–$DFFF` (8K) | WRAM `$0000–$1FFF` (8K) — rebase all addresses |
| HRAM `$FF80–$FFFE` | zero page `$00xx` |
| OAM shadow `$C000` | a WRAM sprite list (software-rendered, no HW OAM) |
| ROM bank reg `$2000` (MBC1) | System Control `$2026` bits 7:5 |
| 4×16K ROM banks (bank 0 fixed) | SV: bank 0 → `$C000` fixed bank; banks 1–3 via `$8000` window |
- The GB's 64K (4 banks) fits SV's 128K cart easily. Keep bank 0 as SV's fixed bank;
  map GB banks 1/2/3 into the switchable `$8000–$BFFF` window via `$2026`.

## Video — the biggest job (GB PPU → SV framebuffer)
GB has tiles + BG maps + hardware OAM sprites + per-frame VBlank VRAM writes. SV has a
**linear 2bpp framebuffer** only. So we **software-render** each frame:
- **Tiles**: GB 2bpp is *planar* (2 bytes/row, bit-plane interleaved). SV 2bpp is
  *linear* (4 px/byte, bits1:0=px0…). → convert tile graphics at build time (extend
  `extract_gfx.py`) into SV-packed tiles, OR convert on the fly. Both are 4-grey, so
  pixel values map 1-1.
- **Background**: instead of a HW tilemap + scroll, blit the visible tile columns into
  VRAM. We already RE'd the column-stream model (`LevelColumnStream`, `$C0B0` buffer) —
  reuse it: as the level scrolls, blit new 8-px columns into the framebuffer and use
  SV **X_Scroll `$2002`** for the fine/byte scroll (mirrors the GB SCX approach).
- **Sprites**: software-blit the shadow-OAM sprite list (`$C000`, 40×4) into the
  framebuffer each frame (with transparency). Mario, enemies, etc.
- **Status bar**: GB used an LYC/STAT raster split to freeze the top rows. SV: render
  the status bar into the **top scanlines** of VRAM and simply don't apply the scroll
  to them (Y_Scroll affects the playfield region) — no raster interrupt needed.
- **Screen size**: GB 160×144 → SV 160×160. Use the **16 extra rows** for the status
  bar (or letterbox). Width matches exactly (160).
- **VRAM DMA `$2008–$200D`** accelerates column/sprite blits.

## Sound (GB APU → SV sound)
| GB channel | SV target |
|-----------|-----------|
| Pulse 1 (NR10-14, sweep) | Square CH1/CH2 (`$2010`/`$2014`). Convert pitch: GB `f=131072/(2048-x)` → SV `f=125000/(F+1)` → `F = 125000/f − 1`. |
| Pulse 2 (NR21-24) | the other square channel |
| Wave (NR30-34, 32-sample) | DMA-audio (`$2018`) streaming the wave data as PCM, or approximate |
| Noise (NR41-44, LFSR) | Noise channel (`$2028`) |
- Reuse our decoded **music format** (song table `$663C`, order/pattern/note bytecode,
  freq table `$6E74`) — `extract_music.py` already pulls it. The driver is reimplemented
  on 65C02; per-note it converts GB-freq → SV-`F` and writes the SV channel regs.
- 4 GB channels vs SV's 3 tonal + DMA: pulse×2 and noise map cleanly; the GB wave
  channel uses SV DMA-audio (revisit fidelity in the port).

## Input (GB joypad → SV controller)
Both read once per frame; produce the same `held`/`pressed` bitfields the game logic
expects (`$FF80`/`$FF81`). Bit remap (GB→SV `$2020`, active-LOW):
| Button | GB bit | SV bit |
|--------|--------|--------|
| A | 0 | 5 |
| B | 1 | 4 |
| Select | 2 | 6 |
| Start | 3 | 7 |
| Right | 4 | 0 |
| Left | 5 | 1 |
| Up | 6 | 2 |
| Down | 7 | 3 |
- Read `$2020`, invert (SV is active-low), reorder bits to the GB layout, then the
  existing held/pressed derivation runs unchanged.

## Timing
- GB 60 Hz VBlank → SV **NMI ≈ 61.04 Hz** (`$2026` bit4). Use NMI as the per-frame
  tick: it replaces the GB VBlank ISR (run the draw/commit chain, set the frame flag,
  do OAM→framebuffer blit). Close enough for 1-1 feel; can fine-tune with the IRQ timer.
- The GB VBlank rendering chain (docs/06) becomes the NMI handler's blit sequence.

## Build pipeline (ties to rule 5)
```
user ROM ──extract_*.py──▶ neutral data (levels/gfx/music)  ──converters──▶ SV-format data
                                                                                  │
                hand-written 65C02 port source (ca65) ──────────────────────────┤
                                                                                  ▼
                                                          ca65/ld65 ──▶ super-mario-land.sv
```

## Open items for Phase 5 (port)
- [ ] Confirm exact SV LCD field/greyscale handling vs our 4 GB shades.
- [ ] Decide tile conversion: build-time (preferred) planar→linear repack.
- [ ] Map the GB wave channel onto SV DMA-audio precisely.
- [ ] 65C02 reimplementation order: boot → input → frame loop → renderer → player →
      level stream → enemies → sound (mirror the RE order).
