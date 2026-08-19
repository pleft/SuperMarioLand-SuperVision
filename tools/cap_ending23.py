"""2-3 ending capture: sphere touch -> full rescue scene. Logs the state walk
with cam/scroll, BG map diffs during the exit-walk states ($1C-$21), OAM
through the room scenes ($23-$26), music/SFX writes, object slots at the
tally burst, and the room template. Runs on the iddqd nav ROM (patches touch
only invincibility/entry, not the ending)."""
from pyboy import PyBoy
import os, sys

SC = "/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/c76a93a9-4c59-42f6-b474-1056dca20b06/scratchpad"
p = PyBoy(f"{SC}/sml_iddqd3.gb", window="null", sound_emulated=False)
p.set_emulation_speed(0)
mem = p.memory
with open("build/states/gb23_end.state", "rb") as fi: p.load_state(fi)
os.makedirs(f"{SC}/end23", exist_ok=True)
mem[0xD007] = 0

frame = [0]
mus_log = []
def mus_cb(ctx):
    a = p.register_file.A
    if a: mus_log.append((frame[0], 'mus', a))
p.hook_register(3, 0x6AB9, mus_cb, None)
def sfx0_cb(ctx):
    a = p.register_file.A
    if a: mus_log.append((frame[0], 'dfe0', a))
def sfx8_cb(ctx):
    a = p.register_file.A
    if a: mus_log.append((frame[0], 'dff8', a))
p.hook_register(3, 0x6A6E, sfx0_cb, None)
p.hook_register(3, 0x6A92, sfx8_cb, None)

# --- nav to the sphere (the proven route) ---
p.button_press("a")
phase = 0
for f in range(3000):
    y, x = mem[0xC201], mem[0xC202]
    p.button_release("up"); p.button_release("down"); p.button_release("right")
    if phase == 0:
        if y < 136: p.button_press("down")
        p.button_press("right")
        if x >= 136: phase = 1
    elif phase == 1:
        p.button_press("right"); p.button_press("up")
        if y <= 76: phase = 2
    else:
        if y < 102: p.button_press("down")
        p.button_press("right")
    p.tick(1, True)
    if mem[0xFFB3] != 0x0D: break
for b in ("a", "right", "up", "down"): p.button_release(b)

# slots at the touch (is the boss alive?)
slots0 = [(i, [mem[0xD100+16*i+k] for k in range(9)]) for i in range(10)
          if mem[0xD100+16*i]]
print("slots at touch:", slots0)

statelog = []; last_state = mem[0xFFB3]
walk_log = []          # (frame, st, x, y, c0ab, c0ac, ff43) during the walk
bg_log = []            # BG map diffs during $1C-$23
oam_log = []           # OAM during $23-$26
slot_log = []          # slot morphs around the tally start
prev_bg = None
room_bg = None; room_oam = None
shots = 0
for f in range(2600):
    p.tick(1, True)
    frame[0] += 1
    st = mem[0xFFB3]
    if st != last_state:
        statelog.append((frame[0], st, mem[0xC202], mem[0xC201],
                         mem[0xC0AB], mem[0xC0AC], mem[0xFF43]))
        last_state = st
        if st == 5:
            slot_log.append((frame[0], 'tally-entry',
                [(i, [mem[0xD100+16*i+k] for k in range(9)])
                 for i in range(10) if mem[0xD100+16*i]]))
    if st == 5 and len(slot_log) and frame[0] - slot_log[0][0] in (8, 24, 48):
        slot_log.append((frame[0], 'tally+%d' % (frame[0]-slot_log[0][0]),
            [(i, [mem[0xD100+16*i+k] for k in range(9)])
             for i in range(10) if mem[0xD100+16*i]]))
    if 0x1C <= st <= 0x23 and frame[0] % 8 == 0:
        walk_log.append((frame[0], st, mem[0xC202], mem[0xC201],
                         mem[0xC0AB], mem[0xC0AC], mem[0xFF43]))
        bg = bytes(mem[0x9800:0x9C00])
        if prev_bg is not None and bg != prev_bg and st <= 0x21:
            diffs = [(i//32, i%32, prev_bg[i], bg[i])
                     for i in range(1024) if prev_bg[i] != bg[i]]
            if len(diffs) <= 12:
                bg_log.append((frame[0], st, diffs))
            else:
                bg_log.append((frame[0], st, 'BULK %d cells' % len(diffs)))
        prev_bg = bg
    if 0x23 <= st <= 0x26 and frame[0] % 8 == 0:
        oam = bytes(mem[0xFE00:0xFEA0])
        ent = [(oam[i], oam[i+1], oam[i+2], oam[i+3]) for i in range(0, 160, 4)
               if 0 < oam[i] < 160]
        if not oam_log or oam_log[-1][2] != ent:
            oam_log.append((frame[0], st, ent))
        if st == 0x26 and frame[0] % 64 == 0 and shots < 10:
            p.screen.image.convert("L").save(f"{SC}/end23/rev_f{frame[0]:05d}.png")
            shots += 1
    if st == 0x24 and room_bg is None:
        room_bg = bytes(mem[0x9800:0x9C00])
        room_oam = bytes(mem[0xFE00:0xFEA0])
        # VRAM tile data for the creature hunt later
        with open(f"{SC}/end23/vram26.bin", "wb") as fo:
            fo.write(bytes(mem[0x8000:0x9800]))
    if st in (0x15, 0x16):
        break

print("states (frame, st, x, y, c0ab, c0ac, scx):")
for e in statelog: print(" ", e)
print("walk samples:")
for e in walk_log: print(" ", e)
print("bg diffs during 1C-21:")
for e in bg_log[:40]: print(" ", e)
print("music:", mus_log)
print("slot morphs:")
for e in slot_log: print(" ", e)
print("OAM 23-26 (%d entries):" % len(oam_log))
for e in oam_log: print(" ", e)
if room_bg:
    print("room bg rows 0-17 (21 cols):")
    for r in range(18):
        print("  r%02d: %s" % (r, " ".join("%02X"%room_bg[r*32+c] for c in range(21))))
