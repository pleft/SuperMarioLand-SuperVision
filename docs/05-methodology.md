# RE Methodology — the symbol-file workflow

The disassembler (mgbdis) traces control flow from known entry points (reset/
interrupt vectors, `$0100`). Code reachable **only via computed jumps** (the
`RST_28` jump tables, pointer tables) is NOT auto-traced and appears as `db` data.

We recover it — and accumulate all naming — through a **hand-authored symbol file**.

## The artifact: `symbols/sml.sym` (tracked in git)
This file is our reverse-engineering knowledge: labels + code/data region markings.
It contains NO ROM bytes (just addresses + names), so it is safe to version
control (rule 5). mgbdis auto-loads a file named `super-mario-land-gb.sym` next to
the ROM; we keep the canonical copy at `symbols/sml.sym` and copy it to that name
before disassembling. The working copy `/super-mario-land-gb.sym` is gitignored.

### Format
```
BB:AAAA Label                ; give address AAAA in bank BB a name
BB:AAAA .code:N              ; mark N bytes at AAAA as code (forces disassembly)
BB:AAAA .data:N              ; mark N bytes as data (db)
BB:AAAA .text:N              ; mark N bytes as ASCII
; lines starting with ';' are comments
```
Bank is hex; bank 00 = $0000–$3FFF, banks 01-03 = $4000–$7FFF (their own space).

### ⚠ GOTCHA: no inline comments on symbol lines
mgbdis parses each line as `location, label = line.split()` — exactly **two**
whitespace-separated tokens. Any line with a trailing `; comment` has >2 tokens and
is **silently dropped** (it prints "Ignored invalid symbol definition", but our
`regen.sh` hides stdout). So:
- ✅ comments only on their own full lines starting with `;`
- ✅ each label/block line = `BB:AAAA token` and nothing else
- ❌ NEVER `00:1234 MyLabel   ; note`  ← this label will not be applied

(We hit this: a batch of named labels never took effect until the file was
rewritten with comments on separate lines. The byte-identical build was unaffected
because only the dropped lines were labels, but the names were missing.)

## The loop (repeat for every newly-discovered routine/table)
1. Identify an address that is code-but-shown-as-data (a jump-table target, a
   pointer-table entry, a `call`/`jp` into a `db` region).
2. Add `BB:AAAA .code:3` + `BB:AAAA MeaningfulName` to `symbols/sml.sym`.
   (For data tables, mark `.data:N` and name them.)
3. Regenerate + verify (MUST stay byte-identical):
   ```
   cp symbols/sml.sym super-mario-land-gb.sym
   python3 tools/mgbdis.py super-mario-land-gb.gb --output-dir disasm --overwrite
   cd disasm && make && cmp -s game.gb ../super-mario-land-gb.gb && echo OK
   ```
4. Read the now-correct disassembly; record findings in `docs/03-re-notes.md`
   with confidence tags. Name sub-targets you discover; goto 1.

**Why byte-identical can't break from this:** code vs data is only an
*interpretation*; RGBDS assembles `db $C9` and `ret` to the same byte. Renames and
re-classification never change output bytes — verified each iteration.

## A small helper to add later
`tools/regen.sh` (todo) to wrap steps 3 (copy + disassemble + build + cmp) so each
iteration is one command.
