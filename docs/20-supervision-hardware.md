# Watara Supervision — Hardware Reference (Phase 4)

Target platform for the port. Sources: kevtris Supervision_Tech.txt,
github.com/GrenderG/supervision_reveng_notes, MAME/Potator. All [PRIMARY-SOURCED].

## CPU
- **WDC 65C02 @ 4 MHz.** 8-bit A/X/Y, 8-bit status P, 16-bit PC, 8-bit SP (stack
  fixed at `$0100–$01FF`). Zero page `$0000–$00FF` (fast addressing).
- NOT binary-compatible with the GB LR35902 → all game logic is reimplemented.

## Memory map
| Range | Size | Purpose |
|-------|------|---------|
| `$0000–$1FFF` | 8K | **WRAM** (work RAM; zero page + stack live here) |
| `$2000–$202F` | 48B | **I/O registers** |
| `$4000–$5FFF` | 8K | **VRAM** (the LCD framebuffer; 0 wait states) |
| `$8000–$BFFF` | 16K | **banked cartridge ROM** (bank via System Control) |
| `$C000–$FFFF` | 16K | **fixed cartridge ROM** = the last 16K bank |
- Cartridge ROM up to **128K** (8 × 16K banks). 65C02 vectors (NMI/RESET/IRQ) at
  `$FFFA–$FFFF` → live in the fixed bank.
- **Bank switching**: System Control `$2026` bits 7–5 (3 bits) select which 16K bank
  appears at `$8000–$BFFF`.

## Video (LCD)
- **160×160, 2 bpp** (4 grey levels). Framebuffer in VRAM `$4000–$5FFF`.
- **Pixel packing**: 2 bits/pixel, little-end within a byte — bits 1:0 = pixel 0,
  bits 3:2 = pixel 1, … → **4 pixels/byte**. NOTE: this 2bpp packing is *linear*,
  unlike the GB's planar 2bpp tiles — conversion needed (see `21-port-mapping.md`).
- **VRAM line STRIDE = `$30` (48 bytes/scanline)**, of which the first **40 bytes
  (160 px) are visible** and 8 are off-screen (used by X_Scroll's byte offset).
  Full 160-line framebuffer = 160 × 48 = **7680 bytes (`$1E00`)**, `$4000–$5DFF`.
  **[VERIFIED empirically]** in MAME + Potator: filling only 40 bytes/line (6400 total)
  left the bottom ~27 lines blank — the `Y_Scroll × $30` hint is literal (stride $30).
  Uniform 2bpp shade bytes: `$00`=lightest, `$55`, `$AA`, `$FF`=darkest.
- Greyscale is achieved by **two interlaced fields** (alternating bit-planes) per frame.
- Registers:
  - `$2000` LCD_X_Size (horiz pixels, upper bits, 4-px align), `$2001` LCD_Y_Size.
  - `$2002` **X_Scroll** (bits7:2 = byte offset/scanline; bits1:0 = 0–3 px delay).
  - `$2003` **Y_Scroll** (×`$30`, added to VRAM start → vertical scroll).
  - `$2026` **System Control** bits (VERIFIED from Potator source): bit0 = NMI enable,
    bit1 = timer-IRQ enable, bit2 = DMA-IRQ enable, bit4 = timer prescaler, bits7:5 = bank.
    (There is no display-enable bit in Potator.)
  - `$2008–$200D` = **VRAM DMA** (src lo/hi, dst lo/hi, len×16, ctrl bit7=start) — fast
    block copy. In Potator it's `vram[dst+i] = cpubus[src+i]` (direction = dst-hi bit6),
    a CLEAN LINEAR copy: to shift the strided framebuffer horizontally, shift PER-LINE or
    only over already-refilled rows, else a linear shift bleeds across scanlines. ~0 cost.
- Frame ≈ **78,720 cycles, ~50.8 fps** (LCD); but see NMI timing below.

## Sound
- **2 square channels** `$2010–$2017` (CH1 right, CH2 left): freq lo/hi (11-bit),
  vol/duty (`$x012`: bit6 enable, bits5:4 duty {12.5/25/50/75%}, bits3:0 volume),
  length. **Freq = 125000/(F+1) Hz**.
- **DMA audio** `$2018–$201C`: plays a sample stream from ROM (addr, len×16, bank +
  L/R + sample-rate in ctrl, trigger bit7). Good for the GB **wave channel** / PCM.
- **Noise** `$2028–$202A`: 4-bit freq + 4-bit vol, length, 15-bit (or 7-bit) LFSR.
- Mirrors at `$2004–$2007`, `$202C–$202E`.

## Input — controller `$2020` (active-LOW: pressed = 0)
| bit | 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
|-----|---|---|---|---|---|---|---|---|
| btn | Start | Select | A | B | Up | Down | Left | Right |

## Interrupts & timing
- **NMI** every **65536 clocks ≈ 61.04 Hz** (independent of LCD) — enable via `$2026`
  **bit0**. This is the natural **per-frame tick** (≈ the GB's 60 Hz VBlank).
- **IRQ timer** `$2023` (downcounter; write loads period = data×`$100`, or ×`$4000` if
  `$2026` bit4 set). Enable via `$2026` **bit1**. `$2024` read clears it. WORKS in Potator.
  NOTE: Potator renders the whole frame in one batch AFTER running a frame of CPU, so a
  mid-frame XSCROLL change (raster split, e.g. a pinned HUD during smooth scroll) has no
  effect without patching its render loop. No beam-racing either (frame drawn atomically).
- **IRQ status** `$2027`: bit0 timer expired, bit1 DMA-audio done. `$2025` clears DMA IRQ.
- Link port `$2021/$2022` (unused for this port).

## Key implications vs Game Boy
- WRAM is **8K** (`$0000–$1FFF`) vs GB's 8K (`$C000–$DFFF`) — same size, different base.
- ROM banking is **16K** windows (like GB), selected by `$2026` bits7:5 instead of a
  GB MBC `$2000` write.
- **No PPU**: no hardware tiles/sprites/BG-map. The framebuffer must be drawn in
  software (CPU/VRAM-DMA) each frame. This is the single biggest port effort.
- **No LYC/STAT raster interrupt** → the GB status-bar split is done differently
  (fixed top region, no mid-frame scroll trick needed since scroll is per-frame).
- 4-grey output matches the GB's 4 shades (palette → SV grey levels directly).

## Scrolling capability — empirical findings (Potator 1.0.5, RetroArch)
Tested 2026-06-28 with throwaway striped-pattern ROMs (since removed):
1. **Timer IRQ ($2023/$2024) does NOT fire under Potator** — neither the down-counter
   nor the documented "write 0 → instant IRQ" produced any IRQ (handler never ran).
2. **XSCROLL ($2002) is latched ONCE PER FRAME, not per scanline** — a tight loop
   sweeping XSCROLL produced uniform vertical stripes sliding sideways (frame-to-frame),
   never a diagonal/sheared (per-scanline) pattern.
=> **No raster split is possible on this target.** The GB keeps its status bar fixed
   during a smooth 1px scroll via a per-scanline STAT/SCX split; that cannot be
   reproduced here. Consequences for the port:
   - Smooth (1px) scroll via XSCROLL shifts the WHOLE screen including the HUD.
   - Keeping the HUD pixel-fixed therefore needs a per-frame HUD redraw, which overruns
     vblank and beam-races (visible tearing/shake). NOT viable.
   - **Practical ceiling = byte-aligned 4px-step scroll** (XSCROLL bits7:2 only): HUD
     redrawn cheaply only on a 4px change (fits vblank), world scrolls in 4px steps.
   - Finer than 4px would require shifting the framebuffer in <4px units, which the
     VRAM-DMA (byte = 4px granular) can't do and a per-frame software bit-shift is far
     too slow for.
