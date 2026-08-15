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
    frames = ramp_bad = proto_bad = dup = 0
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
            seq = m[1]
            if seq == last_seq:
                dup += 1
                continue
            last_seq = seq
            frames += 1
            ok = True
            if m[0] != 0xA5 or m[0x7F] != seq or m[7] != (seq ^ 0xFF):
                proto_bad += 1
                ok = False
            bad = sum(1 for i in range(48) if m[0x10 + i] != ((seq + i) & 0xFF))
            ramp_bad += bad
            x, y = m[5], m[6]
            now = time.time()
            if now - t0 >= 1.0:
                fps = (frames - fps_mark) / (now - t0)
                fps_mark, t0 = frames, now
            bar = ["-"] * 40
            bar[min(x // 4, 39)] = "#"
            sys.stdout.write(
                f"\rseq={seq:02x} x={x:3d} y={y:3d} [{''.join(bar)}] "
                f"{fps:5.1f}fps frames={frames} rampbad={ramp_bad} "
                f"proto={proto_bad} dup={dup} {'OK ' if ok else 'BAD'}")
            sys.stdout.flush()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
