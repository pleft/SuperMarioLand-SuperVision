#!/usr/bin/env bash
# build.sh -- one-shot toolchain setup + ROM build for the Super Mario Land
# Watara Supervision port.
#
#   ./build.sh            # install what's missing, then build
#   ./build.sh --god      # also build the invincibility test ROM
#   ./build.sh --smooth   # also build the "gameplay-accurate" smooth flavor
#   ./build.sh --deps     # only install/verify the toolchain, don't build
#
# LEGAL / RULE 5: this repo contains NO ROM data. Every graphic, level, table
# and sound is extracted from YOUR OWN Game Boy Super Mario Land ROM at build
# time. Supply it yourself as ./super-mario-land-gb.gb (see README). Nothing
# ROM-derived is ever committed or produced outside the gitignored build/ dir.
set -euo pipefail

ROM="super-mario-land-gb.gb"
EXPECT_SHA1="418203621b887caa090215d97e3f509b79affd3e"
BUILD_GOD=0
BUILD_SMOOTH=0
DEPS_ONLY=0
for a in "$@"; do
  case "$a" in
    --god) BUILD_GOD=1 ;;
    --smooth) BUILD_SMOOTH=1 ;;
    --deps) DEPS_ONLY=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- python + pypng
say "Checking Python 3 + pypng ..."
have python3 || die "python3 not found. Install Python 3 (https://python.org) and re-run."
if ! python3 -c "import png" 2>/dev/null; then
  say "Installing pypng (python image library the graphics extractor needs) ..."
  python3 -m pip install --user pypng \
    || python3 -m pip install --break-system-packages --user pypng \
    || die "could not install pypng. Try:  python3 -m pip install pypng"
fi

# ------------------------------------------------------------------------- cc65
install_cc65_from_source() {
  say "Building cc65 from source (no package manager found) ..."
  have git  || die "git required to fetch cc65."
  have make || die "make required to build cc65."
  local dir; dir="$(mktemp -d)"
  git clone --depth 1 https://github.com/cc65/cc65 "$dir/cc65"
  make -C "$dir/cc65" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  local prefix="$HOME/.local"
  make -C "$dir/cc65" install PREFIX="$prefix" >/dev/null 2>&1 || {
    # fall back to copying the two binaries we need onto PATH
    mkdir -p "$prefix/bin"; cp "$dir/cc65/bin/ca65" "$dir/cc65/bin/ld65" "$prefix/bin/"
  }
  export PATH="$prefix/bin:$PATH"
  warn "cc65 installed to $prefix/bin -- add it to your PATH:  export PATH=\"$prefix/bin:\$PATH\""
}

say "Checking cc65 (ca65 / ld65) ..."
if ! have ca65 || ! have ld65; then
  if [ "$OS" = "Darwin" ] && have brew; then
    say "Installing cc65 via Homebrew ..."; brew install cc65
  elif have apt-get; then
    say "Installing cc65 via apt ..."; sudo apt-get update -qq && sudo apt-get install -y cc65
  elif have pacman; then
    say "Installing cc65 via pacman ..."; sudo pacman -S --noconfirm cc65
  elif have dnf; then
    say "Installing cc65 via dnf ..."; sudo dnf install -y cc65
  else
    install_cc65_from_source
  fi
fi
have ca65 && have ld65 || die "cc65 still not on PATH after install."

# --------------------------------------------------------------------- C helper
# svshot/svgold/battery31 (the verification harness) need a C compiler + a local
# Potator checkout; they are OPTIONAL and not required to build the ROM, so we
# only note their absence.
have cc || have gcc || warn "no C compiler found -- the verification harness (svshot/svgold) won't build, but the ROM will."

if [ "$DEPS_ONLY" = 1 ]; then say "Toolchain ready."; exit 0; fi

# ------------------------------------------------------------------- the ROM
say "Checking your Game Boy ROM ($ROM) ..."
[ -f "$ROM" ] || die "$ROM not found.
    Place your own legally-owned Super Mario Land (World) Game Boy ROM here as:
        $ROM
    This project ships no ROM data; it is extracted from yours at build time."
GOT="$( (shasum -a 1 "$ROM" 2>/dev/null || sha1sum "$ROM") | awk '{print $1}')"
if [ "$GOT" != "$EXPECT_SHA1" ]; then
  warn "ROM SHA1 is $GOT, expected $EXPECT_SHA1."
  warn "This targets Super Mario Land (World) rev 0. A different revision may not build/verify."
fi

# ------------------------------------------------------------------- build
say "Building the Supervision ROM ..."
make
[ "$BUILD_SMOOTH" = 1 ] && { say "Building the smooth (gameplay-accurate) flavor ..."; make smooth; }
[ "$BUILD_GOD" = 1 ] && { say "Building the GODMODE (invincibility) test ROM ..."; make godmode; }

echo
say "Done. Output (gitignored):"
ls -1 build/super-mario-land*.sv 2>/dev/null | sed 's/^/    /'
echo
say "Load build/super-mario-land.sv in a Watara Supervision emulator (e.g. Potator / a RetroArch Potator core)."
