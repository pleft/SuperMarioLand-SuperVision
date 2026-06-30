-- mGBA Lua: log EVERY active object slot + Mario, every frame, for the original SML.
-- Object slots: $D100, stride $10. Slot bytes: +0 type ($FF = empty), +1 velocity, +2 Y,
-- +3 X. Logging all non-empty slots (not just the mushroom) so we never miss it if the
-- mushroom changes type/slot mid-life. Mario: Y=$C201, X=$C202.
--
-- Usage in mGBA console:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_mushroom.lua")
-- Then bonk the block and let the mushroom run; send me /tmp/sml_mushroom.txt

local out = io.open("/tmp/sml_mushroom.txt", "w")
local frame = 0

local function onFrame()
  frame = frame + 1
  local line = string.format("f%-6d mario(x=%d y=%d)", frame,
                             emu:read8(0xC202), emu:read8(0xC201))
  for s = 0, 9 do
    local b = 0xD100 + s * 0x10
    local t = emu:read8(b)
    if t ~= 0xFF then                                  -- active object slot
      line = line .. string.format("  | s%d t=%02X v=%02X x=%d y=%d",
             s, t, emu:read8(b + 1), emu:read8(b + 3), emu:read8(b + 2))
    end
  end
  out:write(line .. "\n")
  out:flush()
end

callbacks:add("frame", onFrame)
