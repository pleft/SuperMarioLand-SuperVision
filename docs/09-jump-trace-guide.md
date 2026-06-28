# Dynamic Trace Guide — capturing Mario's jump-rise (task #10)

Goal: find (a) the PC of the code that moves Mario UP during a jump, and (b) the
per-frame `$C201` (Mario Y) sequence across one jump → reconstruct the arc/constants.

SameBoy debugger command syntax verified from the official reference
(https://sameboy.github.io/debugger/).

## A. SameBoy (recommended for the PC hunt)

### 1. Open the debugger console
- Launch `/Applications/SameBoy.app`, open the SML ROM (File ▸ Open).
- Enable the debugger: **SameBoy ▸ Preferences ▸ enable "Developer Mode"** (or the
  Developer/View menu), then open the **Console** window. The Console is where you
  type the commands below. (Optional: SameBoy auto-loads a `.sym` next to the ROM — if
  you copy `disasm/game.sym` next to the ROM it will show our labels.)

### 2. Get in position
- Play into a level so Mario is standing on the ground (state where he can jump).

### 3. Phase A — find the ascent routine (the key result)
In the Console:
```
watch $c201 if new < old
```
This breaks ONLY when Mario's Y decreases (moving up). Then, in the game window,
**make Mario jump**. When it breaks, run:
```
registers
backtrace
```
Copy the **PC** shown by `registers` (and the `backtrace`). That PC is the
instruction writing `$C201` during the rise — paste it to me and I can read the
routine statically. One or two breaks is enough for this part.

### 4. Phase B — capture the full arc (per-frame Y)
Remove the conditional watch and use a plain one to see every write with old→new:
```
delete            (clears watchpoints/breakpoints; or use the listed id)
watch $c201
```
Then jump again. Each break prints the access (old value → new value). Type
`continue` after each, recording the new value, from jump start through landing
(~25–35 breaks). Paste the ordered list of values. (If that's tedious, use the
mGBA logger in section B instead — it captures the whole sequence automatically.)

Useful extra reads at any break:
```
print/d [$c201]     ; Mario Y (decimal)
print/x [$c207]     ; vertical state
print/x [$c208]     ; jump hold-counter
print/x [$c20c]     ; jump force / accel
```

## B. mGBA (recommended for the automatic full-arc capture)
mGBA (Qt) has Lua scripting: **Tools ▸ Scripting…**, then **Load script** and pick
`tools/trace_jump.lua` (see that file). It logs Mario's Y every frame to the
scripting console; jump a few times, then copy the console output to me. (Script
logs only — captures the Y sequence, not the PC; use SameBoy section A for the PC.)

## What to send back
1. From SameBoy Phase A: the **PC** (+ backtrace) where `$C201` is written on the way up.
2. From either tool: the **ordered per-frame `$C201` values** across one full jump.

From (1) I locate the routine; from (2) I derive the exact per-frame deltas
(velocity profile / arc table). Then the ascent constants go into `docs/08-player.md`
and the symbol file — no guessing (rule 2).
