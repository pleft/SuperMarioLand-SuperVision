"""1-3 ending variant B: boss ALIVE at the sphere. Fly over him (pin only for
the pass), unpin at the pedestal, touch the sphere. Log the bridge BG row per
frame + the boss slot + OAM + music/SFX; dump the rescue-room map + OAM."""
from pyboy import PyBoy
import os

SC = "/private/tmp/claude-501/-Users-pleft-Dev-SuperMarioLand/c76a93a9-4c59-42f6-b474-1056dca20b06/scratchpad"
p = PyBoy("super-mario-land-gb.gb", window="null", sound_emulated=False)
p.set_emulation_speed(0)
mem = p.memory
with open(f"{SC}/gb13_preboss.state", "rb") as fi: p.load_state(fi)
os.makedirs(f"{SC}/end13b", exist_ok=True)

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

p.button_press("right")
statelog = []; last_state = -1
bridge_log = []
prev_bridge = None
boss_log = []
room_bg = None; room_oam = None
died = False
for f in range(4800):
    st = mem[0xFFB3]
    x = mem[0xC202]
    boss = next((i for i in range(10) if mem[0xD100+16*i] == 8), None)
    if st == 0:
        mem[0xDA15] = 5
        if mem[0xC0AB] < 149:
            mem[0xC0D3] = 0xF8   # star through the approach (Gaos, fireballs)
        else:
            mem[0xC0D3] = 0      # star OFF at the arena: the boss must live
        # Fly over the pass with the BOSS frozen at his cycle's grounded phase:
        if mem[0xC0AB] >= 149 and x <= 126:
            mem[0xC201] = 0x48
            if boss is not None:
                mem[0xD100+16*boss+2] = 120
                mem[0xD100+16*boss+4] = 8
        if mem[0xC201] > 0x98: mem[0xC201] = 0x30
        if f % 44 == 0: p.button_press("a")
        if f % 44 == 26: p.button_release("a")
    else:
        p.button_release("right"); p.button_release("a")
    p.tick(1, True)
    frame[0] += 1
    st = mem[0xFFB3]
    if st != last_state:
        statelog.append((frame[0], st, mem[0xC202], mem[0xC201]))
        last_state = st
    # bridge row watch: BG map row 14, only once the camera freezes (state>0)
    br = bytes(mem[0x9800+14*32:0x9800+15*32]) if mem[0xFFB3] else prev_bridge
    if br is not None and br != prev_bridge:
        if prev_bridge is not None:
            diffs = [(i, prev_bridge[i], br[i]) for i in range(32) if prev_bridge[i] != br[i]]
            if diffs:
                bridge_log.append((frame[0], st, diffs))
        prev_bridge = br
    bany = next((i for i in range(10) if mem[0xD100+16*i] in (8, 0x27)), None)
    if f % 2 == 0 and bany is not None:
        b = [mem[0xD100+16*bany+k] for k in (0,1,2,3,4,5,6,7,8)]
        if not boss_log or boss_log[-1][1] != b:
            boss_log.append((frame[0], b, st))
    if st in (5, 6) and frame[0] % 8 == 0:
        p.screen.image.convert("L").save(f"{SC}/end13b/fall_f{frame[0]:05d}_st{st:02x}.png")
    if st == 0x26 and frame[0] % 8 == 0:
        oam = bytes(mem[0xFE00:0xFEA0])
        ent = [(oam[i], oam[i+1], oam[i+2], oam[i+3]) for i in range(0,160,4)
               if 0 < oam[i] < 160 and oam[i+2] not in (0,1,0x10,0x11)]
        bridge_log.append((frame[0], 'oam26', ent))
        if frame[0] % 64 == 0:
            p.screen.image.convert("L").save(f"{SC}/end13b/rev_f{frame[0]:05d}.png")
    if st == 0x24 and room_bg is None:
        room_bg = bytes(mem[0x9800:0x9C00])
        room_oam = bytes(mem[0xFE00:0xFEA0])
    if st in (0x15, 0x16):
        break
    if mem[0xDA15] < 5 and st == 0:
        pass
print("states:", statelog)
print("music:", mus_log)
print("bridge row changes (frame, st, [(col, old, new)...]):")
for e in bridge_log[:40]: print(" ", e)
print("boss slot walk after touch (frame, fields, st):")
touch = next((fr for fr,st,_,_ in statelog if st == 7), 10**9)
for e in boss_log:
    if e[0] >= touch - 30: print(" ", e)
if room_bg:
    print("room bg rows 0-17 (visible 20 cols):")
    for r in range(18):
        print("  r%02d: %s" % (r, " ".join("%02X"%room_bg[r*32+c] for c in range(21))))
    print("room OAM (y,x,tile,attr):")
    for i in range(0, 160, 4):
        y,x,t,a = room_oam[i:i+4]
        if 0 < y < 160: print("   %3d %3d %02X %02X" % (y,x,t,a))
