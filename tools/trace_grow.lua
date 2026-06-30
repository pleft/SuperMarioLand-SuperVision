-- mGBA Lua: capture the small->big GROW animation in the original SML.
-- $ff99 = size/grow state (0=small, 1=growing, 2=big, 3=star/shrink); $ffa6 = grow timer;
-- $c201/$c202 = Mario Y/X. To see the sprite flash we log Mario's OAM tiles: the player's
-- sprites are the first OAM entries ($FE00, 4 bytes each: Y,X,tile,attr).
--
-- Usage:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_grow.lua")
-- Then as SMALL Mario, grab a Super Mushroom and let the whole grow finish (stand still).
-- Logs every frame from when the grow starts until big has been steady for ~1s.
-- Send me /tmp/sml_grow.txt
local out = io.open("/tmp/sml_grow.txt", "w")
local frame, started, steady = 0, false, 0
local cbid
local function onFrame()
  frame = frame + 1
  local s = emu:read8(0xFF99)
  if not started then
    if s == 1 then started = true else return end      -- begin at grow start
  end
  -- OAM tiles of Mario's 4 sprites (tile byte at +2 of each 4-byte entry)
  local t0 = emu:read8(0xFE02); local t1 = emu:read8(0xFE06)
  local t2 = emu:read8(0xFE0A); local t3 = emu:read8(0xFE0E)
  out:write(string.format("f%-5d ff99=%d ffa6=%3d  oamTiles=%02X %02X %02X %02X  y=%d\n",
            frame, s, emu:read8(0xFFA6), t0, t1, t2, t3, emu:read8(0xC201)))
  out:flush()
  if s == 2 then steady = steady + 1 else steady = 0 end
  if steady > 60 and cbid then callbacks:remove(cbid) end       -- stop after grow settles
end
cbid = callbacks:add("frame", onFrame)
