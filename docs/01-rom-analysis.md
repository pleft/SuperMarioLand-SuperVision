# ROM Analysis — Cartridge Header

Source: `super-mario-land-gb.gb`. All offsets are file offsets (== address in
banks 0/00 for the header region).

## Identity
- SHA1: `418203621b887caa090215d97e3f509b79affd3e`
- MD5:  `b259feb41811c7e4e1dc200167985c84`
- Size: 65536 bytes = 64 KB = 4 × 16 KB banks.

## Header fields (0x100–0x14F)
| Offset      | Bytes              | Meaning |
|-------------|--------------------|---------|
| 0x100–0x103 | `00 C3 50 01`      | Entry point: `nop` ; `jp $0150` |
| 0x104–0x133 | Nintendo logo      | `CE ED 66 66 ...` (standard) |
| 0x134–0x143 | `SUPER MARIOLAND`  | Title (padded with 00) |
| 0x143       | `00`               | CGB flag = 00 (DMG only, not Color) |
| 0x144–0x145 | `00 00`            | New licensee code |
| 0x146       | `00`               | SGB flag = 00 (no Super Game Boy features) |
| 0x147       | `01`               | **Cartridge type = MBC1** |
| 0x148       | `01`               | **ROM size = 64 KB (4 banks)** |
| 0x149       | `00`               | RAM size = none |
| 0x14A       | `00`               | Destination = Japanese? (00) — verify vs World |
| 0x14B       | `01`               | Old licensee = 01 (Nintendo) |
| 0x14C       | `01`               | Mask ROM version |
| 0x14D       | `9D`               | Header checksum |
| 0x14E–0x14F | `5E CF`*           | Global checksum (verify byte order) |

\* Re-verify 0x14E/0x14F exact bytes during disassembly.

## Implications for disassembly
- **MBC1, 4 banks, no RAM.** Banks: 00 (fixed, 0x0000–0x3FFF) + 01,02,03
  (switchable at 0x4000–0x7FFF). With only 4 banks, MBC1 bank switching is simple
  (no mode-1 RAM banking relevant here since RAM size = 0).
- Entry jumps to `$0150` (just past the header) — standard.

## Open questions / to verify
- [ ] Confirm exact global checksum bytes and that the ROM is unmodified Rev 0.
- [ ] Confirm interrupt/restart vector usage (0x00–0xFF) once disassembled.
- [ ] Map which banks hold code vs data (graphics/levels/sound).
