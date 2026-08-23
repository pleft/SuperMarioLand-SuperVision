#!/usr/bin/env python3
"""make_iddqd -- rebuild the measurement GB rom from the user's own cartridge dump.

Five bytes (documented in the iddqd-ROM-trap memory): three turn the damage
handlers into RET so a capture run can traverse a level instead of dying in the
first 10%, two enable the title level select.

    python3 tools/make_iddqd.py [out.gb]      # default: $CLAUDE_JOB_DIR/tmp/sml_iddqd3.gb
    SML_GB=<that path> python3 tools/gbauto.py 6

RULE 5: the input is the user's rom and the output is a scratch file -- neither
is ever committed. This exists because the old scratchpad copy evaporated with
its temp dir and took every GB measurement with it.

TRAP: on this build Mario CANNOT die from contact, so it may be used for
positions, timings, animation and spawn columns -- NEVER for a question about
damage, death, lives or i-frames. Use the clean rom for those.
"""
import os, sys

PATCH = {                      # offset: (expected, patched)
    0x09F1: (0xFA, 0xC9),      # hurt small Mario   -> RET
    0x09E0: (0x3E, 0xC9),      # hurt big Mario     -> RET
    0x515E: (0xFA, 0xC9),      # the crush death    -> RET
    0x04AA: (0xD2, 0xC3),      # level select
    0x04D3: (0x45, 0x00),
}


def main():
    src = os.environ.get("SML_CLEAN_GB", "super-mario-land-gb.gb")
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get("CLAUDE_JOB_DIR", "/tmp"), "tmp", "sml_iddqd3.gb")
    rom = bytearray(open(src, "rb").read())
    for off, (want, new) in PATCH.items():
        if rom[off] != want:
            raise SystemExit(f"{src}: byte ${off:04X} is ${rom[off]:02X}, expected "
                             f"${want:02X} -- wrong rom or wrong revision")
        rom[off] = new
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "wb").write(bytes(rom))
    print(f"wrote {out} ({len(rom)} bytes, {len(PATCH)} bytes patched)")


if __name__ == "__main__":
    main()
