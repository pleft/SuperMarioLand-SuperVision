#!/usr/bin/env python3
"""telemview: live viewer for the SuperPico telemetry link (docs/29).

Usage: python3 tools/telemview.py [/dev/cu.usbmodemXXX]

Reads 'F <seq> <128 hex pairs>' snapshot lines from the SUPERPICO_TELEM
firmware, validates the hwtest18 mailbox protocol (MAGIC/COMMIT/XOR/ramp)
and live-renders the bouncing box as an ASCII bar -- the dot on the console
LCD and this marker must move in lockstep. The 48-byte ramp measures
capture corruption: any byte the poller sampled mid-transition shows up
here as a ramp error. Stdlib only.
"""
import sys, glob, termios, time

def open_dev():
    if len(sys.argv) > 2 and sys.argv[1] == "--replay":
        return open(sys.argv[2], "rb")          # offline parser test
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        cands = glob.glob("/dev/cu.usbmodem*")
        if not cands:
            sys.exit("no /dev/cu.usbmodem* found -- is the Pico on USB?")
        path = cands[0]
    f = open(path, "rb", buffering=0)
    attrs = termios.tcgetattr(f.fileno())
    attrs[0] = attrs[1] = attrs[3] = 0          # iflag/oflag/lflag: raw
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(f.fileno(), termios.TCSANOW, attrs)
    print(f"listening on {path}")
    return f

REGPROBE = [                     # hwtest19 payload layout ($1F90+)
    ("$2002 (wrote $11)", 0x10), ("$2003 (wrote $07)", 0x11),
    ("$2000 (boot $A0)", 0x12), ("$2001 (boot $A0)", 0x13),
    ("$2026 (boot $DF)", 0x14), ("$2022 (boot $0F)", 0x15),
    ("$2020 JOYPAD", 0x16), ("$2024", 0x17), ("$2025", 0x18),
    ("$2027", 0x19), ("$2008 (wrote $5A)", 0x1A), ("$2009 (wrote $A5)", 0x1B),
]

def main():
    regs_mode = "--regs" in sys.argv
    if regs_mode:
        sys.argv = [a for a in sys.argv if a != "--regs"]
    replay = len(sys.argv) > 2 and sys.argv[1] == "--replay"
    f = open_dev()
    last_payload = None
    frames = ramp_bad = proto_bad = dup = valid = 0
    raw_f = malformed = other_lines = 0
    last_m = None
    from collections import defaultdict
    fails = defaultdict(int)
    last_seq = None
    t0 = time.time()
    fps_mark, fps = 0, 0.0
    buf = b""
    while True:
        chunk = f.read(4096)
        if not chunk:
            if replay:
                print(f"\nreplay done: F={raw_f} malformed={malformed} "
                      f"dup={dup} frames={frames} valid={valid} "
                      f"fails={dict(fails)}")
                return
            time.sleep(0.005)
            continue
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.decode("ascii", "replace").strip()
            if line.startswith("#"):
                print(f"\r{line}  [rx: F={raw_f} malformed={malformed} "
                      f"dup={dup} frames={frames}]" + " " * 8)
                continue
            if not line.startswith("F "):
                if line:
                    other_lines += 1
                    if other_lines <= 3:
                        print(f"\rnon-F line: {line[:60]!r}" + " " * 8)
                continue
            raw_f += 1
            parts = line.split()
            if len(parts) != 3 or len(parts[2]) != 256:
                malformed += 1
                if malformed <= 3:
                    print(f"\rmalformed F line ({len(parts)} fields, "
                          f"payload {len(parts[2]) if len(parts) > 2 else 0}): "
                          f"{line[:60]!r}" + " " * 8)
                continue
            try:
                m = bytes.fromhex(parts[2])
            except ValueError:
                malformed += 1
                continue
            seq = m[2]           # header at $1F81+ ($1F80 = the trap byte)
            if seq == last_seq:
                dup += 1
                continue
            prev = last_m
            last_m = m
            last_seq = seq
            frames += 1
            ok = True
            # Per-field failure breakdown -- which byte actually tears?
            if m[1] != 0xA5:
                fails["magic"] += 1
                fails[f"magic_val_{m[1]:02x}"] += 1
            if m[0x7F] != seq:
                fails["commit"] += 1
                if prev and m[0x7F] == prev[0x7F]:
                    fails["commit_stale"] += 1
            if m[8] != (seq ^ 0xFF):
                fails["xor"] += 1
                if prev and m[8] == prev[8]:
                    fails["xor_stale"] += 1
            if m[1] != 0xA5 or m[0x7F] != seq or m[8] != (seq ^ 0xFF):
                proto_bad += 1
                ok = False
            # CKSUM at $1FFE: mod-256 sum of header + ramp. A frame that
            # fails it is torn (missed/early-sampled bytes) -> drop it.
            ck = (sum(m[1:9]) + sum(m[0x10:0x40])) & 0xFF
            if ck != m[0x7E]:
                if ok:
                    fails["ck_only"] += 1
                ok = False
            valid += ok
            if frames % 305 == 0:
                print("\rfails: " + " ".join(f"{k}={v}" for k, v in
                                             sorted(fails.items())) + " " * 8)
            if not regs_mode:
                bad = sum(1 for i in range(48)
                          if m[0x10 + i] != ((seq + i) & 0xFF))
                ramp_bad += bad
            if not ok:
                continue                     # torn frame: keep the last good one
            if regs_mode:
                payload = m[0x10:0x1C]
                if payload != last_payload:
                    last_payload = payload
                    print("\r--- register readbacks (open bus reads as $20):"
                          + " " * 20)
                    for name, off in REGPROBE:
                        print(f"    {name:20s} -> {m[off]:02x}")
            x, y = m[6], m[7]
            now = time.time()
            if now - t0 >= 1.0:
                fps = (frames - fps_mark) / (now - t0)
                fps_mark, t0 = frames, now
            bar = ["-"] * 40
            bar[min(x // 4, 39)] = "#"
            pct = 100.0 * valid / frames if frames else 0.0
            sys.stdout.write(
                f"\rseq={seq:02x} x={x:3d} y={y:3d} [{''.join(bar)}] "
                f"{fps:5.1f}fps valid={pct:5.1f}% frames={frames} "
                f"rampbad={ramp_bad} proto={proto_bad} dup={dup}   ")
            sys.stdout.flush()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
