#!/usr/bin/env python3
"""svrender: turn a raw Watara Supervision VRAM dump into a 160x160 image.

Pure geometry, stdlib only (zlib for PNG). Used by telemview's --render mode
to draw the real console screen from the generic telemetry mailbox, and
standalone to validate the pixel layout against a known VRAM dump.

Hardware facts it stands on (docs/27, supervision-hardware memory, kevtris
Supervision_Tech.txt), all confirmed on real hardware (hwtest14):
  - VRAM is 8 KB at CPU $4000-$5FFF, a LINEAR 2bpp framebuffer.
  - 4 pixels per byte, bits1:0 = the LEFTMOST pixel of the four.
  - The LCD scan is a RING: line stride 48 bytes, address wraps at
    8160 = 170 lines x 48 (8160 % 48 == 0 keeps line phase).
  - Scan origin is byte-precise: origin = XSCROLL//4 + YSCROLL*48, and the
    low 2 bits of XSCROLL delay pixels 0-3 clocks (1px sub-byte scroll).
  - Visible screen: 160 lines x 160 px = 40 visible bytes per 48-byte line
    (the extra 8 bytes/line are the off-screen fetch margin).

Scroll note: registers are write-only on real hardware, so live scroll isn't
in the telemetry yet (it comes from a per-game RAM shadow var, a separate
build item). Default render is origin (0,0) = the raw framebuffer, which is
already a recognizable picture; pass xscroll/yscroll once a shadow var is
wired.
"""
import zlib, struct

VRAM_BYTES = 8192          # $4000-$5FFF
RING = 8160                # scan wrap = 170 lines * 48
STRIDE = 48                # bytes per scanline (192 px addressable)
W = H = 160                # visible screen
VIS_BYTES = W // 4         # 40 visible bytes per line

# 4 grey levels, lightest(0) -> darkest(3). Default neutral greyscale;
# GREEN approximates the Supervision's greenish LCD.
GREY = [(255, 255, 255), (170, 170, 170), (85, 85, 85), (0, 0, 0)]
GREEN = [(0xC4, 0xCF, 0xA1), (0x8B, 0x95, 0x6D), (0x4D, 0x53, 0x3C),
         (0x1F, 0x1F, 0x1F)]


def render_vram(vram, xscroll=0, yscroll=0, palette=GREY):
    """VRAM (bytes/bytearray, >=8160) -> list of H rows of W (r,g,b) tuples."""
    origin = (xscroll // 4 + yscroll * STRIDE) % RING
    sub = xscroll & 3                      # sub-byte pixel delay 0..3
    rows = []
    for ly in range(H):
        line_base = (origin + ly * STRIDE) % RING
        # Decode 41 bytes -> 164 px, then drop the leading `sub` pixels so the
        # 1px sub-byte scroll is honoured; keep the first W.
        px = []
        for cb in range(VIS_BYTES + 1):
            b = vram[(line_base + cb) % RING]
            px.append(b & 3)
            px.append((b >> 2) & 3)
            px.append((b >> 4) & 3)
            px.append((b >> 6) & 3)
        px = px[sub:sub + W]
        rows.append([palette[v] for v in px])
    return rows


def _png_chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)


def write_png(path, rows, scale=1):
    """rows: H lists of W (r,g,b). scale: integer nearest-neighbour upscale."""
    h = len(rows) * scale
    w = len(rows[0]) * scale
    raw = bytearray()
    for row in rows:
        line = bytearray()
        for (r, g, b) in row:
            line += bytes((r, g, b)) * scale
        for _ in range(scale):
            raw.append(0)                  # filter type 0 (None) per scanline
            raw += line
    png = b"\x89PNG\r\n\x1a\n"
    png += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += _png_chunk(b"IEND", b"")
    open(path, "wb").write(png)


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3:
        sys.exit("usage: svrender.py VRAM.bin OUT.png [scale] [xscroll] [yscroll]")
    vram = bytearray(open(sys.argv[1], "rb").read())
    if len(vram) < RING:
        vram += bytes(VRAM_BYTES - len(vram))
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    xs = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    ys = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    write_png(sys.argv[2], render_vram(vram, xs, ys), scale)
    print(f"wrote {sys.argv[2]} ({W*scale}x{H*scale}, scroll {xs},{ys})")
