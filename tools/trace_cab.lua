-- mGBA Lua: nail the cab<->camera relation + true enemy spawn WORLD positions.
-- Logs every 4th frame: cab ($c0ab), camera low bytes ($ffa4/$ffa3?), scroll regs,
-- seg/col ($ffe5/$ffe6), Mario, and object slots. Walk 1-1 from the start to past
-- the tall pipe on the ledge (where the Chibibo pair descends). ~60s window.
-- Usage: dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_cab.lua")
-- Send /tmp/sml_cab.txt
local out = io.open("/tmp/sml_cab.txt", "a")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 3600 then if cbid then callbacks:remove(cbid) end return end
  if frame % 4 ~= 0 then return end
  local line = string.format("f%-5d cab=%d a4=%d a3=%d scx=%d seg=%d/%d M(%d,%d)",
    frame, emu:read8(0xC0AB), emu:read8(0xFFA4), emu:read8(0xFFA3),
    emu:read8(0xFF43), emu:read8(0xFFE5), emu:read8(0xFFE6),
    emu:read8(0xC202), emu:read8(0xC201))
  for s = 0, 9 do
    local b = 0xD100 + s * 0x10
    local t = emu:read8(b)
    if t ~= 0xFF then
      line = line .. string.format(" [%d:%02X@%d,%d]", s, t, emu:read8(b + 3), emu:read8(b + 2))
    end
  end
  out:write(line .. "\n")
  out:flush()
end
cbid = callbacks:add("frame", onFrame)
