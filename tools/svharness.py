"""py65 harness for the 64K banked SV image: loads [bank0][fixed], watches
SYS_CTRL ($2026) bits 7:5 and remaps $8000-$BFFF on bank change.

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
        assert len(self.file) == 65536
        self.dbg = open(dbg).read()
        self.mem = bytearray(0x10000)
        self.cur_bank = 0
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
        b = (self.mem[0x2026] >> 5) & 7
        if b != self.cur_bank:
            self.cur_bank = b
            self.mem[0x8000:0xC000] = self.file[b * 0x4000:(b + 1) * 0x4000]

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

    def dump_screen(self, path):
        """render the visible 160x160 4-shade framebuffer (48B stride) to a PGM"""
        vram = self.mem[0x4000:0x6000]
        shades = [255, 170, 85, 0]
        rows = []
        for y in range(160):
            row = []
            base = y * 48
            for bx in range(40):
                b = vram[base + bx]
                for p in range(4):
                    row.append(shades[(b >> (p * 2)) & 3])
            rows.append(row)
        with open(path, "wb") as f:
            f.write(b"P5\n160 160\n255\n")
            for r in rows: f.write(bytes(r))
