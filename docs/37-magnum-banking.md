# MAGNUM banking: past the 128K wall

Decision (user, 2026-08-20): move the cart to the MAGNUM mapper so ROM space
stops dictating the architecture. This is the design and the traps.

## Why 128K was a wall, and why it isn't one

The standard mapper is `$2026` bits 7:5 -- three bits, 8 x 16K = **128K**, and
the cart edge carries A0-A16 (128K flat). Measured cost of that ceiling:

- W4 needs ~17.3K; only ~11.5K of usable contiguous space is left. It does not fit.
- W3 cannot be resident in the bank mapped while it runs (bank 1 has 58 bytes
  free, its data needs 2197), so every enemy draw and script byte costs a bank
  switch, and **every SYS_CTRL write restarts the LCD scan** (law D1) -- that is
  the 3-X HUD instability.
- 44KB of the cart is spent duplicating one 8833-byte prefix into six banks.

**MAGNUM** is a real Supervision cartridge mapper (the 512K 'Journey to the
West'). Potator implements it and **auto-detects it purely by size**:

```c
isMAGNUM   = size > 131072;                                   // memorymap.c:269
bankOffset = ((regs[BANK] & 0x20) << 9) | ((regs[0x21] & 0xf) << 15);
```

So `$2021` bits 3:0 pick a 32K page and `$2026` **bit 5** picks the 16K half:
32 banks, 512K. No emulator patch is needed -- any image over 131072 bytes
switches the core into MAGNUM mode.

## The file layout does not change

Bank `b` still lives at file offset `b * $4000`, because
`(b>>1) * $8000 + (b&1) * $4000 == b * $4000`. Only the SELECTION changes:

```
page = b >> 1   ->  $2021 bits 3:0
half = b &  1   ->  $2026 bit 5
```

`upperRomBank` is the **last 16K of the file** regardless of size, so FIXED
must stay at the end of the image.

## Trap 1: our own boot disables the mapper

`src/supervision.inc` names `$2022` twice -- `LCD_DRIVE` ("written $0F by every
commercial boot ... the panel may not [work without it]") and `LINK_DATA`.
Potator gates MAGNUM on `regs[0x22] == 0`, so writing `$0F` there switches
banking off.

The gate is evaluated **at the `$2021` write** and never re-evaluated on a
`$2022` write, so a bank switch can open it and close it again immediately:

```asm
    stz LINK_DATA        ; $2022 = 0   -- open the MAGNUM gate
    sta LINK_DDR         ; $2021 = page -- BANKS HERE
    lda #$0F
    sta LCD_DRIVE        ; $2022 = $0F -- give the panel its value straight back
```

## Trap 2: this is what fixes the HUD

Potator calls `supervision_scan_restart()` from the `$2026` case **only** --
the `$2021` case banks without restarting the scan. So under MAGNUM, a bank
switch that changes only `$2021` does not disturb the LCD. Combined with full
residency (nothing to switch during play), 3-X's switch rate should reach the
0.00/frame that 1-1 measures today.

Keep `$2026` writes (the 16K half bit) to LEVEL LOAD, where a scan restart is
invisible. Never change the half during play.

## Trap 3: SuperPico cannot see the page number

Bus snooping (docs/28) found register writes appear on the cart bus as
**address only, no data** -- so the Pico cannot read the value written to
`$2021` and cannot implement MAGNUM natively the way a real MAGNUM cart does.

Mitigation, to be carried by the ROM from the start: alongside the `$2021`
write, perform a **magic ROM read** whose ADDRESS encodes the page
(`lda magic_base + page`). Reads are the visible direction (`#RD` is routed).
That read is a harmless ROM fetch on a real MAGNUM cart and in Potator, and it
is the command channel the Pico firmware can act on later. Whether D0-D7 are
in fact valid during a `$2021` write is worth one bus test -- if they are, the
Pico can implement MAGNUM natively and the magic read becomes redundant.

## Compatibility, stated honestly

A MAGNUM image needs a MAGNUM-capable cartridge. It runs on emulators (Potator
auto-detects) and on carts that implement the mapper; it does NOT run on a
plain 128K flash cart. That trade was made deliberately in exchange for the
space.

## Verification

`tools/svharness.py` models both mappers and picks by size exactly as Potator
does, latching the MAGNUM page at the `$2021` write while `$2022 == 0`
(`_bank_check`). The 128K image still passes GOLD-OK unchanged, so the model is
inert until the image actually grows.

## Trap 4: where `set_bank` can live (found attempting step 2)

A routine that switches banks must have its OWN remaining instructions present
in the destination bank -- the byte after the switch is fetched from the new
mapping. That rules out three of the four obvious homes:

- **LEVELS (the prefix)**: safe only when the destination bank ALSO carries the
  prefix. Banks 0-5 do; bank 6 (W3 cold data + boot images) does not, and the
  boot maps bank 6. So a prefix-resident `set_bank` cannot make that hop.
- **RCODE ($1200)**: 3 bytes free, and it is bounded by the kit window at $1500.
- **ZP**: full, so even the `sys_sh` shadow has to be an absolute byte.
- **FIXED**: the only region present after ANY switch -- and it has **10 bytes
  free**, against roughly 20-28 for the routine.

Callers in RAM (the $1500 kit window, the L13E ending blob) can inline the
sequence at no cost to FIXED, because RAM survives a switch too. It is only the
FIXED and prefix callers that need the shared routine.

**So step 2 is blocked on ~20 bytes of FIXED, and the fix is structural, not a
squeeze.** With 16 banks available the clean answer is to give EVERY bank the
prefix, which makes a prefix-resident `set_bank` universally safe and costs
nothing in FIXED. That means W3's cold data (10817B) must leave bank 6 and
split across two prefix-bearing banks (7551B of data each), and the boot images
move with it. Prefix cost at 16 banks is 141K of 256K, leaving ~115K for data
against ~60K of level data today -- affordable, but it is a packer rewrite, not
an edit.

Order of work: (1) harness model [done], (2) give every bank the prefix + move
W3 cold data and the boot images out of bank 6, THEN grow to 256K and convert
the selection -- gold hashes must stay bit-identical, (3) re-lay-out to make W3
resident and drive the switch rate to zero, (4) W4.

Do NOT grow the image before the selection is converted: past 131072 bytes
Potator switches to MAGNUM and the existing 3-bit writes stop banking, so the
two changes have to land together.
