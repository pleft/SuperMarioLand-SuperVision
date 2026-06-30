-- mGBA Lua: log the original Super Mario Land mushroom object every frame.
-- Object slots live at $D100, stride $10 (16 bytes). Slot bytes: +0 type, +1 velocity,
-- +2 Y, +3 X. The mushroom is type $28 ($2D once you're already big). This scans all
-- 10 slots each frame and logs any active mushroom/power-up to a file.
--
-- Usage: mGBA -> Tools -> Scripting -> load this file. Then in World 1-1 bonk the
-- mushroom block and let the mushroom pop, fall, walk, hit the pipe and reverse WITHOUT
-- grabbing it. Send me  /tmp/sml_mushroom.txt

local out = io.open("/tmp/sml_mushroom.txt", "w")
local frame = 0

local function onFrame()
  frame = frame + 1
  for s = 0, 9 do
    local b = 0xD100 + s * 0x10
    local t = emu:read8(b)
    if t == 0x28 or t == 0x2D then
      out:write(string.format("frame %d  slot %d  type=%02X  vel=%02X  x=%d  y=%d\n",
                frame, s, t, emu:read8(b + 1), emu:read8(b + 3), emu:read8(b + 2)))
    end
  end
  out:flush()
end

callbacks:add("frame", onFrame)
