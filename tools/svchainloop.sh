#!/bin/bash
# Chain-driver: loop svauto -> svchain until GOAL or stagnation.
# Usage: bash tools/svchainloop.sh <level> <prefix.txt> [frames]
# Stops when svauto prints GOAL (route left in $ROUTE) or when an iteration
# fails to advance the safe prefix by >=8 world-x px (hand chunk needed there).
set -u
LEVEL=$1; PREFIX=$2; FRAMES=${3:-12000}
ROUTE=/tmp/chainloop_route.txt
LASTX=-1
for it in $(seq 1 40); do
  /tmp/svauto build/super-mario-land.sv "$LEVEL" "$FRAMES" "$ROUTE" "$PREFIX" > /tmp/chainloop_$it.log 2>&1
  if grep -q GOAL /tmp/chainloop_$it.log; then
    echo "GOAL at iteration $it -- route in $ROUTE"; exit 0
  fi
  OUT=$(python3 tools/svchain.py "$ROUTE" "$PREFIX" "$LEVEL")
  X=$(echo "$OUT" | sed 's/.*world x \([0-9]*\).*/\1/')
  echo "iter $it: $OUT"
  if [ "$X" -lt $((LASTX+8)) ]; then
    echo "STAGNANT at x$X (was $LASTX) -- hand chunk needed"; exit 1
  fi
  LASTX=$X
done
echo "iteration cap reached at x$LASTX"; exit 1
