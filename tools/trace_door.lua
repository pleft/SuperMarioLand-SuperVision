-- mGBA Lua: settle the goal-door approach EXACTLY. Logs Mario x/y, state, and the JOYPAD
-- (held $ff80 / new $ff81) every frame near the level end, so we can see WHERE player input
-- stops mattering and what speed the walk-in uses.
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_door.lua")
-- Two runs into the BOTTOM door, both in one sitting (file appends):
--  1) RUN into it (hold B + Right the whole way, full speed).
--  2) Approach, and just BEFORE the door RELEASE Right and hammer LEFT + A --
--     if Mario walks in anyway, that's the auto-walk boundary.
-- Send me /tmp/sml_door.txt
local out = io.open("/tmp/sml_door.txt", "a")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 7200 then if cbid then callbacks:remove(cbid) end return end
  local st = emu:read8(0xFFB3)
  if emu:read8(0xFFE5) < 17 and st == 0x00 then return end   -- only the final segments
  out:write(string.format("f%-5d st=%02X M(%d,%d) held=%02X new=%02X\n",
    frame, st, emu:read8(0xC202), emu:read8(0xC201),
    emu:read8(0xFF80), emu:read8(0xFF81)))
  out:flush()
end
cbid = callbacks:add("frame", onFrame)
