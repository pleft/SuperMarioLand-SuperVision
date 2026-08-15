# 29: Display-list telemetry — game → SuperPico → host (phase 2, option 2)

Goal: the running game's screen, live on the Mac (later: GameShell),
reconstructed from WRAM-write telemetry snooped off the cart bus (docs/28).

## The mailbox: WRAM $1F80-$1FFF (128 bytes)

Free in the port (HUDSHADOW ends at $1F7F; boot clears $1D00-$1FFF; no BSS
symbol above $1F7F). All telemetry stores are plain `sta abs` — every WRAM
write is bus-visible regardless of addressing mode.

Layout (v1):

| addr  | name   | content |
|-------|--------|---------|
| $1F80 | TRAP   | NEVER written — the window-base byte (low7=0) catches bus-transition aliases in the snooper (HW-measured: ~50% of frames tore ONLY here before it was retired); excluded from CKSUM |
| $1F81 | MAGIC  | $A5, rewritten first every frame |
| $1F82 | SEQ    | frame counter |
| $1F83 | VXP    | scroll fine x |
| $1F84 | VXPH   | scroll page x |
| $1F85 | VYP    | scroll y |
| $1F86+| payload| producer-defined display list |
| $1FFE | CKSUM  | mod-256 sum of header+payload — the viewer DROPS torn frames |
| $1FFF | COMMIT | = SEQ, written LAST — triggers the ship |

Rules: write MAGIC..payload first, then CKSUM, COMMIT last, once per frame.
The whole list is rewritten every frame (full snapshot), so a missed/
corrupt byte self-heals next frame — the link needs no ACKs.

HW-measured link quality (2026-08-15, TELEM18B/C): COMMIT detection is
lossless (61 ships/s exactly); polling at ~17.5M samples/s captures bytes
with ~3% per-byte corruption — dominated by USB-IRQ gaps on core 0 (missed
write cycle = stale byte) plus rare early-phase samples (a 65C02 write
cycle carries the RETAINED previous fetch byte — the $1F operand — for its
first half; the poller keeps the LAST sample per address, which needs >4
samples/cycle to land late; the 5.5M-polls/s v1 firmware read seq=$1F
forever because of this). CKSUM + drop-torn-frames turns 3%/byte into
"most frames perfect, torn ones discarded" — at 61 snapshots/s even 50%
drops would still give a fluid display. Lossless capture = PIO+DMA, later.

hwtest18 (the pipeline validator) fills the payload with test freight:
$1F85 box x (bounces 0..159), $1F86 box y, $1F87 = SEQ^$FF, and
$1F90-$1FBF = SEQ+i ramp (48 bytes) so the viewer can MEASURE per-frame
capture corruption before the real game goes on the wire. It also draws a
black dot at column x on VRAM row 80 — console dot and viewer box must move
together.

## Capture: edge-locked two-phase PIO sampling (FINAL — 100% valid on HW)

Free-running polling CANNOT capture this bus reliably; every failure mode
below was hit and measured on hardware (2026-08-15, TELEM v1→v5):

1. A 65C02 write cycle carries the RETAINED previous fetch byte (the $1F
   operand) for its first half — slow polling read seq=$1F forever.
2. USB IRQs on the polling core eclipse whole write cycles.
3. Bus-transition aliases (address bits mid-flip) hit single-sample window
   states: they clobbered the window-base byte $1F80 (hence the TRAP byte)
   and fired phantom COMMITs.
4. The poll loop and the console crystal BEAT-LOCK: fixed instructions in
   the NMI writer get systematically favorable/unfavorable phases (accSeq
   33% vs accCommit 85%, with minute-scale jumps as the beat drifts).
5. End-of-cycle skew: direct-wired data lines flip to the next fetch byte
   before the '245-buffered address lines let go — pair-filtered polling
   accepted mailbox bytes containing OPCODES (9d/ad/bd).
6. `sta abs,X` inserts a DUMMY READ (same address, OLD data) in the same
   #RD-high period as the write — single edge-locked samples captured all
   48 ramp bytes one frame stale (ck_only=100%).

The fix for all six: PIO (buscap.pio, hand-assembled into buscap_pio.h —
pioasm won't configure under CMake 4.4). On each #RD rising edge push TWO
samples: +168 ns (mid cycle 1) and +424 ns (mid cycle 2). Plain-abs writes:
A hits the write, B lands after #RD fell and self-rejects at the window
check. Indexed writes: A hits the dummy, B hits the write and overwrites
it. #RD stays low across back-to-back fetches, so events are only ~21k/s —
huge FIFO headroom. PIO reads pins passively: ZERO impact on the serve
loop. Measured: valid=100.0%, rampbad=0, 61 fps lossless, dup only at
connect time.

## Firmware: SUPERPICO_TELEM (build/Superpico/code/main_telem.c)

Core 1 = the untouched serve loop. Core 0 = USB CDC + a tight poller:
sample `gpio_in`; on #RD-high with `(v & 0x1FF80) == 0x19F80` (prefix 110 +
$1F80 window) store `shadow[v & 0x7F] = data` — last-sample-wins, so the
settled (late-cycle) value survives transitional samples. A write to index
$7F (COMMIT) marks the snapshot for shipping; the loop then prints one line

    F <seq2hex> <128 hex pairs>

(~262 chars, ~61/s ≈ 16 KB/s — trivial for CDC; the print happens right
after COMMIT, i.e. in the dead time before the next frame's writes). A `#`
heartbeat line reports polls/ships once per second.

## Host: tools/telemview.py (stdlib only)

`python3 tools/telemview.py [/dev/cu.usbmodemXXX]` — raw-modes the tty,
parses `F` lines, validates MAGIC/COMMIT/ramp, and live-prints seq, fps,
box x/y with an ASCII position bar + a corruption counter. (Pixel-true
rendering replaces this once the real game telemetry lands.)

## Next steps

1. HW-validate the hwtest18 chain (dot on console == box in viewer, ramp
   corruption ~0). -> then:
2. Game producer: end-of-frame RCODE routine writes SEQ/scroll/HUD digits/
   object table (type,x,y,frame,flip per active slot) — ~100 stores ≈ 800
   cyc ≈ 1% of frame. Bank space: RCODE/RCRAM is the pressure valve.
3. Mac renderer: reuse the repo's map/tile extractions to redraw the
   background from scroll + camera, sprites from the object table — the
   same data the port itself draws from.
4. GameShell replaces the Mac; PIO+DMA capture replaces polling when we
   need lossless streams (full shadow-execution debugger, docs/28).
