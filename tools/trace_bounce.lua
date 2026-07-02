-- mGBA Lua: capture (1) the ?-block BOUNCE animation and (2) the brick-break DEBRIS.
-- Logs, every frame for ~12s: the bounce state $ffee + bounce-block Y/X/tile ($c02c/d/e),
-- Mario, and the full OAM (tile@x,y) so the debris pieces' tiles + trajectories are captured.
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_bounce.lua")
-- ~30s window. In one relaxed run: (1) bonk a ?-block cleanly (the block-bounce anim),
-- (2) collect the mushroom (the "1000" score popup), (3) if reachable, the 1-up heart
-- (the "1UP" popup). Send me /tmp/sml_bounce.txt
local out = io.open("/tmp/sml_bounce.txt", "w")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 1800 then if cbid then callbacks:remove(cbid) end return end
  local ee = emu:read8(0xFFEE)
  local line = string.format("f%-4d ee=%02X blk(y=%d x=%d t=%02X) M(%d,%d)",
    frame, ee, emu:read8(0xC02C), emu:read8(0xC02D), emu:read8(0xC02E),
    emu:read8(0xC202), emu:read8(0xC201))
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
