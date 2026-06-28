#!/bin/sh
# Regenerate the disassembly from the current symbol file and verify the rebuild
# is byte-identical to the original ROM. Run from the repo root.
#
#   tools/regen.sh
#
# Exits non-zero (and shouts) if the rebuilt ROM differs from the source — that
# must never happen from labeling/region changes (see docs/05-methodology.md).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ROM="super-mario-land-gb.gb"
EXPECT_SHA1="418203621b887caa090215d97e3f509b79affd3e"

[ -f "$ROM" ] || { echo "ERROR: $ROM not found (user must supply their own legally-owned ROM)"; exit 2; }

# stage the hand-authored symbols under the name mgbdis auto-loads
cp symbols/sml.sym "${ROM%.gb}.sym"

python3 tools/mgbdis.py "$ROM" --output-dir disasm --overwrite >/dev/null
( cd disasm && make >/dev/null 2>&1 )

GOT="$(shasum -a 1 disasm/game.gb | awk '{print $1}')"
if [ "$GOT" = "$EXPECT_SHA1" ] && cmp -s disasm/game.gb "$ROM"; then
  echo "OK — rebuild byte-identical (SHA1 $GOT)"
else
  echo "FAIL — rebuild DIFFERS from source ROM!"
  echo "  expected $EXPECT_SHA1"
  echo "  got      $GOT"
  exit 1
fi
