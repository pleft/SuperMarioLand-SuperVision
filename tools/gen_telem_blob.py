#!/usr/bin/env python3
"""gen_telem_blob: assemble tools/telem_stub.s into the fixed position-
independent blob the fetch-overlay firmware carries (telem_stub_blob.h).

Default (no WITH_SCROLL) MUST stay byte-identical to the validated 107-byte
overlay blob. Pass --scroll to preview the scroll-enabled variant's length.
Usage: gen_telem_blob.py [--scroll] [--out PATH]
"""
import os, sys, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
STUB = os.path.join(HERE, "telem_stub.s")


def assemble(defines):
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "orig_nmi.inc"), "w").write("ORIG_NMI = $0000\n")
        cfg = os.path.join(tmp, "s.cfg")
        open(cfg, "w").write(
            "MEMORY { STUB: start $C000 size $4000 type ro file %O; }\n"
            "SEGMENTS { STUB: load STUB type ro; }\n")
        o, b = os.path.join(tmp, "s.o"), os.path.join(tmp, "s.bin")
        cmd = ["ca65", "--cpu", "65c02", "-I", tmp, "-I", HERE]
        for d in defines:
            cmd += ["-D", d]
        cmd += [STUB, "-o", o]
        subprocess.run(cmd, check=True)
        subprocess.run(["ld65", "-C", cfg, o, "-o", b], check=True)
        return open(b, "rb").read()


def emit_header(blob):
    L = len(blob)
    out = ["// telem_stub.s assembled with ORIG_NMI=$0000; jmp operand = last 2 bytes.",
           "#pragma once", f"#define TELEM_STUB_LEN {L}",
           f"static const unsigned char telem_stub_blob[{L}] = {{"]
    for i in range(0, L, 12):
        out.append("  " + ",".join("0x%02x" % b for b in blob[i:i + 12]) + ",")
    out.append("};")
    return "\n".join(out) + "\n"


def main():
    scroll = "--scroll" in sys.argv
    blob = assemble(["WITH_SCROLL"] if scroll else [])
    print(f"{'scroll' if scroll else 'base'} stub = {len(blob)} bytes")
    if "--out" in sys.argv:
        path = sys.argv[sys.argv.index("--out") + 1]
        open(path, "w").write(emit_header(blob))
        print(f"wrote {path}")
    else:
        sys.stdout.write(emit_header(blob))


if __name__ == "__main__":
    main()
