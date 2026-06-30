-- mGBA Lua: log the surface segment index as you walk RIGHT in World 1-1.
-- $ffe5 = current segment index, $ffe6 = column within segment, $c202 = Mario X,
-- $ffb3 = player/level state (changes when you go down a pipe). Logs only when the
-- segment index or state changes, so the file stays short.
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_level.lua")
-- Then in 1-1 just WALK RIGHT along the surface (do NOT go down any pipe) for a few
-- screens. Send me /tmp/sml_level.txt
local out = io.open("/tmp/sml_level.txt", "w")
local last = ""
local frame = 0
local function onFrame()
  frame = frame + 1
  local seg, col, st = emu:read8(0xFFE5), emu:read8(0xFFE6), emu:read8(0xFFB3)
  local key = string.format("seg=%d state=%02X", seg, st)
  if key ~= last then
    out:write(string.format("f%-6d seg=%d col=%d state=%02X marioX=%d\n",
              frame, seg, col, st, emu:read8(0xC202)))
    out:flush()
    last = key
  end
end
callbacks:add("frame", onFrame)
