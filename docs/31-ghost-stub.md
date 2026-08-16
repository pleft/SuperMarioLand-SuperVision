# 31: The ghost stub — time-multiplexed VRAM exporter (devkit phase 3c)

docs/30 ended at THE WALL: a packed commercial ROM (Alien: 16384/16378 fixed-
bank bytes read) has **no dead window** for a resident 107-byte exporter, and
partial coverage finds "dead" runs that are really unvisited live code. Both
injection strategies need free fixed-bank **space** that packed games don't
have.

The ghost stub sidesteps the wall by spending **time** instead of space: the
cart is a live computer, and the served rom[] doesn't have to be the same ROM
at every microsecond. During the NMI window the game's main program is frozen
mid-interrupt — its code bytes are *guaranteed unfetched* for that whole
window. So the stub only *exists* while the main program is provably asleep.

## Per frame (NMI = crystal-locked 61.04 Hz, predictable to a few µs)

1. `t_pred − 250 µs`: core 0 swaps the stub over a chosen quiet run **Y** in
   the fixed bank and points the NMI vector at Y (both plain writes to rom[];
   core 1's serve loop untouched — BOOT LAW intact).
2. NMI: CPU pushes state, reads the (patched) vector, runs the stub — exports
   a VRAM slice + joypad to the WRAM mailbox (docs/29 protocol, bus-visible),
   ends `jmp ORIG_NMI`; the game's real handler runs normally.
3. COMMIT (+30 µs grace — the stub epilogue still fetches ~11 bytes from Y):
   restore the original bytes and vector. ROM is pristine again, ~92 % of
   every frame.

## Why every failure mode is benign

- Vector only points at Y **while the stub is resident** — an off-schedule
  NMI always runs the original handler.
- NMI stops (menus/attract): windows suspend after 40 empties, resume on the
  next observed `$FFFA` fetch (the vector read is bus-visible; that's also
  the per-frame resync).
- Stub never COMMITs (wrong Y for this game): watchdog restores everything
  and disables ghost mode after 3 misses.
- No timing race: the swap happens ~250 µs before the NMI with the main loop
  running elsewhere; nothing needs nanosecond reflexes. (A reactive
  swap-on-`$FFFA` design was analyzed and rejected: its 500 ns budget vs a
  107-byte copy was marginal, and a single missed trigger with a permanently
  patched vector = crash.)

## Y selection (calibration phase — the user just PLAYS)

Fetch-capture can't distinguish execution from data reads, but it doesn't
need to: the requirement is only that Y is never **read** during the NMI
window (when the stub is resident). Two footprint maps, built post-settle:

- `nmi_fp[]` — bytes read within 3 ms of a `$FFFA` fetch → never usable.
- `main_fp[]` — bytes read outside NMI windows.

Preferred Y: clear in **both** maps (init-only bytes — zero risk; even
100 %-covered Alien has boot-only code that never re-reads post-settle).
Fallback: clear in `nmi_fp` only — exposed only during the 250 µs pre-swap
lead (~1.5 % duty), and the miss-watchdog catches a bad pick. Go-live gates:
≥15 s of live NMI (50–75/s), the chosen Y stable ≥8 s, mailbox $1F80-$1FFF
untouched by the game, then `# GHOST: LIVE stub@$XXXX`.

## The bit-reversal bug (found building this)

bin2c stores rom[] **bit-reversed** (the serve loop's GPIO shuffle depends on
it) — but docs/30's resident overlay wrote the stub blob and read the NMI
vector RAW. Confirmed against the real Alien image: `PHA` (0x48) was served
as 0x12. Every previously "applied" overlay injected bit-garbled opcodes and
a garbled vector — this is (part of) why overlaid Block Buster was a zombie.
The ghost engine bit-reverses everything (stub image, vector patch, vector
read); transforms validated bit-exact in a Python mirror against Alien:
swap-in serves the exact 107 stub opcodes + `jmp $C04F` (Alien's real
handler), restore returns rom[] byte-identical.

## Status

- Firmware built (SUPERPICO_TELEM, ghost engine on core 0): CAL phase with
  per-second `# CAL … PLAY the game` reporting, self-triggered go-live,
  window engine with suspend/resume + watchdogs. HW test pending.
- Byte-transform layer validated offline against real Alien (above); stub
  semantics validated on a real 65C02 (py65, docs/30).
- Mac side unchanged and done: `telemview.py --render` + svrender consume the
  same mailbox protocol.
- Expected output: 32-byte slice/frame → full 160×160 refresh ~4.2 s
  (progressive live mirror); slice size tunable later against the NMI budget.

## HW run script

1. Flash SUPERPICO-ALIEN-GHOST.uf2, boot the console, **play the game**.
2. Watch `# CAL` lines → `# GHOST: LIVE stub@$XXXX` → ships climbing.
3. `python3 tools/telemview.py --render ~/Desktop/alien_screen.png --green`
   — the PNG refreshes ~4×/s with the real console screen.
