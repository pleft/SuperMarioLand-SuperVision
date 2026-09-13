/* SuperPico firmware for the Super Mario Land -> Watara Supervision port.
 *
 * Serves the game from SRAM (the 512K MAGNUM image is compacted to ~224K by
 * dropping the fill -- see gen_rom_h.py -- which fits the RP2040's 264K SRAM;
 * XIP flash was too slow for the SV bus and would not boot).
 *
 * MAGNUM banking: SuperPico cannot see register-write DATA and does not route
 * #WR (docs/28), so the ROM announces every bank switch with a harmless write
 * to $3F00+page (src/magbank.inc). A single-core serve loop MISSES some of
 * those writes: while it is busy driving the data bus for a read (~100ns), it
 * is not sampling the bus, and a brief write cycle slips by -> a stale bank ->
 * corrupt tiles + freeze on the first banked read (seen on hardware).
 *
 * Fix (docs/28's own approach): DEDICATE CORE 1 to snooping. It does nothing
 * but poll the address bus (~1 sample / 20ns), so it catches every $3F0x write
 * and publishes the page as g_bankOffset. CORE 0 runs the serve loop and reads
 * g_bankOffset. 32-bit aligned, single-writer/single-reader -> access is atomic.
 *
 * Cart-edge map (docs/28): GP0..GP16=A0..A16; D0..D7=GP 27,26,22,21,20,19,18,17
 * (rom[] bit-reversed to match); GP28=#RD (low=cart read).
 * SV cart map: $8000-$BFFF = banked 16K (page P), $C000-$FFFF = FIXED.
 */
#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/gpio.h"
#include "rom.h"          /* const unsigned char rom[]; NBANKS; FIXEDOFF; ROMSIZE */

#define NRD        28
#define READMASK   (1u << NRD)
#define DATAMASK   ((1u<<17)|(1u<<18)|(1u<<19)|(1u<<20)|(1u<<21)|(1u<<22)|(1u<<26)|(1u<<27))
/* Magic bank-select = a WRITE to $3F00+page (src/magbank.inc). The snag was that
 * matching only the low 14 address bits ($3F0x) also matched cart READS of
 * $BF0x/$FF0x -> false bank switches -> corrupt tiles. Clean discriminator: the
 * whole cart lives at $8000-$FFFF (A15=1), while $3F00 is below it (A15=0). A0-A15
 * are the bits the serve path already proves reliable, so matching the full
 * 16-bit address (A15=0) excludes every cart read -- no need for the flaky A16
 * "forcing". MAGIC_MASK keeps A5..A15 (drops the low 5 = the page). */
#define MAGIC_MASK 0xFFE0u
#define MAGIC_SIG  0x3F00u
/* plus a 2-sample debounce (same page twice) to reject any bus-transition glitch */

static volatile unsigned int g_bankOffset = 0;   /* compacted base of $8000 window */

static void initGPIO(void) {
  for (int p = 0; p <= 16; p++) { gpio_init(p); gpio_set_dir(p, GPIO_IN); }
  gpio_init(NRD); gpio_set_dir(NRD, GPIO_IN);
  const int dpins[8] = {27,26,22,21,20,19,18,17};
  for (int i = 0; i < 8; i++) { gpio_init(dpins[i]); gpio_set_dir(dpins[i], GPIO_IN); }
}

/* CORE 1: nothing but bus snooping -> catches every $3F00+page write. */
static void snoop_core(void) {
  int prev = -1;                                  /* page seen last sample, or -1 */
  for (;;) {
    unsigned int g = gpio_get_all();
    int cur = -1;
    if ((g & READMASK) && ((g & MAGIC_MASK) == MAGIC_SIG))  /* #RD high + full addr $3F0x */
      cur = (int)(g & 0x1F);                       /* the page */
    if (cur >= 0 && cur == prev && cur < NBANKS)  /* two consecutive, same page */
      g_bankOffset = (unsigned int)cur << 14;     /* publish the compacted 16K bank base */
    prev = cur;
  }
}

/* CORE 0: serve reads from SRAM. */
int main(void) {
  set_sys_clock_khz(250000, false);              /* 250MHz overclock -- load-bearing */
  initGPIO();
  multicore_launch_core1(snoop_core);

  for (;;) {
    unsigned int g = gpio_get_all();
    if (!(g & READMASK)) {                        /* #RD low: cart read -> drive the bus */
      gpio_set_dir_out_masked(DATAMASK);
      unsigned int a   = g & 0xFFFF;
      unsigned int off = a & 0x3FFF;
      unsigned char b  = (a & 0x4000) ? rom[FIXEDOFF + off]
                                      : rom[g_bankOffset + off];
      gpio_put_all(((b & 0x3F) << 17) | ((b & 0xC0) << 20));
    } else {
      gpio_set_dir_in_masked(DATAMASK);           /* release the data bus */
    }
  }
  return 0;
}
