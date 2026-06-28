# Super Mario Land → Watara Supervision Port — Overview

## Goal
Disassemble and reverse-engineer the Game Boy ROM *Super Mario Land*, then port it
to the **Watara Supervision** as a **1-to-1 identical port** (same gameplay,
graphics, levels, timing, audio behavior).

## Working rules (from the project owner)
1. **Always RE and read the sources.** Every claim must trace back to actual ROM
   bytes / disassembled code. No guessing from memory of the game.
2. **Do not improvise.** If something is unknown, mark it UNKNOWN and investigate;
   do not invent behavior.
3. **Target a 1-1 identical port.** Reuse the exact game data; reproduce logic
   faithfully.
4. **Always document progress and findings** (this docs/ tree + PROGRESS.md).
5. **Never ship copyrighted/licensed material.** The repository must NOT contain
   extracted graphics, music, level data, or any ROM-derived content. Instead
   ship **extraction scripts** that read the user's own legally-owned
   `super-mario-land-gb.gb` and emit the data needed to build the Watara ROM at
   build time. Original ROM, disassembly bytes, and extracted assets stay
   out of version control (see `.gitignore`).

## Source ROM
- File: `super-mario-land-gb.gb`
- Size: 65536 bytes (64 KB)
- SHA1: `418203621b887caa090215d97e3f509b79affd3e`
- MD5: `b259feb41811c7e4e1dc200167985c84`
- Identified: *Super Mario Land (World)* — see `01-rom-analysis.md`.

## The core architectural challenge
The Game Boy and the Watara Supervision are **not** binary-compatible. A literal
byte-for-byte port is impossible; "1-1" must mean **behaviorally identical**.

| Aspect      | Game Boy (source)                | Watara Supervision (target)        |
|-------------|----------------------------------|------------------------------------|
| CPU         | Sharp LR35902 (Z80/8080-like)    | WDC 65C02 (6502 family)            |
| Screen      | 160×144, 4 shades                | 160×160, 4 shades                  |
| Graphics    | Tile/BG maps + OAM sprites (PPU) | Linear-ish bitmap framebuffer + LCD controller |
| Sound       | 4-channel APU (2 pulse,wave,noise)| 4-channel (2 pulse, 1 noise/DMA)  |
| Memory map  | MBC1 banked                      | flat + bankswitch (cart dependent) |

### What "1-1 port" therefore means in practice
- **Reusable as-is (data):** level maps, tile graphics, sprite graphics, object
  tables, palettes-as-shades, music/sound data — the *content*.
- **Must be reimplemented (code):** all CPU logic must be rewritten in 65C02
  assembly, because the instruction sets are disjoint. The reimplementation must
  reproduce the LR35902 game logic faithfully (same algorithms, same constants).
- **Must be re-targeted (hardware I/O):** the PPU/OAM rendering model and APU
  must be mapped onto the Supervision's framebuffer LCD and sound hardware.

## Build pipeline (consequence of rule 5)
The user supplies their own `super-mario-land-gb.gb`. The build does:

```
super-mario-land-gb.gb  (user-supplied, gitignored)
        │
        ▼  extraction scripts (shipped, in tools/)
   neutral data files  (graphics, levels, tables, sound — gitignored, build artifacts)
        │
        ▼  converters → Supervision-native formats
   port source (65C02 asm, shipped) + converted data
        │
        ▼  ca65/ld65 assembler+linker
   super-mario-land.sv  (Watara Supervision ROM — build output)
```

Only the **scripts and hand-written port source** live in the repo. No
ROM-derived bytes are committed. A build verifies the input ROM's SHA1 first.

## Phased plan (high level)
1. **Disassembly** — produce a complete, reassembling RGBDS disassembly of the ROM
   that rebuilds to a byte-identical `.gb`. This is the ground truth.
2. **Reverse engineering** — annotate the disassembly: name routines, RAM
   variables, data tables; document subsystems (player, physics, enemies, level
   loading, rendering, sound, input).
3. **Extract data** — pull out graphics/levels/tables in a platform-neutral form.
4. **Target study** — document the Supervision hardware precisely (CPU, video,
   sound, memory map, input) from primary sources.
5. **Port** — reimplement subsystems on the 65C02, reusing extracted data,
   verifying behavior against the original at each step.

See `PROGRESS.md` for the running log and current status.
