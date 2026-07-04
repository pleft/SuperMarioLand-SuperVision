-- mGBA Lua: time the Nokobon bomb chain + walk behavior. Logs every frame any object
-- of type $04 (Nokobon) / $05 (bomb) / $46 (explosion) is live: type, x, y + Mario.
-- Usage: dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_noko.lua")
-- In 1-1: reach the Nokobon (after the tall ledge pipe area), STOMP it, step back and
-- let the bomb blow. If you can, also let one walk toward a LEDGE first (does it turn
-- or fall?). /tmp/sml_noko.txt
local out = io.open("/tmp/sml_noko.txt", "a")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 10800 then if cbid then callbacks:remove(cbid) end return end
  local line = nil
  for s = 0, 9 do
    local b = 0xD100 + s * 0x10
    local t = emu:read8(b)
    if t == 0x04 or t == 0x05 or t == 0x46 then
      line = (line or string.format("f%-5d M(%d,%d)", frame,
        emu:read8(0xC202), emu:read8(0xC201)))
        .. string.format(" [%d:%02X@%d,%d]", s, t, emu:read8(b + 3), emu:read8(b + 2))
    end
  end
  if line then out:write(line .. "\n"); out:flush() end
end
cbid = callbacks:add("frame", onFrame)
