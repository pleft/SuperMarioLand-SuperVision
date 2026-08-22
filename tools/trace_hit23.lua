-- mGBA Lua: 2-3 contact forensics. WHY does the GB report a contact and then
-- decline the damage?
--
-- Established with PyBoy (docs/38 finding 13): during a school-fish graze the
-- GB's own overlap test ($0aaf) returns HIT on nine frames -- the reporter is
-- slot 1, confirmed by reading hl at the hook -- and Mario is never hurt: state
-- stays $0D, lives stay 5. The damage path could NOT be traced further because
-- PyBoy hooks fire only at call/jump targets (law E13), so nothing inside
-- $09f1 is observable there.
--
-- The open question is exactly one branch. $09f1 (hurt small Mario) starts:
--     $09f1  ld a,[$d007]
--     $09f4  and a
--     $09f5  ret nz          <-- gate: nonzero $d007 aborts the hurt
--     $09f6  ld a,$03
--     $09f8  ldh [$ffb3],a   <-- the death state
-- So either $d007 is NONZERO at that instant (and PyBoy's end-of-frame read of
-- 0 was simply the wrong moment), or the state IS set to 3 and something later
-- in the frame puts it back.
--
-- This script logs the context every frame so the graze can be read back
-- afterwards; the BREAKPOINTS below are what actually answer it.
--
-- Usage:
--   mgba -d ~/Dev/SuperMarioLand/super-mario-land-gb.gb
--   (in the mGBA window) Tools -> Scripting -> load this file, or from a
--   scripting console:  dofile("/Users/pleft/Dev/SuperMarioLand/tools/trace_hit23.lua")
--   Play into 2-3, then graze a school fish. Log: /tmp/sml_hit23.txt
local out = io.open("/tmp/sml_hit23.txt", "a")
local frame = 0
out:write("\n=== new run ===\n")
local function onFrame()
  frame = frame + 1
  local st = emu:read8(0xFFB3)
  if st ~= 0x0D and st ~= 0x00 then
    -- any state that is not "playing" is worth a line on its own
    out:write(string.format("f%-6d STATE=%02X lives=%02X\n", frame, st, emu:read8(0xDA15)))
    out:flush()
    return
  end
  if st ~= 0x0D then return end                      -- only trace the sub level
  local line = string.format("f%-6d st=%02X d007=%02X ff99=%02X c0d3=%02X lives=%02X M(%d,%d)",
    frame, st, emu:read8(0xD007), emu:read8(0xFF99), emu:read8(0xC0D3),
    emu:read8(0xDA15), emu:read8(0xC202), emu:read8(0xC201))
  -- every live enemy slot: type, x, y, and its size byte (+$0a)
  for s = 0, 9 do
    local b = 0xD100 + 16 * s
    local t = emu:read8(b)
    if t ~= 0x00 and t ~= 0xFF then
      line = line .. string.format("  [%d:%02X x%d y%d sz%02X]",
        s, t, emu:read8(b + 3), emu:read8(b + 2), emu:read8(b + 10))
    end
  end
  out:write(line .. "\n")
  out:flush()
end
callbacks:add("frame", onFrame)
