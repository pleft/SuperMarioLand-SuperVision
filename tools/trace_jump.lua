-- mGBA Lua script: log Mario's vertical state each time his Y changes.
-- Use: mGBA (Qt) -> Tools -> Scripting... -> Load script -> pick this file.
--      Load the SML ROM, get into a level, jump a few times, then copy the
--      scripting console output and send it back.
--
-- Captures: frame, Y ($C201), delta, vertical-state ($C207), jump-hold ($C208),
--           force/accel ($C20C). From the Y/delta sequence the jump arc
--           (per-frame velocity) is reconstructed. (No PC here — use SameBoy for that.)

local ADDR_Y     = 0xC201   -- Mario Y position (screen)
local ADDR_STATE = 0xC207   -- 0=ground/fall, 1=ascend, 2=bonk
local ADDR_HOLD  = 0xC208   -- jump hold-counter
local ADDR_FORCE = 0xC20C   -- jump force / accel

local frame  = 0
local prevY  = nil

local function onFrame()
  frame = frame + 1
  local y = emu:read8(ADDR_Y)
  if y ~= prevY then
    local d = (prevY == nil) and 0 or (y - prevY)
    -- signed delta in -128..127
    if d > 127 then d = d - 256 elseif d < -128 then d = d + 256 end
    console:log(string.format(
      "f=%-6d Y=%3d (%+d)  C207=%d C208=%02X C20C=%02X",
      frame, y, d,
      emu:read8(ADDR_STATE), emu:read8(ADDR_HOLD), emu:read8(ADDR_FORCE)))
    prevY = y
  end
end

callbacks:add("frame", onFrame)
console:log("trace_jump.lua loaded - jump a few times; copy this console.")
