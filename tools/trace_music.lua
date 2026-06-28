-- mGBA Lua: auto-log SML music channel state each frame (for note-format decode).
-- Use: mGBA (Qt) -> Tools -> Scripting... -> Load script -> this file.
--      Load the ROM, get into World 1-1 (music playing), let it run ~5-10 sec,
--      then copy the scripting console output and send it back.
--
-- Polls the 4 sound channel state blocks at $DF00/$DF10/$DF20/$DF30. From the
-- live dump, each block has: +4/+5 = current sequence DATA POINTER, +9/+A =
-- cached note freq (lo/hi). We emit a line whenever any channel's data pointer
-- changes (= it consumed sequence bytes), showing the pointer + freq. That lets
-- us align ROM sequence bytes -> played notes and decode the note bytecode.

local CH = { 0xDF00, 0xDF10, 0xDF20, 0xDF30 }
local last = { -1, -1, -1, -1 }
local frame = 0

local function rd(a) return emu:read8(a) end
local function u16(a) return rd(a) | (rd(a + 1) << 8) end

local function onFrame()
  frame = frame + 1
  for i = 1, #CH do
    local b = CH[i]
    local ptr  = u16(b + 4)          -- current sequence data pointer
    if ptr ~= last[i] and ptr ~= 0 then
      local flo, fhi = rd(b + 9), rd(b + 0x0A)
      console:log(string.format(
        "f=%-6d ch%d ptr=$%04X  freq=$%X%02X", frame, i - 1, ptr, fhi & 0x07, flo))
      last[i] = ptr
    end
  end
end

callbacks:add("frame", onFrame)
console:log("trace_music.lua loaded - play World 1-1, let music run, then copy this console.")
