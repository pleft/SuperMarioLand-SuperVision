# 30: Generic screen mirroring for ANY Supervision game (devkit phase 3)

Goal (user, 2026-08-15): the Mac shows a *real* Supervision's screen for any
game — NOT our own port, and explicitly NOT by re-running the ROM in an
emulator to reconstruct VRAM. Pixels must come from the real hardware.

## Why the console must export its own VRAM

The cart bus never carries VRAM data (docs/28: VRAM lives on the ASIC video
bus; only its write ADDRESS leaks). Registers are write-only except $2020
(joypad). So the only way to get real pixels off an unmodified-hardware
console without an emulator is to make the CPU itself read VRAM and write it
somewhere the cart bus CAN see — WRAM. We do that by patching the game ROM:
inject an NMI-prefix routine that copies a VRAM slice into the WRAM mailbox
($1F80-$1FFF) every frame; the telemetry stack (docs/29) ships it; the Mac
renders it. Scroll comes from the game's RAM shadow var (all WRAM writes are
data-visible); joypad from $2020.

## The patcher (tools/patch_telem.py + tools/telem_stub.s)

Reads the NMI vector (ROM's last 6 bytes = NMI/RESET/IRQ at $FFFA), assembles
the 107-byte stub via ca65 at a free fixed-bank address, splices it in, and
repoints NMI at it; the stub ends `jmp ORIG_NMI`. Stub is transparent: saves
A/X/Y + ZP $10/$11, exports a 32-byte VRAM slice (256 frames = full 8 KB,
~4 s) + joypad + checksum, COMMIT last. VALIDATED end-to-end in the emulator
(hwtest/test_game.sv, a roomy synthetic ROM): patched mailbox output ==
real VRAM byte-for-byte, all 256 slices, valid checksums.

## The wall: real ROMs have FULL fixed banks

The only always-mapped region is CPU $C000-$FFFF = the game's fixed bank,
and real ROMs pack it solid:
- Block Buster (64K): largest fixed-bank free run = **2 bytes**.
- Our own super-mario-land (128K): **10 bytes**.
Both < the 107-byte stub. Growing the ROM does NOT help: the fixed bank must
hold the game's $C000-$FFFF bytes verbatim (vectors, handlers, absolute
refs), so there is nowhere to add always-resident code. In-place injection
only works for ROMs that happen to have a big fixed-bank gap (homebrew, our
test ROM). patch_telem.py detects this and exits 2 with the free-run map.

## Required next step: Pico-side fetch-overlay (phase 3b)

The cart IS the Pico, so it can serve stub bytes for a chosen CPU address
window WITHOUT using ROM free space:
- Overlay a 3-byte trampoline (`jmp stub`) at the original NMI entry; serve
  the 107-byte stub body at a fixed-bank address the game NEVER fetches.
- Find that dead window empirically: the Pico already sees every fetch —
  observe the game for a few seconds, pick a never-touched fixed-bank run
  (e.g. one-time RESET/init code, dead after boot; enable the overlay only
  post-boot). No ROM growth, no free-space requirement.
- The stub still needs the mailbox WRAM free ($1F80-$1FFF); the Pico can
  verify the game never writes there (it sees all WRAM writes) and, if it
  does, relocate the mailbox to another observed-dead WRAM window.
This is the generic path; it also reuses the PIO capture + protocol wholesale.

## Remaining build items
- Phase 3b overlay firmware (dead-window finder + fetch substitution).
- Scroll-shadow-var identification per game (~30 games; one-time, or auto:
  the var whose value the game copies to $2002/$2003 each frame).
- Mac 160x160 renderer: mailbox VRAM slices + scroll -> pixels via the LCD
  scan rules (docs/27). Currently telemview is text-only.
