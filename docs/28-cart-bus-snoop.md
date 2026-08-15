# 28: Cart-bus snooping — what the SuperPico can see (2026-08-15)

The GameShell-devkit side-quest, phase 1: can the RP2040 on the SuperPico
watch the console's memory traffic through the cart edge? Answer: **yes,
enough to mirror the screen — but not by reading VRAM directly.**

## Board truth (SuperPico schematic, rev 1.0)

- Cart edge pin 35 **#WR exists but is NOT routed to the Pico**. GPIO28 is
  **#RD** (main.c's `NWR` define is a misnomer). Every other usable GPIO is
  consumed (GP0-16 = A0-A16, GP17-22 + GP26-27 = D7..D0), so #WR cannot be
  bodged over either.
- A0-A16 pass through three 74LVC245s, always enabled, console→Pico: the
  address bus is continuously visible.
- D0-D7 are wired STRAIGHT to the Pico (no transceiver): the data bus is
  continuously visible. Connector D0..D7 = GPIO 27,26,22,21,20,19,18,17;
  `bin2c.py` bit-reverses ROM bytes to match.
- #RD is asserted by the ASIC for CART reads only (it must be — the serve
  loop drives the bus whenever #RD is low; a global read strobe would fight
  the internal SRAM on every RAM read).

## Method (hwtest15/16/17 + BUSDIAG firmware v1-v4)

A diag ROM loops marker accesses (`sta`/`lda` of known addr/data). Its loop
contains ONLY cart fetches + marker cycles, so every #RD-HIGH cycle is a
marker cycle. The snoop firmware (build/Superpico/code/main_snoop.c, target
SUPERPICO_SNOOP; serve loop verbatim on core 1, USB CDC + poller on core 0,
~2M polls/s) edge-counts full (addr14+data), data-only and addr-only marker
matches and reports over USB every second.

## Findings (real hardware, clean gray-screen runs)

| bus cycle                | address | data | note |
|--------------------------|---------|------|------|
| cart fetch               | yes     | yes  | we serve it |
| WRAM write ($0000-$1FFF) | yes     | yes  | ~93% of samples carry valid data |
| WRAM read, ABSOLUTE mode | yes     | yes  | data window narrow (~3% of samples) but real |
| WRAM read, ZERO-PAGE     | **no**  | **no** | zp reads never touch the external bus |
| VRAM write ($4000-$5FFF) | yes     | **no** | address broadcast every write |
| VRAM read                | yes     | **no** | |
| write to unmapped ($3111)| yes     | no   | write-ADDRESS broadcast covers ALL space |
| ASIC register read       | yes     | no   | address broadcast; data = open-bus $20 (CORRECTED — the v4 marker used low14 $0026 instead of $2026; the ring showed A=1a026/D=20 all along) |

**Register readback (hwtest19 + REGPROBE, real HW, 2026-08-15): ALL ASIC
registers are WRITE-ONLY** — reads return the open-bus ghost $20 (the last
fetched operand byte) — EXCEPT $2020 (joypad), which reads real button
state. Potator models every register as readable: fiction; anything
readback-based works in the emulator and breaks on hardware. $2xxx
addresses have low14 = $2xxx — a $2xxx marker with low14 $0xxx matches
nothing (the v4 bug).

**Register writes are ADDRESS-ONLY on the cart bus (BUSDIAG5, real HW):**
`sta $2002` broadcasts the address, never the data — scroll values cannot
be sniffed from reg writes NOR read back. Ways to a game's scroll state:
(a) the game's RAM shadow variable — ALL WRAM writes (zp included) are
data-visible, so tracking the variable's writes gives its value; finding
WHICH variable is a one-time per-game config (~30 games exist), or (b) for
abs-mode `lda var / sta $2002` sequences, pair the visible WRAM read with
the following reg-write event.

- Non-cart cycles present the CPU address as `a16:a15:a14 = 110` + the raw
  low 14 bits (a WRAM write to $0066 shows $18066 on the cart bus).
- VRAM is NOT on the external CPU bus (it hangs off the ASIC's video bus);
  only the write/read ADDRESS is broadcast outward, never its data.
- The NMI's stack pushes ($01FC-$01FF) are visible WRAM writes → interrupt
  timing and return addresses are observable from the cart.
- Failed-boot signature: #RD never goes low while the bus shows a small
  looping set of garbage WRITES (prefix 110, e.g. $19BE4-$19C05) — the CPU
  crashed without valid vectors. Useful boot-lottery telltale.

## Artifacts to remember

- Bus-transition glitch samples (address bits mid-flip) produce low-rate
  false matches — thresholds > 1000/s separate signal from artifact; a naive
  "reset-vector fetch" detector false-fires ~1/s from them.
- Data lines float and RETAIN values when nothing drives them; a powered
  Pico with an off console reads structured-looking garbage. Counters
  survive console power cycles (Pico stays on USB), so v3+ zeroes them per
  boot attempt.
- Polling at ~2 M samples/s catches ~92-97% of write cycles but individual
  samples can carry in-transition data. Last-sample-wins per address settles
  it; PIO+DMA capture is the phase-3 upgrade for lossless streams.

## Consequence: the devkit pipeline (chosen: display-list telemetry)

Since WRAM writes are fully visible and we own 100% of the game code, the
game writes a compact per-frame display list into a WRAM mailbox
($1F80-$1FFF, free above HUDSHADOW $1D00-$1F7F); the Pico snoops it and
ships snapshots over USB; the host reconstructs the 160x160 screen from the
same ROM data it already has. Full-snapshot-per-frame makes the link
loss-tolerant. Protocol + pipeline: docs/29. The alternative (Pico
shadow-executes the served ROM, reconstructs VRAM, syncs on the visible
VRAM write-address stream) stays the endgame for a real debugger.

Files: hwtest/hwtest15.s .. hwtest17.s (probes); firmware lives in
build/Superpico/code (main_snoop.c / main_telem.c — untracked vendor tree).
