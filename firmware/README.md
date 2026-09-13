# SuperPico firmware — Super Mario Land (512K MAGNUM) on real Watara Supervision

The stock SuperPico firmware (github.com/zwenergy/Superpico) serves a flat ROM
of **≤128K from SRAM** and has **no MAGNUM banking**. The full port is a **512K
MAGNUM** image, so it needs this firmware, which adds:

1. **MAGNUM banking by address-snoop.** SuperPico cannot see register-write data
   and does not route `#WR` (see `../docs/28-cart-bus-snoop.md`), so it cannot
   latch `$2021` the way a real MAGNUM cart does. Instead the ROM announces every
   bank switch with a harmless write to **`$3F00 + page`** (`../src/magbank.inc`);
   `$3F00-$3F1F` is unmapped, so the write is a no-op in Potator and on a real
   MAGNUM cart, but its **address** is visible on the cart bus. The firmware
   snoops it and sets `bankOffset = page << 15`.
2. **Serving from flash (XIP).** 512K does not fit the RP2040's 264K SRAM, so
   `rom[]` is `const` (→ flash) and only the serve loop is pinned in SRAM.

> **Not yet validated on hardware.** The XIP cache-miss cost on a bank switch,
> and the snoop's immunity to bus-transition glitches, can only be confirmed on
> the cart. This is the honest risk of the 512K-on-SuperPico path.

## Build

Requires the **Arm GNU embedded toolchain** (with newlib — Homebrew's
`arm-none-eabi-gcc` is compiler-only and will fail with `nosys.specs not found`),
`cmake`, and the **pico-sdk**.

```sh
export PICO_SDK_PATH=/path/to/pico-sdk           # e.g. ~/Dev/pico-sdk (v1.5.1)
export PATH="/path/to/arm-gnu-toolchain/bin:$PATH"

# 1. build the 512K ROM first (repo root):  make
# 2. generate the ROM header (bit-reversed, const -> flash):
python3 gen_rom_h.py ../build/super-mario-land.sv rom.h
# 3. build the firmware:
cmake -S . -B build && cmake --build build -j
#    -> build/superpico_sml.uf2
```

## Flash

Hold **BOOTSEL** on the Pico while plugging it in (it mounts as `RPI-RP2`), then:

```sh
picotool load build/superpico_sml.uf2 && picotool reboot
# or: cp build/superpico_sml.uf2 /Volumes/RPI-RP2
```

## Files

- `main.c` — the serve loop (`$3F0x` snoop + XIP).
- `gen_rom_h.py` — ROM → `rom.h` (bit-reversed to match the D-pin wiring).
- `CMakeLists.txt` — no `copy_to_ram`, no USB (keeps `rom[]` in flash).
- `rom.h` — generated, git-ignored (contains ROM-derived bytes; never commit — RULE 5).
