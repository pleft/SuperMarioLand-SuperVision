#!/usr/bin/env python3
# gen_rom_h.py IN.sv OUT/rom.h
# Compact the 512K MAGNUM image to just the bytes the 65C02 can address, so it
# fits the RP2040's 264K SRAM and can be served at SRAM speed (XIP flash is too
# slow for the SV bus -- it would not even boot). The port keeps $2026 bit5 = 0,
# so only the LOW 16K of each 32K page is ever mapped ($8000-$BFFF), and the
# fixed window ($C000-$FFFF) is the file's last 16K. Everything else is fill.
#
# Compact layout (16K units): bank 0..NBANKS-1 packed contiguously, then FIXED.
#   CPU $8000-$BFFF, page P  -> rom[ P*0x4000 + (addr & 0x3FFF) ]
#   CPU $C000-$FFFF          -> rom[ FIXEDOFF + (addr & 0x3FFF) ]
# Bytes are bit-reversed to match the SuperPico D-pin wiring (zwenergy bin2c).
import sys
src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
assert len(d) == 512*1024, f"expected 512K, got {len(d)}"

# banks the port can select: page P (0..12) -> file offset P*0x8000 (low 16K of
# the 32K page). Detect the highest non-empty page so we never drop live data.
NB = 0
for P in range(16):
    seg = d[P*0x8000 : P*0x8000 + 0x4000]
    if any(b != 0xFF for b in seg):
        NB = P + 1
banks = [d[P*0x8000 : P*0x8000 + 0x4000] for P in range(NB)]
fixed = d[-0x4000:]

# sanity: the odd (high) halves of used pages must be pure fill (unaddressable);
# warn if not, so we never silently lose data.
for P in range(NB):
    hi = d[P*0x8000 + 0x4000 : P*0x8000 + 0x8000]
    live = sum(1 for b in hi if b != 0xFF)
    if live and (P*0x8000 + 0x8000) != len(d):
        sys.stderr.write(f"WARN: page {P} high 16K has {live} non-fill bytes (unaddressable, dropped)\n")

compact = b"".join(banks) + fixed
rev = bytes(int(f"{b:08b}"[::-1], 2) for b in compact)
FIXEDOFF = NB * 0x4000
with open(dst, "w") as f:
    f.write(f"#define NBANKS   {NB}\n")
    f.write(f"#define FIXEDOFF 0x{FIXEDOFF:X}\n")
    f.write(f"#define ROMSIZE  {len(rev)}\n\n")
    f.write(f"const unsigned char rom[ {len(rev)} ] = {{\n")
    for i in range(0, len(rev), 16):
        f.write("  " + ",".join(f"0x{b:02x}" for b in rev[i:i+16]) + ",\n")
    f.write("};\n")
print(f"gen_rom_h: {NB} banks + FIXED = {len(compact)//1024}K compact "
      f"(from {len(d)//1024}K), FIXEDOFF=0x{FIXEDOFF:X} -> {dst}")
