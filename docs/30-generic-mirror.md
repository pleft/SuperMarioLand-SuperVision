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

## Pico-side fetch-overlay (phase 3b) — BUILT, pending HW validation

The cart IS the Pico and its served ROM lives in WRITABLE RAM (rom[]), so it
overlays the exporter WITHOUT any ROM free space — it overwrites bytes the
game never FETCHES. Firmware = main_telem.c (target SUPERPICO_TELEM):

- **Coverage learn:** core 1's serve loop marks a coverage bit per cart
  address it serves, AFTER driving data (uses inter-fetch slack, not the
  read window; one gated test, zero cost once off). ~6 s covers boot+attract.
- **Overlay (once, core 0):** `apply_overlay()` finds the longest never-
  fetched run in the fixed bank [n-0x4000, n-6); if >= 107 it drops the
  stub blob there, patches the blob's `jmp ORIG_NMI` operand (last 2 bytes)
  to the game's real NMI target, and repoints the NMI vector at the stub.
  All live edits to rom[]; dead bytes are never read so core 1 never serves
  a half-written stub. Reports over USB: `# OVERLAY: ... stub@$xxxx : ACTIVE`.
- **Key enabler:** telem_stub.s is POSITION-INDEPENDENT (only absolute refs
  are fixed WRAM/VRAM/reg addrs; loops use relative branches; sole address-
  dependent byte-pair is the final jmp operand). So the firmware carries it
  as a fixed 107-byte blob (telem_stub_blob.h, assembled once w/ ORIG_NMI=0)
  — no on-Pico assembler.
- The stub still needs mailbox WRAM $1F80-$1FFF free; the Pico sees all WRAM
  writes so it CAN verify/relocate, not yet wired.
- `apply_overlay` transform unit-tested bit-exact on the real Block Buster
  image (Python mirror). The runtime bits (coverage accuracy, is-the-window-
  truly-dead, serve timing under live edit) are the hardware test.

Reuses the PIO capture + protocol wholesale — once overlaid, the exporter's
mailbox writes ship exactly as our own game's would.

## Mac 160x160 renderer (tools/svrender.py + telemview --render) — DONE

`svrender.render_vram(vram, xscroll, yscroll)` decodes the 8 KB VRAM to a
160x160 image via the hardware-confirmed layout: 4 px/byte with bits1:0 =
leftmost pixel, 48-byte line stride, ring wrap at 8160, origin =
XSCROLL//4 + YSCROLL*48 (low 2 XSCROLL bits = 1px sub-byte delay). Stdlib
only (zlib PNG, no deps). `telemview.py --render OUT.png [--green] [--scale N]`
decodes the generic telem_stub protocol (slice id m[3], 32 payload bytes
m[5..36], CKSUM=sum(payload)+SEQ+JOYPAD), drops torn frames, accumulates the
256 slices, and repaints OUT.png at ~4 Hz with a decoded-joypad status line.

VALIDATED end-to-end offline (zero hardware): synthesize the exact F-lines
telem_stub would emit for the test_game ramp VRAM (incl. a torn frame) ->
feed to telemview --render -> output PNG is BYTE-IDENTICAL to a direct
render, torn frame correctly dropped (valid=256/257). Geometry + scroll
invariants unit-checked (pixel decode, stride, ring, XSCROLL 1px/4=1byte,
YSCROLL=+48). Live command once the board boots the overlay firmware:
`python3 tools/telemview.py /dev/cu.usbmodemXXXX --render screen.png --green`.

## Scroll-shadow-var auto-detection (tools/scrollhunt.py) — ALGORITHM DONE

Registers are write-only on the bus (docs/28), so the value written to
$2002/$2003 never appears — but EVERY WRAM write is data-visible, INCLUDING
zero page, and games hold the camera in a WRAM shadow var they write every
frame. And $2020 (joypad) is readable. So scrollhunt finds the scroll var by
correlation: rank WRAM addresses by how well their per-frame value-DELTA
tracks the D-pad (X-var delta <-> Left/Right, Y-var <-> Up/Down), after a
sane-step filter (median |delta| <= 8 px) that rejects RNG/violent vars.

`hunt()` returns the X and Y addresses + a signed correlation (sign = the
game's scroll-direction convention) + a ranked candidate table. VALIDATED
offline (`scrollhunt.py --selftest`): a scripted-D-pad synthetic trace with a
zero-page camera ($00C5/$00C6) buried among decoys (per-frame timer, anim
0..3 counter, LCG RNG, rare coin count) -> X identified $00C5 corr +0.998,
Y $00C6 +1.000, ALL decoys rejected (timer/anim ~0, RNG filtered as
insane-step). Capture format: `F <frame> <joy>` / `W <addr> <val>` lines.

Firmware learn-mode needed to feed it (spec, HW-gated): snoop WRAM writes the
same way the mailbox is captured, but the raw volume (thousands of writes/
frame) can't ship at line rate. On-Pico reduction: per WRAM address track
(last_val, writes_this_frame); a scroll var is written ~ONCE per frame, so
ship only addresses whose per-frame write-count is ~1 with a small running
delta -- collapses to a handful of candidates. Frame boundary = the $2002
register-write ADDRESS event (visible) or NMI stack push. One-time, ~300
frames while the user wiggles the D-pad.

## Runtime scroll export (telem_stub.s WITH_SCROLL) — DONE

Once scrollhunt gives the addresses, `patch_telem.py --scrollx $ADDR
--scrolly $ADDR` bakes them into the stub: telem_stub.s gained a `.ifdef
WITH_SCROLL` block that reads the shadow vars on-CPU (zp OR abs -- ca65 picks
the mode) into mailbox $1FA5/$1FA6 and folds them into the checksum, and sets
MAGIC $A6 so telemview knows the format. Without WITH_SCROLL it assembles
BYTE-IDENTICAL to the validated 107-byte overlay blob (verified by
gen_telem_blob.py; MAGIC $A5) so the fetch-overlay path is untouched.
telemview --render decodes $A6, extracts SCROLL-X/Y, and passes them to
render_vram (which already scrolls).

VALIDATED three ways: (1) base stub byte-identical to committed blob; (2) both
stubs executed on a real 65C02 (py65) -- $A5 leaves scroll 0, $A6 reads
SCROLL-X/Y from WRAM $80/$81 ($37/$9C) and the checksum matches; (3) telemview
--render on synthesized $A6 frames == direct render at that scroll, and !=
origin. Only the HW-gated learn-mode (finding the addresses live) remains
before scroll works on a real console; until then the renderer draws at origin
(0,0) = raw framebuffer (a $A5 stub / no scrollhunt).

## First HW run (2026-08-16): overlay coverage-safety failure + fixes

Block Buster booted THROUGH the Pico to its title/attract screens (boot
lottery is beatable) and the overlay applied -- but the game then cycled
logo<->title, was DEAD to input (START did nothing), and shipped ZERO frames.
Diagnosis (a real, important failure mode of the fetch-overlay):

- "Never fetched during learn" != "never executed." The learn phase only saw
  ATTRACT (logo/title); the game's START/input-handler code was never fetched,
  so apply_overlay marked it dead and dropped the 107B stub right on top of it.
  Attract kept working (that code was fetched, intact); START was now stub
  bytes -> input dead -> can't reach gameplay.
- NMI is OFF during attract on this game, so even the intact stub never ran ->
  no export. Double bind: can't export in attract, can't start to reach
  gameplay where NMI is live.

Three firmware fixes (main_telem.c; the Pico tree is gitignored, RULE 5):
1. **Clock anchored to first cart fetch**, not Pico boot -- the Pico is
   powered SECONDS before the console, so a boot-anchored learn window elapsed
   with EMPTY coverage and apply_overlay treated the whole fixed bank as dead,
   dropping the stub at $C000 OVER game code. (This alone likely explains prior
   "overlay won't boot" nights.)
2. **Refuse to apply on empty/sparse coverage** (guard) -- belt-and-braces
   against #1.
3. **Self-triggered apply, not a fixed timer**: apply ONLY once fixed-bank
   coverage exceeds attract levels (FB_MIN=6000, vs ~1.5K attract-only) AND has
   plateaued (STABLE_SECS=4). So the user just PLAYS the game (menus + into
   gameplay); the stub then lands only on bytes unfetched across everything
   played, preserving live code, and NMI is live in gameplay to drive export.
   Residual risk: code paths never exercised during play could still be
   overwritten -- inherent to the fetch-overlay; mitigated by playing the
   screens you want mirrored before it triggers.

Next HW run is now zero-fuss for the user: flash, boot the game, PLAY it a bit;
the log shows `# LEARN: ... keep playing` then `# OVERLAY: ... ACTIVE` and
frames start. No timing/keystrokes.

## THE WALL (2026-08-16, HW-proven): packed ROMs have NO dead window

Alien, played into a level, fetched `fixed-touched=16384/16378` -- 100% of its
fixed bank (every byte, code AND data tables read via #RD). Result:
`NO DEAD WINDOW >= 107 bytes : FAILED`. There is nowhere to hide the exporter.

This is a HARD, inherent limit of the fetch-overlay, not a bug:
- Partial coverage (attract only, Block Buster) -> finds a "dead" run that is
  really unvisited LIVE code -> stub corrupts it (broke the START handler).
- Full coverage (Alien) -> correctly finds ZERO dead space -> can't place the
  stub at all.
There is no safe middle: a commercial game uses ~all of its always-mapped
fixed bank ($C000-$FFFF), so neither the in-place patcher nor the fetch-overlay
(both need free fixed-bank bytes) can inject a resident NMI exporter.

Directions for a fresh attempt (none free of cost; decide before building):
1. Grow the ROM +1 bank for the exporter BODY, steal only a ~12-byte
   bank-switch trampoline from the fixed bank placed over bytes classified as
   GRAPHICS DATA (cosmetic tile glitch, game keeps running) -- needs a
   code-vs-data classifier from the access pattern (contiguous sequential
   reads = likely data copy; can't be told from #RD alone, so risky).
2. NMI-handler HOOK: overwrite the game's existing NMI handler entry with a
   jump to an added-bank stub that runs the stolen instructions then continues
   -- game-specific, fiddly, still steals a few fixed-bank bytes.
3. Reconsider the strategy entirely (temporal per-fetch overlay is barred by
   the BOOT LAW: the serve loop must stay byte-identical, no per-fetch branch).
The Mac side (renderer, scroll detect, protocol) is DONE and correct; the
blocker is purely getting CPU-executed exporter code resident on a packed ROM.

## Remaining build items
- Firmware learn-mode (WRAM-write snoop + per-frame-once candidate reduction)
  to feed scrollhunt -- the only remaining piece of the scroll story, HW-gated.
- Phase 3b overlay firmware HW validation (dead-window finder + fetch
  substitution) — built + unit-tested; blocked on the SuperPico boot lottery.
