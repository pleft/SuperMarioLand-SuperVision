# 26 — Real hardware bring-up (SuperPico cart)

The port boots and shows the title screen on a real Watara Supervision,
served by a SuperPico flash cart (RP2040-based, PCBWay-assembled). This
documents the laws learned on the way — every one cost real flash cycles.

## Hardware laws (differentially proven on the real unit)

1. **SYS_CTRL ($2026) bit3 gates the video subsystem.** While it is clear,
   VRAM writes are LOST (not buffered). Any framebuffer fill must happen
   with bit3 already set. Potator renders unconditionally and never shows
   this. (Proven: hwtest8 vs hwtest9 — identical fill, bit3 on vs off →
   stripes vs black.)
2. **Sound/DMA registers hold garbage at power-on and must be zeroed
   before/at system enable.** Every commercial boot (Block Buster $D8A7)
   zeroes $2010-$2017, $201B, $201C, $2028-$202A right after writing
   SYS_CTRL=$DF. Enabling the system (esp. bit4) without the zeroing can
   wedge the machine (hwtest11 black-screen vs hwtest3 working, only
   difference the zeroing). The port now zeroes them first thing in
   boot6_init.
3. **$2022 (LCD_DRIVE) = $0F** is written by every commercial boot; the
   panel may need it (Potator ignores it).
4. **The full port boot chain is real-hardware clean**: $C0 bank-6 write,
   8-page window copy to $1500, execution from WRAM, ZP/WRAM clears,
   build_revpix, l3vec staging, LCD regs from RAM code, $0B switch — each
   step probed individually (probe ladder M0/MA/MB/MC/MD/M1/M2, stripes
   painted from FIXED ROM after the step under test). The NMI handler ran
   throughout every probe spin (61 Hz) without harm.

## SuperPico serving facts

- The cart firmware is a polled GPIO serve loop; the ROM array must live
  in SRAM (it does: `unsigned char rom[]`, non-const → .data → copied to
  RAM by crt0). 128K images serve fine (ADDRMASK $1FFFF).
- The 250 MHz overclock in the stock firmware is load-bearing: 0/10 boots
  at stock 125 MHz.
- The prebuilt "wataragames" UF2s embed the same serve loop; disassembly
  shows our compiled firmware is instruction-identical in the hot loop.
  The historical difference in boot rates was POWER + PROCEDURE, not code.
- UF2 hygiene: a 64K game UF2 is ~152 KB, a 128K one ~283 KB. ALWAYS
  size-check after build — a stale `make` once shipped Block Buster under
  an SML name and burned a whole test session.

## Boot procedure (the reliable pattern, found by the user)

1. Flash the UF2 (BOOTSEL → drag → wait for the drive to disappear).
2. Power the Pico first (USB, or hot-insert the cart into the powered-on
   unit). The point: the RP2040 must be up and serving BEFORE the 65C02
   fetches its reset vector. The console side has no ready-gating (the
   cart-edge power pin is hard-strapped), so cold simultaneous power-up
   is a race with ~1-in-4 odds at best.
3. With the Pico pre-powered: first-try boots, consistently.

## Build pipeline (128K game UF2)

    make                       # release image build/super-mario-land.sv
    cd build/Superpico/code
    python3 bin2c.py ../../super-mario-land.sv rom.h
    cd build && touch ../main.c && make -j8
    # verify: wc -c SUPERPICO.uf2  -> must be > 280000 for a 128K image
    cp SUPERPICO.uf2 ~/Desktop/<NAME>.uf2

Marker/probe builds: assemble with `-D HWMARKER0/1/2`, `-D HWMA/MB/MC/MD`
(+ `-D NOSPLASH -D HWMARK` for the FIXED-space donors), link against the
release data objects, and pass `-Ln build/<x>.lbl` — pack_banks needs the
label dump beside the map.

## Open questions

- Audio on real hardware: the port never sets SYS_CTRL bit4 (Block Buster
  runs with $DF = bit4 on). If the unit is silent, try adding bit4 to the
  runtime SYS_CTRL values.
- Overlay VRAM writes from $1500 execution during gameplay (1-3 kit, W2
  kit): the boot-phase probes prove WRAM execution + register writes;
  in-game overlay drawing is exercised the moment 1-3/W2 run on hardware.
