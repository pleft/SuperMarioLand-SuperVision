#!/bin/sh
# svgold.sh -- the gold gate (port law E1), run on the REAL Potator core.
#
# The old gate was a py65 script that lived in /tmp and evaporated; worse, the
# sim runs neither the NMI nor the raster IRQ (law E9), so it could not see the
# whole class of damage those cause. This drives the real core through the
# port's own title-screen level select (N taps of SELECT = level N, then START)
# and hashes the sampled framebuffers.
#
#   tools/svgold.sh out.txt          # capture
#   diff before.txt after.txt        # the gate
#
# Any level that changes without an intended reason is a regression. Build
# /tmp/svshot first:
#   cc -O1 -I ~/Dev/potator/common -I ~/Dev/potator/common/m6502 \
#      -o /tmp/svshot tools/svshot.c ~/Dev/potator/common/*.c \
#      ~/Dev/potator/common/m6502/m6502.c
set -e
OUT=${1:-/dev/stdout}
ROM=${ROM:-build/super-mario-land.sv}
SHOT=${SHOT:-/tmp/svshot}
: > "$OUT"
for lvl in 0 1 2 3 4 5 6 7 8; do
    # Hold RIGHT for 900 frames: a no-input run parks the camera so no spawn
    # entry ever fires, and 420 frames was still too short -- entries fire with
    # the object ~184px off-screen, so it takes hundreds more frames before an
    # enemy is VISIBLE and can affect the hash. Verified discriminating: it
    # separates builds whose spawn timing differs, which the 240-frame no-input
    # version did not.
    if "$SHOT" "$ROM" $lvl 900 60 /tmp/svgold_$lvl.bin >/dev/null 2>&1 "" "R900"; then
        echo "$lvl $(shasum -a 1 < /tmp/svgold_$lvl.bin | cut -c1-12)" >> "$OUT"
    else
        echo "$lvl FAIL" >> "$OUT"
    fi
done
