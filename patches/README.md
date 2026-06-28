# Emulator patches

## potator-per-scanline-render.patch

Patches **Potator** (libretro Supervision core) to **capture the scroll registers
(`XPOS`/`YPOS`) per scanline** as the CPU runs, then render the whole frame at the end
using those captures (instead of sampling the scroll once per frame). This enables
**raster splits** (mid-frame `XSCROLL` changes) — which this port uses to keep the
status bar pinned at the top while the playfield scrolls smoothly (NMI sets
`XSCROLL=0`; a timer IRQ at scanline 16 switches to the playfield scroll).

Rendering at the END (after a full frame of CPU) means the framebuffer is fully
composed before any scanline is drawn, so software sprites high on the screen are never
torn — while the per-scanline scroll capture still gives the raster split.

It is **back-compatible**: games that set the scroll once per frame render identically.
Real Supervision hardware renders per-scanline, so the split also works on hardware
without this patch — only stock Potator (which batched the whole frame) needed it.

### Build & install (macOS example)

```sh
git clone https://github.com/libretro/potator
cd potator
git checkout 227c5f6                      # the commit this patch was made against (core 1.0.5)
git apply /path/to/patches/potator-per-scanline-render.patch
cd platform/libretro
# Universal build (match an x86_64 RetroArch on Apple Silicon; arm64 for native):
make CC="clang -arch x86_64 -arch arm64"
cp potator_libretro.dylib "$HOME/Library/Application Support/RetroArch/cores/"
```

Back up the original core first; restore it to revert.
