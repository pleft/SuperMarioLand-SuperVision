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

def main():
    f = open_dev()
    frames = ramp_bad = proto_bad = dup = valid = 0
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
            time.sleep(0.005)
            continue
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.decode("ascii", "replace").strip()
            if line.startswith("#"):
                print("\r" + line + " " * 20)
                continue
            if not line.startswith("F "):
                continue
            parts = line.split()
            if len(parts) != 3 or len(parts[2]) != 256:
                proto_bad += 1
                continue
            try:
                m = bytes.fromhex(parts[2])
            except ValueError:
                proto_bad += 1
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
            bad = sum(1 for i in range(48) if m[0x10 + i] != ((seq + i) & 0xFF))
            ramp_bad += bad
            if not ok:
                continue                     # torn frame: keep the last good one
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
