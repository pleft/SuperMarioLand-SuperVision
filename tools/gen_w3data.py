#!/usr/bin/env python3
"""Extract the World-3 enemy AI scripts + metasprite display lists from the
user's ROM for the port's AI-VM (docs/34).

Emits:
  build/w3scripts.bin   raw script bytes, concatenated (packed into bank 6)
  build/w3data.inc      assembly: the type table, per-type script offsets, and
                        the metasprite display lists (they live in the kit's
                        RAM window; the scripts stay in bank 6)

RULE 5: reads the ROM only as a build input; every output is gitignored.
"""
import os, sys, os

ROM = open(sys.argv[1] if len(sys.argv) > 1 else "super-mario-land-gb.gb", "rb").read()
# WORLD 3 or 4: each world gets its own data set (scripts, display lists, tile
# slice, tables) because they live in that world's COLD BANK and its sprite
# overlay differs -- and because one shared slice cannot hold both rosters
# (68 tile slots; World 4 alone needs 9 more than World 3 leaves free).
WORLD = int(sys.argv[2]) if len(sys.argv) > 2 else 3
OUT_BIN = f"build/w{WORLD}scripts.bin"
OUT_INC = f"build/w{WORLD}data.inc"
SCRIPT_TBL = 0x349E                       # AIScriptPtrTable, 99 entries
DL_RIGHT, DL_LEFT = 0x2FE2, 0x30B4        # metasprite display lists
PHYS_TBL = 0x3375                         # 3 bytes per type
CONTACT_TBL = 0x3186                      # 5 bytes per type; +0 = the STOMP result
                                          # (0 = not stompable: the GB's stomp test
                                          # at $08C7 reads this column)

# every GB type W3's spawn lists name (types the ENGINE already handles --
# $00/$04/$0A/$0B/$0E/$36 -- and the shared kit types $02/$0C are excluded)
# exactly the VM types W3's spawn lists name (measured from the packed
# spawn binaries -- $05 and $56 are NOT among them; seeding them dragged in
# whole chains of scripts, params and tiles that can never appear)
SEEDS = {
    # World 3 (levels 6-8), unchanged
    3: [0x03, 0x25, 0x31, 0x32, 0x35, 0x38, 0x39,
        0x3A, 0x3B, 0x3C, 0x47, 0x49],
    # World 4 (levels 9-11), from the spawn lists (docs/45): the lifts and the
    # Piranha it shares with W3, plus $55 upside-down Piranha, $56 Pionpi
    # (stomp -> $57, which morphs BACK to $56: it gets up again), and 4-2/4-3's
    # $4B $4D $52 $53 $54 $59 and the boss $61.
    # 4-1: $38/$39 lifts, $49 Piranha, $55 upside-down Piranha, $56 Pionpi.
    # 4-2 adds $3A (a lift it shares with W3), $3F (Gao -- a VM type here: the
    # EAS3 build compiles out the native $3F handler), $54. The 24-type closure
    # fits the $1500 window with ~79 B to spare (docs/45); 4-3's types ($4D $52
    # $53 $59 $61) push it over and force the table relocation, added with 4-3.
    4: [0x38, 0x39, 0x49, 0x55, 0x56, 0x3A, 0x3F, 0x54, 0x09],   # 4-1 + 4-2 only (pages 9/10); $09 = the Pompon Flower (4-2), child $51 pollen
    # "World 43" = 4-3 alone (its own page pair 11/12 and kit w43code): $53 $52
    # (spawns $50 -> $5A), $59, $54, $4D, $06 (two bobbing hazards before the
    # arena), the boss $61 and its death chain $62 $5B $60 $5C..; sharing one W4
    # data set put every 4-3 type into 4-1/4-2's cold page, which had 4 bytes
    # left (the $06 alone pushed the script blob 16 B into the dlist pin).
    43: [0x4D, 0x52, 0x53, 0x54, 0x59, 0x61, 0x06],
}


def flat(addr):
    """script/display-list pointers are bank-0/1 flat in the first 32K"""
    return addr


def script_bytes(t):
    p = SCRIPT_TBL + t * 2
    a = ROM[p] | (ROM[p + 1] << 8)
    off = flat(a)
    i, n = off, 0
    while n < 240:
        b = ROM[i]
        if b == 0xFF:
            return ROM[off:i + 1]          # keep the $FF (loop-to-start)
        i += 2 if 0xF0 <= b <= 0xFE else 1
        n += 1
    raise SystemExit(f"script ${t:02X}: no terminator")


def dlist(param, base):
    p = base + param * 2
    a = ROM[p] | (ROM[p + 1] << 8)
    off = flat(a)
    i = off
    while ROM[i] != 0xFF and i - off < 48:
        i += 1
    return ROM[off:i + 1]


def ents(p, base=DL_RIGHT):
    """decoded (dy, dx) entries of a display list, for extent maths"""
    q = base + p * 2
    a = ROM[q] | (ROM[q + 1] << 8)
    dy = dx = 0
    out = []
    i = a
    while ROM[i] != 0xFF and i - a < 48:
        b = ROM[i]; i += 1
        if b & 0x80:
            out.append((dy, dx))
        else:
            dy += (-8 if b & 8 else 0) + (8 if b & 4 else 0)
            dx += (-8 if b & 2 else 0) + (8 if b & 1 else 0)
    return out

def main():
    # transitive closure over morph ($F3) / spawn-child ($F1) targets
    types, todo = [], list(SEEDS[WORLD])
    params = set()
    while todo:
        t = todo.pop(0)
        if t in types or t > 0x7F:
            continue
        types.append(t)
        for c in range(5):                    # contact results are types too
            r = ROM[CONTACT_TBL + 5 * t + c]  # (stomp/ball/star chains)
            if 0 < r <= 0x7F:
                todo.append(r)
        b = script_bytes(t)
        i = 0
        while i < len(b):
            op = b[i]
            if 0xF0 <= op <= 0xFE:
                arg = b[i + 1] if i + 1 < len(b) else 0
                if op == 0xF8:
                    params.add(arg)
                if op in (0xF1, 0xF3) and arg <= 0x7F:
                    todo.append(arg)          # morph / spawn-child targets
                i += 2
            else:
                i += 1
    types.sort()
    params = sorted(params)

    # COVERAGE (law E48, 2026-09-06): every type the world's packed spawn lists
    # name must be a native engine type or in this closure. The spawner consumes
    # what it does not know without a fault -- 4-2's three Pompon Flowers ($09)
    # were missing for weeks because $09 sat between "engine native" and "seeded".
    NATIVE = {0x00, 0x02, 0x04, 0x08, 0x0A, 0x0B, 0x0C, 0x0E, 0x36, 0x42}   # spawn_check
    WORLD_LEVELS = {3: (6, 7, 8), 4: (9, 10), 43: (11,)}[WORLD]
    for lv in WORLD_LEVELS:
        d = open(f"build/levels/level_{lv:02d}_spawns.bin", "rb").read()
        named = sorted(set(d[i + 3] for i in range(0, len(d) - 4, 5)))
        missing = [t for t in named if t not in NATIVE and t not in types]
        assert not missing, (f"W{WORLD} level {lv}: spawn list names types "
                             f"{[f'${t:02X}' for t in missing]} that neither the engine "
                             f"nor the kit closure handles -- add them to SEEDS[{WORLD}]")

    blob = bytearray()
    offs = {}
    for t in types:
        offs[t] = len(blob)
        blob += script_bytes(t)
    os.makedirs("build", exist_ok=True)
    open(OUT_BIN, "wb").write(bytes(blob))

    with open(OUT_INC, "w") as f:
        f.write("; generated by tools/gen_w3data.py -- W3 AI-VM data (docs/34)\n")
        f.write(f"W3_NTYPES = {len(types)}\n")
        f.write(f"W3_SCRIPTS_LEN = {len(blob)}\n")
        # the per-type tables live in the RESIDENT bank (segment W3TAB, $B000):
        # every reader runs with it mapped, and the $1500 window could not hold
        # 4-3's 43-type closure (docs/45)
        f.write('.segment "W3TAB"\n')
        f.write("; GB type id per VM index\n")
        f.write("w3_typetab:\n    .byte " + ",".join(f"${t:02X}" for t in types) + "\n")
        f.write("; script offset within the bank-6 blob, per VM index\n")
        f.write("w3_scrlo:\n    .byte " + ",".join(f"<{offs[t]}" for t in types) + "\n")
        f.write("w3_scrhi:\n    .byte " + ",".join(f">{offs[t]}" for t in types) + "\n")
        f.write("; PhysicsParamTable rows: [0] = the COLLISION-RESPONSE flags the VM\n")
        f.write("; reads as ffc7 ($30 -> restart the script on landing, etc.)\n")
        f.write("w3_phys0:\n    .byte " + ",".join(f"${ROM[PHYS_TBL+3*t]:02X}" for t in types) + "\n")
        f.write("w3_phys1:\n    .byte " + ",".join(f"${ROM[PHYS_TBL+3*t+1]:02X}" for t in types) + "\n")
        f.write("w3_phys2:\n    .byte " + ",".join(f"${ROM[PHYS_TBL+3*t+2]:02X}" for t in types) + "\n")
        f.write("; contact table $3186 column +0: the type to MORPH INTO when\n")
        f.write("; stomped ($00 = not stompable -- Mario passes through the head)\n")
        # Superball column (contact row byte 3, GB $2A68/$2A89) as sparse
        # (type index, morph type, phys byte2) rows, $FF-terminated. The rows are
        # indexed by w3_ti, a PER-WORLD index, so the table is per-world: each
        # world's rows are pasted at the SAME pin ($B520, main.s w3_ballt) in its
        # own resident bank (pack_banks bank 1 / pack_w4 page 9) and the mapped
        # bank selects the right one.  (It used to be one .inc in FIXED, written
        # unconditionally by both gen runs: whichever world ran last won, and the
        # other world's Superball kills were mis-indexed.)
        ball = bytearray()
        for i, t in enumerate(types):
            b3 = ROM[CONTACT_TBL + 5 * t + 3]
            if b3:                           # + phys byte2: HP (& $3F) and score class (>> 6)
                ball += bytes((i, b3, ROM[PHYS_TBL + 3 * t + 2]))
        ball.append(0xFF)
        assert len(ball) <= 0x20, \
            f"w{WORLD} ball table {len(ball)}B > 32B pin gap ($B520..$B53F)"
        open(f"build/w{WORLD}ball.bin", "wb").write(bytes(ball))
        f.write("w3_stomp:\n    .byte " + ",".join(f"${ROM[CONTACT_TBL+5*t]:02X}" for t in types) + "\n")
        f.write("; contact table column +2: the SIDE-contact result -- $FF hurts,\n")
        f.write("; $00 does NOTHING, anything else morphs the slot into that type.\n")
        f.write("; Column +0 being zero means 'not stompable', which is NOT the same\n")
        f.write("; as 'hurts': $27/$0D (the corpses), $49 (the moai pillar), $3E and\n")
        f.write("; $36 are all harmless on every side, and treating them as hurtful\n")
        f.write("; killed Mario when he bounced on a corpse (user-reported).\n")
        f.write("w3_side:\n    .byte " + ",".join(f"${ROM[CONTACT_TBL+5*t+2]:02X}" for t in types) + "\n")
        if WORLD >= 4:
            # contact column +4 = the TORPEDO/missile result (GB $2aad, State_0D):
            # 4-3's Sky Pop missiles kill VM types through it (kit_sky43 torp_hit)
            f.write("; contact table column +4: what a MISSILE turns the type into\n")
            f.write("w3_torpt:\n    .byte " + ",".join(f"${ROM[CONTACT_TBL+5*t+4]:02X}" for t in types) + "\n")
        # display lists: index by param through a compact table
        f.write(f"W3_NPARAM = {len(params)}\n")
        f.write('.segment "W3X"\n')   # the draw walk executes under BANK 6 (docs/42)
        f.write("w3_paramtab:\n    .byte " + ",".join(f"${p:02X}" for p in params) + "\n")
        # COMPACT tile slice: the lists reference GB overlay tiles $A0-$DC;
        # ship only the ones actually drawn, renumbered to a contiguous port
        # range from $A0 (draw_quad resolves $A0-$DC through the header's
        # overlay base). Tiles < $A0 come from the shared chardata sheet and
        # keep their GB ids.
        order, remap = [], {}
        # The slice is ID-PRESERVING for the GB overlay range: slot $A0..$DC
        # holds overlay tile $A0..$DC (pack_banks: w3_ovl_8A00), because the
        # ENGINE draws its own objects through draw_quad with raw ids -- 3-2's
        # Fly is tiles $A0-$A3/$B0-$B3 -- and a compact, renumbered slice
        # handed it the lift/missile/Kumo tiles (user: "garbled sprite", "its
        # corpse is a fly"). Ids OUTSIDE $A0-$DC that the kit lists reference
        # ($DF Kumo, $EF, $FE, the missile's $F9-$FB, ...) are parked in slots
        # no W3 list and no engine object uses; pack_banks sources their pixels
        # (w3_hi.svt for the missile, w1_obj_8000.svt otherwise).
        ENGINE_IDS = {0xA0, 0xA1, 0xA2, 0xA3, 0xB0, 0xB1, 0xB2, 0xB3,  # the Fly (W3: the Kumo)
                      0xA8, 0xA9}                                    # its squashed corpse (FLY_SQ)
        PARK_END = 0xEC if WORLD >= 4 else 0xE4   # (see below)
        raw = []
        for p in params:
            raw.append(dlist(p, DL_RIGHT)); raw.append(dlist(p, DL_LEFT))
        used = set(b for l in raw for b in l if b & 0x80 and b != 0xFF)
        # ids INSIDE the band keep their own slot (draw_quad resolves $A0..top-1
        # through the slice at the id itself); only ids at/after the band top need
        # a parking slot -- so $E2/$E3 no longer consume two of them (4-3)
        extra = sorted(b for b in used if b >= PARK_END)
        # parking slots after the overlay: World 3 has 7 ($DD-$E3; the slice ends
        # exactly at $BB80 where creature33 sits in bank 6). World 4's cold page has
        # nothing at $BB80-$BBFF, so it parks 15 ($DD-$EB) -- 4-3's 43-type closure
        # needs 8 (the W3 count was measured 8 vs 7 for it, docs/45). The slice then
        # ends exactly at $BC00 (the W3X walk pin).
        # ids the FIXED engine draws THROUGH the band from the base sheet: the
        # Superball Flower's two frames ($E0/$E5, upd_flower). Parking over them
        # drew the flower as a missile piece in every W3/W4 level (user, 4-2:
        # "a garbled graphic that when I picked it up nothing happened" -- big
        # Mario's flower gives no visible change). Never a parking slot.
        FIXED_BAND_IDS = {0xE0, 0xE5}
        free = [i for i in range(0xDD, PARK_END) if i not in used and i not in FIXED_BAND_IDS] + \
               [i for i in range(0xA0, 0xDD) if i not in used and i not in ENGINE_IDS]
        assert len(extra) <= len(free), f"W{WORLD}: {len(extra)} out-of-range tile ids, {len(free)} free slots"
        remap = {b: free[k] for k, b in enumerate(extra)}
        order = list(range(0xA0, PARK_END))  # $A0-$DC overlay + the parking slots
        for b, slot in remap.items():
            order[slot - 0xA0] = b
        def conv(lst):
            return bytearray(remap.get(b, b) if (b & 0x80 and b != 0xFF) else b for b in lst)
        # each param's RIGHT list is followed immediately by its LEFT list, so
        # one pointer serves both: the draw walks past the $FF terminator to
        # reach the left-facing form (that saves a whole pointer table, and the
        # RAM window has no room to spare)
        body = bytearray()
        starts = []
        for p in params:
            starts.append(len(body))
            body += conv(dlist(p, DL_RIGHT))
            body += conv(dlist(p, DL_LEFT))
        open(f"build/w{WORLD}tiles.txt", "w").write(" ".join(f"{t:02X}" for t in order))
        assert len(order) == PARK_END - 0xA0, f"W{WORLD} tile slice must be the full $A0..{PARK_END-1:02X} table (draw_quad quad_top)"
        f.write("; display lists live in BANK 6 at W3DLB (pack_banks pin)\n")
        f.write("w3_dlo:\n    .byte " + ",".join(f"<(W3DLB+{s})" for s in starts) + "\n")
        f.write("w3_dhi:\n    .byte " + ",".join(f">(W3DLB+{s})" for s in starts) + "\n")
        f.write('.segment "W3TAB"\n')  # the exception tables join the resident tables
        # the left-facing pointers live in the bank-RESIDENT far segment: the
        # RAM window needs its space for the hot code (they are read before
        # any bank switch, so residency is safe)

        open(f"build/w{WORLD}dlists.bin", "wb").write(bytes(body))
        # --- erase exceptions -------------------------------------------
        # The kit erases W3 objects with a default box (8px left of the
        # anchor, 24px tall). A few metasprites are bigger; list ONLY those,
        # with the y-origin adjust (in 8px rows) and the engine's width byte
        # (bit7 = +1 row, bit6 = +1, bit5 = +2, low bits = 8px columns).
        # (the tight-$84 default experiment is REVERTED: the Batadon's 40px
        # wing band under-erased and trailed -- user-caught on the first kill.
        # Back to the proven conservative default; exceptions only for BIGGER.)
        exc = []
        for p in params:
            e = ents(p)
            if not e:
                continue
            miny = min(y for y, _ in e); maxy = max(y for y, _ in e) + 8
            minx = min(x for _, x in e); maxx = max(x for _, x in e) + 8
            if os.environ.get("W3DBG"): print(f"param ${p:02X}: y {miny}..{maxy} x {minx}..{maxx}")
            if p in (0x31, 0x47) and miny >= -8 and maxy <= 8 and minx == 0 and maxx <= 16:
                # 16x16-or-smaller sprites anchored at x 0 (Ganchan, Tokotoko,
                # the boss's thrown $33, corpses): 3 rows (straddle) x 4 cols
                # (the 8px-left shift + the bar) instead of the 40x24 default --
                # the boss arena overran the frame (docs/44, playtest round 1)
                exc.append((p, (-miny - 8) // 8 if miny < -8 else 0, 0xC0 | ((maxx + 8) // 8 + 1)))
                continue
            if p in (0x12, 0x22) and miny == 0 and maxy == 8 and minx == 0:
                # the 3-3 lifts (24x8 / 16x8 bars): 3 lifts moving at once
                # with the 40x24 default box dropped up to 24% of the logic
                # frames (docs/44) -- a 2-row box from the anchor, cols
                # covering the 8px-left shift + the bar
                exc.append((p, 0, 0x80 | ((maxx + 8) // 8 + 1)))
                continue
            if miny >= -8 and maxy <= 16 and minx >= -8 and maxx <= 32:
                continue                      # inside the default box
            # the engine erases from (o_pvx-8, o_pvy-excy) for `rows` rows of 8px,
            # so the origin must be lifted to the metasprite's own TOP: excy =
            # -miny PIXELS (it used to be (-miny-8)//8 ROWS -- 8px short, which is
            # exactly the band Hiyoihoi left behind as a trail, user-caught).
            yadj = -miny - 8 if miny < -8 else 0   # the engine subtracts a further 8
            rows = (maxy - miny) // 8 + 1         # (erase_slot's tall path)
            cols = (maxx - minx) // 8 + 2   # +1 for the 8px left shift, +1 because a
                                            # flipped metasprite can reach one cell
                                            # further right than its RIGHT list does
                                            # (Hiyoihoi left a column behind)
            # width byte rows: base 1 + bit7 (+1) + bit6 (+1) + bit5 (+2)
            wb = cols | {1: 0x00, 2: 0x80, 3: 0xC0, 4: 0xA0}.get(rows, 0xE0)
            exc.append((p, yadj, wb))
        f.write(f"W3_NEXC = {len(exc)}\n")
        f.write("w3_excp:\n    .byte " + ",".join(f"${p:02X}" for p, _, _ in exc) + "\n")
        f.write("w3_excy:\n    .byte " + ",".join(f"{y}" for _, y, _ in exc) + "\n")   # PIXELS
        f.write("w3_excw:\n    .byte " + ",".join(f"${w:02X}" for _, _, w in exc) + "\n")
        f.write('.segment "W2C"\n')   # back to the window for the includer

    print(f"gen_w3data W{WORLD}: {len(types)} scripts ({len(blob)}B), {len(params)} params "
          f"({len(body)}B lists), {len(order)} tiles -> {OUT_INC}")


if __name__ == "__main__":
    main()
