-- mGBA Lua: capture the Superball FLOWER that a power-up block spawns when Mario is BIG.
-- Flower item = object type $2D (emerging) -> morphs to $2E (sitting/animating). Object slots
-- at $D100 stride $10: +0 type, +1 vel, +2 Y, +3 X, +6 sprite-param ($FFC6), +8 state.
-- Also dumps the flower's actual tile PIXELS from VRAM (its tiles $E0/$E5 are only loaded when
-- big) and the OAM, so we get graphics + behavior together.
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_flower.lua")
-- Get BIG first (eat a mushroom), then bonk a power-up ?-block. Send me /tmp/sml_flower.txt
local out = io.open("/tmp/sml_flower.txt", "w")
local frame, dumped = 0, false
local function onFrame()
  frame = frame + 1
  local found = false
  for s = 0, 9 do
    local b = 0xD100 + s * 0x10
    local t = emu:read8(b)
    if t == 0x2D or t == 0x2E then
      found = true
      out:write(string.format("f%-5d s%d type=%02X x=%d y=%d param=%02X vel=%02X state=%02X\n",
        frame, s, t, emu:read8(b + 3), emu:read8(b + 2),
        emu:read8(b + 6), emu:read8(b + 1), emu:read8(b + 8)))
      if not dumped then
        dumped = true
        out:write("--- OAM (non-empty), Y X tile attr ---\n")
        for e = 0, 39 do
          local o = 0xFE00 + e * 4
          local y = emu:read8(o)
          if y ~= 0 and y < 160 then
            out:write(string.format("  oam%d: y=%d x=%d tile=%02X attr=%02X\n",
              e, y, emu:read8(o + 1), emu:read8(o + 2), emu:read8(o + 3)))
          end
        end
        out:write("--- VRAM tiles $DE..$E8 (16 bytes each = the flower gfx) ---\n")
        for tile = 0xDE, 0xE8 do
          local a = 0x8000 + tile * 16
          local row = string.format("  tile $%02X:", tile)
          for i = 0, 15 do row = row .. string.format(" %02X", emu:read8(a + i)) end
          out:write(row .. "\n")
        end
      end
    end
  end
  out:flush()
end
callbacks:add("frame", onFrame)
