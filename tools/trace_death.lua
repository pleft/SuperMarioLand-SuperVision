-- mGBA Lua: capture (1) the pit-death -> respawn sequence (delay + respawn position =
-- the checkpoint system) and (2) the GAME OVER strip scroll (window Y animation).
-- Logs state $ffb3, WY $ff4a, Mario x/y, col counter, lives, every frame when the state
-- isn't plain play (or Mario is near a pit fall).
-- Usage: dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_death.lua")
-- Then: die in a pit MID-LEVEL (past the halfway point!) with spare lives, let it respawn;
-- then die repeatedly to reach GAME OVER and let the strip scroll. /tmp/sml_death.txt
local out = io.open("/tmp/sml_death.txt", "a")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 10800 then if cbid then callbacks:remove(cbid) end return end
  local st = emu:read8(0xFFB3)
  local y = emu:read8(0xC201)
  if st == 0x00 and y < 140 then return end
  out:write(string.format("f%-5d st=%02X wy=%d M(%d,%d) cab=%d seg=%d lives=%02x\n",
    frame, st, emu:read8(0xFF4A), emu:read8(0xC202), y,
    emu:read8(0xC0AB), emu:read8(0xFFE5), emu:read8(0xDA15)))
  out:flush()
end
cbid = callbacks:add("frame", onFrame)
