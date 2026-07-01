-- mGBA Lua: capture the SUPERBALL. It's an OAM sprite, not a $D100 object, so we just log
-- Mario + every active OAM sprite (tile@x,y) EVERY frame for ~7s. No button dependency (my
-- previous trigger keyed on $ffb2, which is a pause flag -- hence the empty file). The ball is
-- the sprite that appears when you fire with B and arcs/bounces away from Mario.
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_superball.lua")
-- As Superball Mario, IMMEDIATELY fire with B a few times (stand on flat ground, aim one at a
-- pipe/wall so I catch a bounce). Send me /tmp/sml_superball.txt
local out = io.open("/tmp/sml_superball.txt", "w")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 420 then if cbid then callbacks:remove(cbid) end return end   -- ~7s cap
  local line = string.format("f%-4d M(%d,%d)", frame, emu:read8(0xC202), emu:read8(0xC201))
  for e = 0, 39 do
    local o = 0xFE00 + e * 4
    local y = emu:read8(o)
    if y ~= 0 and y < 160 then
      line = line .. string.format(" %02X@%d,%d", emu:read8(o + 2), emu:read8(o + 1), y)
    end
  end
  out:write(line .. "\n")
  out:flush()
end
cbid = callbacks:add("frame", onFrame)
