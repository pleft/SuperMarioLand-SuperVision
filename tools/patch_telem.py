#!/usr/bin/env python3
"""patch_telem: inject the generic NMI-prefix telemetry exporter into any
Supervision .sv ROM (devkit phase 3, docs/28-30).

The Supervision maps the top 16 KB of the ROM to CPU $C000-$FFFF, always
present ("fixed bank"); the NMI/RESET/IRQ vectors are its last 6 bytes. We:
  1. read the NMI vector,
  2. assemble tools/telem_stub.s (which ends in `jmp ORIG_NMI`),
  3. find a free run (>= stub length) of $FF in the fixed bank,
  4. splice the stub there and repoint the NMI vector at it.
The stub runs each NMI, exports a VRAM slice + joypad through the WRAM
mailbox $1F80-$1FFF, then jumps to the game's original handler.

Usage: patch_telem.py IN.sv OUT.sv
Exit 2 = insufficient fixed-bank free space (prints the free-run map).
"""
import sys, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
STUB_SRC = os.path.join(HERE, "telem_stub.s")

def ff_runs(buf):
    runs, cur, start = [], 0, 0
    for i, b in enumerate(buf):
        if b == 0xFF:
            if cur == 0:
                start = i
            cur += 1
        elif cur:
            runs.append((start, cur)); cur = 0
    if cur:
        runs.append((start, cur))
    return sorted(runs, key=lambda r: -r[1])

def assemble(cpu_addr, orig_nmi, tmp, scrollx=None, scrolly=None):
    inc = os.path.join(tmp, "orig_nmi.inc")
    open(inc, "w").write("ORIG_NMI = $%04X\n" % orig_nmi)
    cfg = os.path.join(tmp, "stub.cfg")
    open(cfg, "w").write(
        "MEMORY { STUB: start $%04X size $4000 type ro file %%O; }\n"
        "SEGMENTS { STUB: load STUB type ro; }\n" % cpu_addr)
    o = os.path.join(tmp, "stub.o")
    b = os.path.join(tmp, "stub.bin")
    cmd = ["ca65", "--cpu", "65c02", "-I", tmp, "-I", HERE]
    if scrollx is not None or scrolly is not None:
        cmd += ["-D", "WITH_SCROLL"]        # MAGIC $A6 + scroll export
        if scrollx is not None:
            cmd += ["-D", "SCROLLX_ADDR=$%04X" % scrollx]
        if scrolly is not None:
            cmd += ["-D", "SCROLLY_ADDR=$%04X" % scrolly]
    cmd += [STUB_SRC, "-o", o]
    subprocess.run(cmd, check=True)
    subprocess.run(["ld65", "-C", cfg, o, "-o", b], check=True)
    return open(b, "rb").read()

def main():
    # positional IN OUT + optional --scrollx/--scrolly $ADDR (from scrollhunt.py)
    argv = sys.argv[1:]
    scrollx = scrolly = None
    pos = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--scrollx":
            scrollx = int(argv[i + 1].lstrip("$"), 16); i += 2
        elif a == "--scrolly":
            scrolly = int(argv[i + 1].lstrip("$"), 16); i += 2
        else:
            pos.append(a); i += 1
    if len(pos) != 2:
        sys.exit("usage: patch_telem.py IN.sv OUT.sv [--scrollx $ADDR] [--scrolly $ADDR]\n"
                 "  scroll addrs (from tools/scrollhunt.py) bake scroll export into the stub.")
    src, dst = pos
    rom = bytearray(open(src, "rb").read())
    n = len(rom)
    if n < 0x8000 or (n & (n - 1)):
        print(f"warning: ROM size {n} is not a power-of-two >= 32K")
    nmi = rom[n - 6] | (rom[n - 5] << 8)
    print(f"ROM {n} bytes  NMI=${nmi:04X}  RESET=${rom[n-4]|(rom[n-3]<<8):04X}")

    fixed_base_file = n - 0x4000            # CPU $C000 -> this file offset
    with tempfile.TemporaryDirectory() as tmp:
        stub = assemble(0xC000, nmi, tmp, scrollx, scrolly)  # length is address-independent
        L = len(stub)
        print(f"stub is {L} bytes")

        # search the fixed bank only (always mapped), excluding the vectors.
        fb = rom[fixed_base_file:n - 6]
        runs = ff_runs(fb)
        big = runs[0] if runs else (0, 0)
        if big[1] < L:
            print(f"\nINSUFFICIENT SPACE: largest fixed-bank free run is "
                  f"{big[1]} bytes (need {L}).")
            print("fixed-bank free runs (CPU addr : size), top 8:")
            for off, sz in runs[:8]:
                print(f"  ${0xC000+off:04X} : {sz}")
            print("\nThis ROM is too densely packed for in-place injection.")
            print("Next option (docs/30): Pico-side fetch-overlay -- the cart")
            print("serves the stub bytes for a chosen address window, needing")
            print("zero ROM free space. Not yet implemented.")
            sys.exit(2)

        off = big[0]
        cpu = 0xC000 + off
        stub = assemble(cpu, nmi, tmp, scrollx, scrolly)  # reassemble at the real address
        rom[fixed_base_file + off: fixed_base_file + off + L] = stub
        rom[n - 6] = cpu & 0xFF             # repoint NMI vector -> stub
        rom[n - 5] = cpu >> 8
        print(f"injected stub at CPU ${cpu:04X}, NMI -> ${cpu:04X}")

    open(dst, "wb").write(rom)
    print(f"wrote {dst} ({len(rom)} bytes)")

if __name__ == "__main__":
    main()
