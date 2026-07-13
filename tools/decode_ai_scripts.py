#!/usr/bin/env python3
"""
Decode Super Mario Land enemy/object AI movement scripts from the user's ROM.
RULE 5: ships as a tool; output (ROM-derived) is printed / written under build/.

The AI VM (interpreter = ObjectPhysicsAndScript $2676) reads a per-type script of
bytes from AIScriptPtrTable @ $349E. Opcodes (see docs/12-enemies.md):
  $00-$DF        : set velocity ($FFC1), mark active
  $E0-$EF        : set movement-state ($FFC8 = low nibble)
  $F0 nn         : facing / track player
  $F1            : spawn sub-object
  $F2 nn         : set acceleration ($FFC7)
  $F3 nn         : change object type ($FFC0 -> new script; $FF = despawn)
  $F4 nn         : set $FFC9
  $F5 nn         : conditional (variant)
  $F6 nn         : jump (set script PC $FFC4 = nn)
  $F8 nn         : set param ($FFC6)
  $FF            : loop (reset PC to 0)
"""
import sys, hashlib

EXPECT_SHA1 = "418203621b887caa090215d97e3f509b79affd3e"
AISCRIPT_TABLE = 0x349E      # bank 0 (file offset == addr)
NUM_TYPES = 99   # PhysicsParamTable $3375..$349E = 99*3 bytes, AIScriptPtrTable $349E..$3564 = 99*2

# opcode -> (mnemonic, operand_bytes)
OPS = {
    0xF0: ("face/track", 1), 0xF1: ("spawn", 0), 0xF2: ("set_accel", 1),
    0xF3: ("morph_type", 1), 0xF4: ("set_ffc9", 1), 0xF5: ("cond", 1),
    0xF6: ("jump_pc", 1), 0xF8: ("set_param", 1), 0xFF: ("loop", 0),
}

def decode_script(d, addr, maxlen=64):
    out = []
    pc = addr
    seen = set()
    while pc - addr < maxlen:
        if pc in seen:            # jumped back — stop
            out.append((pc, "-> (jump target already seen) stop", []))
            break
        seen.add(pc)
        op = d[pc]
        if op in OPS:
            name, nopnd = OPS[op]
            opnd = [d[pc + 1 + k] for k in range(nopnd)]
            out.append((pc, f"{op:02X} {name}", opnd))
            pc += 1 + nopnd
            if op == 0xFF:
                break
        elif 0xE0 <= op <= 0xEF:
            out.append((pc, f"{op:02X} set_state {op & 0x0F}", []))
            pc += 1
        else:
            sv = op - 256 if op > 127 else op    # signed velocity
            out.append((pc, f"{op:02X} velocity=${op:02X} ({sv:+d})", []))
            pc += 1
    return out

def main():
    rom = sys.argv[1] if len(sys.argv) > 1 else "super-mario-land-gb.gb"
    d = open(rom, "rb").read()
    if hashlib.sha1(d).hexdigest() != EXPECT_SHA1:
        print("WARNING: ROM SHA1 mismatch")
    print(f"AI scripts (table @ ${AISCRIPT_TABLE:04X}):")
    for t in range(NUM_TYPES):
        ptr = d[AISCRIPT_TABLE + t * 2] | (d[AISCRIPT_TABLE + t * 2 + 1] << 8)
        if not (0x150 <= ptr < 0x4000):
            continue
        print(f"\n--- type ${t:02X} -> script @ ${ptr:04X} ---")
        for addr, txt, opnd in decode_script(d, ptr):
            ops = " ".join(f"${b:02X}" for b in opnd)
            print(f"  ${addr:04X}: {txt}{('  ' + ops) if ops else ''}")

if __name__ == "__main__":
    main()
