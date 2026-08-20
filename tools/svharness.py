"""py65 harness for the banked SV image (64K-512K): loads [bank0][last-16K=fixed],
watches the mapper regs and remaps $8000-$BFFF on bank change: SYS_CTRL
($2026) bits 7:5 below 128K, or MAGNUM ($2021 low nibble + $2026 bit5) above it.

Usage (run from the repo root; needs the -g debug build's build/dbg.txt):
    from svharness import Harness
    h = Harness(); h.boot_to_game()          # title -> Start -> 1-1 settled
    # enter any level via the game's own next_level:
    ml, nl = h.sym('main_loop'), h.sym('next_level')
    ...push ml-1, set pc=nl, run_to(...)
Rebuild build/dbg.txt after ANY code move (a stale main_loop = apparent hang)."""
import re
from py65.devices.mpu65c02 import MPU

ROM_PATH = "build/super-mario-land.sv"
DBG_PATH = "build/dbg.txt"

class Harness:
    def __init__(self, rom=ROM_PATH, dbg=DBG_PATH):
        self.file = open(rom, "rb").read()
        assert len(self.file) % 0x4000 == 0 and len(self.file) >= 0x8000
        self.dbg = open(dbg).read()
        self.mem = bytearray(0x10000)
        self.cur_bank = 0
        self.magnum = len(self.file) > 131072   # Potator: isMAGNUM
        self.mag_page = 0
        self.prev21 = 0
        self.mem[0x8000:0xC000] = self.file[0:0x4000]
        self.mem[0xC000:0x10000] = self.file[-0x4000:]
        self.mpu = MPU()
        self.mpu.memory = self.mem
        self.mpu.pc = self.mem[0xFFFC] | (self.mem[0xFFFD] << 8)
        self.mem[0x2020] = 0xFF
        self.frame = 0
        self.steps = 0

    def sym(self, n):
        for m in re.finditer(r'name="%s",([^\n]*)' % n, self.dbg):
            mm = re.search(r'val=(0x[0-9A-Fa-f]+)', m.group(1))
            if mm: return int(mm.group(1), 16)
        raise KeyError(n)

    def _bank_check(self):
        # Two mappers, exactly as Potator picks them (memorymap.c):
        #   isMAGNUM = size > 131072  -> bankOffset = (r26 & $20)<<9 | (r21 & $F)<<15
        #   else                      -> bankOffset = (r26 & $E0)<<9   (3 bits, 128K)
        # The MAGNUM page is latched AT THE $2021 WRITE and only while $2022 == 0
        # (Potator never re-evaluates it on a $2022 write), which is what lets the
        # game restore the panel's LCD_DRIVE value straight afterwards.
        if self.magnum:
            r21 = self.mem[0x2021] & 0x0F
            if r21 != self.prev21:
                self.prev21 = r21
                if self.mem[0x2022] == 0:
                    self.mag_page = r21
            off = (self.mag_page << 15) | ((self.mem[0x2026] & 0x20) << 9)
        else:
            off = (self.mem[0x2026] & 0xE0) << 9
        if off != self.cur_bank:
            self.cur_bank = off
            o = off % len(self.file)            # Potator: bankOffset % programRomSize
            self.mem[0x8000:0xC000] = self.file[o:o + 0x4000]

    def _dma(self):
        if self.mem[0x200D] & 0x80:
            s0 = self.mem[0x2008] | (self.mem[0x2009] << 8)
            d = self.mem[0x200A] | (self.mem[0x200B] << 8)
            for i in range(self.mem[0x200C] * 16):
                self.mem[(d + i) & 0xFFFF] = self.mem[(s0 + i) & 0xFFFF]
            self.mem[0x200D] &= 0x7F

    def run_to(self, n):
        while self.frame < n:
            self.mpu.step(); self.steps += 1
            if self.steps % 120_000 == 0:
                self.mem[0] = 1
                self.mem[1] = (self.mem[1] + 1) & 0xFF
                self.frame += 1
            self._dma()
            self._bank_check()

    def boot_to_game(self):
        """title -> Start at frame 240 -> settled gameplay at frame 300"""
        self.run_to(240)
        self.mem[0x2020] = 0x7F
        self.run_to(248)
        self.mem[0x2020] = 0xFF
        self.run_to(300)

    def snapshot(self):
        return (bytes(self.mem), (self.mpu.pc, self.mpu.a, self.mpu.x, self.mpu.y,
                self.mpu.sp, self.mpu.p), (self.frame, self.steps), self.cur_bank)

    def restore(self, snap):
        m, cpu, fs, bank = snap
        self.mem[:] = m
        (self.mpu.pc, self.mpu.a, self.mpu.x, self.mpu.y, self.mpu.sp, self.mpu.p) = cpu
        self.frame, self.steps = fs
        self.cur_bank = bank

    def dump_screen(self, path, scroll=None):
        """render the VISIBLE 160x160 window: fb pixels scroll..scroll+159 per
        line (the hardware applies XSCROLL; a fb-origin dump hid a 32px offset
        at level ends, where scroll_s pins at 32)."""
        if scroll is None:
            try:
                scroll = self.mem[self.sym('scroll_vis')]
            except Exception:
                scroll = 0
        vram = self.mem[0x4000:0x6000]
        shades = [255, 170, 85, 0]
        rows = []
        for y in range(160):
            row = []
            base = y * 48
            s = 0 if y < 16 else scroll   # the line-16 raster split: HUD unscrolled
            for px in range(s, s + 160):
                b = vram[base + (px >> 2)]
                row.append(shades[(b >> ((px & 3) * 2)) & 3])
            rows.append(row)
        with open(path, "wb") as f:
            f.write(b"P5\n160 160\n255\n")
            for r in rows: f.write(bytes(r))
