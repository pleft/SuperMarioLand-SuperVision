# Disassembly & Build (Phase 1) — VERIFIED GROUND TRUTH

## Status: ✓ Reassembles byte-identical to the original ROM.

## Toolchain (installed 2026-06-27)
- **RGBDS v1.0.1** (`rgbasm`/`rgblink`/`rgbfix`) — GB assembler/linker. Homebrew.
- **cc65 v2.18** (`ca65`/`ld65`) — 65C02 target toolchain (for the port phase).
- **mgbdis v3.0** (`tools/mgbdis.py` + `tools/instruction_set.py`) — GB disassembler.
  Deps: `pypng`. Needs `tools/hardware.inc` beside it. From github.com/mattcurrie/mgbdis (MIT).

## How the disassembly was produced
```
python3 tools/mgbdis.py super-mario-land-gb.gb --output-dir disasm --overwrite
```
Output (all gitignored — contains verbatim ROM bytes, see rule 5):
- `disasm/game.asm`      — top-level, INCLUDEs hardware.inc + the 4 banks
- `disasm/bank_000.asm`  — bank 00 (fixed,    $0000–$3FFF)
- `disasm/bank_001.asm`  — bank 01 (switched, $4000–$7FFF)
- `disasm/bank_002.asm`  — bank 02
- `disasm/bank_003.asm`  — bank 03
- `disasm/hardware.inc`  — GB hardware register defs
- `disasm/Makefile`

## How to rebuild + verify (the regression test for all RE work)
```
cd disasm && make
# rebuilt game.gb must satisfy:
#   SHA1 = 418203621b887caa090215d97e3f509b79affd3e
cmp disasm/game.gb super-mario-land-gb.gb   # must be silent (identical)
```
**Invariant:** Until the porting phase, every annotation/rename to the disassembly
MUST keep this rebuild byte-identical. Renaming labels is safe; changing bytes is not.

## Notes
- mgbdis is purely mechanical — it disassembles the actual opcode bytes and emits
  raw `db` for data regions. No semantic guessing (satisfies rules 1 & 2). All
  reverse-engineering meaning is added by hand on top of this ground truth.
- Disassembly is ~55,550 lines across the 4 banks.
