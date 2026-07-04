-- mGBA Lua: capture the star's full flight in the original. Logs every frame any
-- object of type $2C (emerging) or $34 (live star) exists: x,y + Mario.
-- Usage: dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_star.lua")
-- In 1-1: reach the star block (the lone ? on the two-block pillar past the flies),
-- bonk it, DON'T grab the star -- let it fly away until it disappears.
-- Send /tmp/sml_star.txt
local out = io.open("/tmp/sml_star.txt", "a")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 10800 then if cbid then callbacks:remove(cbid) end return end
  for s = 0, 9 do
    local b = 0xD100 + s * 0x10
    local t = emu:read8(b)
    if t == 0x2C or t == 0x34 then
      out:write(string.format("f%-5d [%d:%02X@%d,%d] M(%d,%d)\n",
        frame, s, t, emu:read8(b + 3), emu:read8(b + 2),
        emu:read8(0xC202), emu:read8(0xC201)))
      out:flush()
    end
  end
end
cbid = callbacks:add("frame", onFrame)
