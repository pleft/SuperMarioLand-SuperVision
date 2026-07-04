#!/usr/bin/env python3
"""
Self-service tracing of the ORIGINAL Super Mario Land via PyBoy (headless).
Replaces user-driven mGBA Lua captures: script the inputs, log any memory,
save/load states for repeatable experiments at any point in any level.

RULE 5: reads the user's own ROM at runtime; nothing ROM-derived is committed.

Usage as a library:
    from gbharness import GB
    gb = GB()                      # boots to gameplay (state $00, Mario at the 1-1 start)
    gb.hold("right"); gb.run(120)  # play
    print(gb.mario(), gb.objects())# (x, y, state) and live object slots
    gb.save("star_block.state")    # reusable checkpoints (build/states/, gitignored)
"""
import io, os
from pyboy import PyBoy

ROM = os.path.join(os.path.dirname(__file__), "..", "super-mario-land-gb.gb")
STATES = os.path.join(os.path.dirname(__file__), "..", "build", "states")

class GB:
    def __init__(self, state=None, rom=ROM):
        self.pb = PyBoy(rom, window="null")
        self.m = self.pb.memory
        self._held = set()
        if state:
            with open(os.path.join(STATES, state), "rb") as f:
                self.pb.load_state(f)
        else:
            self.boot()

    def boot(self):
        for _ in range(300): self.pb.tick()
        self.pb.button_press("start"); self.run(10)
        self.pb.button_release("start"); self.run(240)

    def run(self, frames=1):
        for _ in range(frames): self.pb.tick()

    def hold(self, *btns):
        for b in btns:
            if b not in self._held:
                self.pb.button_press(b); self._held.add(b)

    def release(self, *btns):
        btns = btns or tuple(self._held)
        for b in tuple(btns):
            if b in self._held:
                self.pb.button_release(b); self._held.discard(b)

    def mario(self):
        return (self.m[0xC202], self.m[0xC201], self.m[0xFFB3])

    def objects(self, types=None):
        out = []
        for s in range(10):
            b = 0xD100 + s * 0x10
            t = self.m[b]
            if t != 0xFF and (types is None or t in types):
                out.append((s, t, self.m[b + 3], self.m[b + 2]))
        return out

    def save(self, name):
        os.makedirs(STATES, exist_ok=True)
        with open(os.path.join(STATES, name), "wb") as f:
            self.pb.save_state(f)

    def stop(self):
        self.pb.stop()

    def auto_right(self, frames, cheat_star=False, log=None):
        """Drive right with stall-detection auto-jumps. Returns per-frame camera deltas."""
        self.hold("right")
        deltas = []
        stall = 0; jf = -99; prev = self.m[0xFFA4]
        for f in range(frames):
            if cheat_star: self.m[0xC0D3] = 0xF8
            if f == jf + 22: self.pb.button_release("a")
            cur = self.m[0xFFA4]
            d = (cur - prev) & 0xFF
            if d > 128: d = 0
            deltas.append(d); prev = cur
            stall = stall + 1 if d == 0 else 0
            if stall > 6 and f > jf + 30:
                self.pb.button_press("a"); jf = f; stall = 0
            self.pb.tick()
            if log is not None: log(f)
        self.pb.button_release("a")
        return deltas
