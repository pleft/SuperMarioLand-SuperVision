-- mGBA Lua: capture the ORIGINAL's LEVEL-END (goal) sequence in 1-1.
-- Logs, once Mario is in the last level segments (seg $ffe5 >= 13) or out of the play state:
-- state $ffb3, sub $ffb4, goal flag $d007, Mario X/Y, col counter $c0ab, seg $ffe5/col $ffe6,
-- TIME ($da01/$da02 BCD), and every object slot (type @ $D100+16n, x,y). ~90s window.
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_goal.lua")
-- Play 1-1 to the end and walk through the BOTTOM goal door; let the tally + transition play.
-- If you can, do a SECOND run entering the TOP door (send that file too / append happens).
-- Send me /tmp/sml_goal.txt
local out = io.open("/tmp/sml_goal.txt", "a")
local frame, cbid = 0, nil
local function onFrame()
  frame = frame + 1
  if frame > 5400 then if cbid then callbacks:remove(cbid) end return end
  local st = emu:read8(0xFFB3)
  local seg = emu:read8(0xFFE5)
  if seg < 13 and st == 0x0D then return end          -- only near the level end / non-play states
  local line = string.format("f%-5d st=%02X sub=%02X d007=%02X M(%d,%d) cab=%d seg=%d/%d T=%x%02x",
    frame, st, emu:read8(0xFFB4), emu:read8(0xD007),
    emu:read8(0xC202), emu:read8(0xC201), emu:read8(0xC0AB),
    seg, emu:read8(0xFFE6), emu:read8(0xDA02), emu:read8(0xDA01))
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
