# docs/46 -- the game ending (after 4-3), captured from the GB (2026-09-05)

Trigger: the $60 object's 24th missile hit sets d007 ($2ad9); the State_0D
handler then calls Call_000_1b45 (the clear) -> states $07/$06 -> $27 (the
arena dissolves row by row over ~385 frames) -> $28 (155 f) -> $29..$36.
Timeline (t = frames after d007; from build/gbend_log.json):

| t | state | what |
|---|---|---|
| 543 | $29 | LCD off, BG map cleared to $2C, brick ceiling+floor rows, Mario (c202 $38 -> x 56, c201 126) and Daisy (c212 120, c213 34) placed, music $0F |
| 546 | $2A | typewriter "OH! DAISY" at $98A5 (1 tile / 12 frames, script $1183: "OH! DAISY" FE "DAISY" = second line under it) |
| 744 | $2B | typewriter $11BF "THANK YOU MARIO." at $9902; Daisy walks left 1px/4f from 120 to $44 (67) |
| 957 | $2C | heart ($84) rises from (79,91) to y 31; |
| 1120 | $2D | typewriter $123F '"YOUR QUEST IS OVER"' at $9900; then c213 $24 (Daisy pose), c241 $7E/$28 (the plane object off right) |
| 1360 | $2E | the map SCROLLS (LevelColumnStream, ffa4 += ; ffe5/ffe6 column counters) -- text and room slide left; Daisy blinks pose (c213 ^1 every 4f); the plane (c240) taxis in from x $F0 down to $50/$40 |
| 1832 | $2F | c240..c245 copied into c200 (Mario + Daisy become the plane's riders), Mario pose $26 |
| 1896 | $30 | the plane rises 1px/2f from y 126 to $58 (88) |
| 1972 | $31 | flight: ffa4 scrolls; at wraps the HUD rows are blanked (Call_000_134e) and LYC raster set; three passing objects (c210/c220/c230 from tables $137F/$1384/$1389); music $11 when $dfe9 is clear |
| 2389 | $32 | scroll continues; when fffb runs out: LYC $60, text cursor -> $1557 (credits), ffa6 $F0 |
| 2517 | $33 | one credit pair written to $9A42 / $9A87 (name FE role); $34-$36 hold ~400 f and loop back to $33 with the next pair; the three passing objects re-enter at random x (rDIV) |

Texts (tile ids: 0-9 = $00-$09, A-Z = $0A-$23 with $23 also the '.', space $2C,
FE = next line, FF = end): "OH! DAISY"/"DAISY", "THANK YOU MARIO.",
'"YOUR QUEST IS OVER"', credits: PRODUCER/G.YOKOI, DIRECTOR/S.OKADA,
PROGRAMMER/M.YAMAMOTO, PROGRAMMER/T.HARADA, DESIGN/H.MATSUOKA, SOUND/H.TANAKA,
AMIDA/M.YAMANAKA, DESIGN/MASHIMO, SPECIAL THANKS TO?/TAKI, I'USHI, NAGATA, KANOH,
NISHI'AWA (the [27] is the apostrophe tile).

Sprites (OAM captures, build/gbend_oam.json has the tile data; ROM offsets below
for a RULE-5 build-time extraction): Mario standing $20 $21 / $30 $31; Daisy
standing $49 $4E / $50 $51 (x-flipped, attr $20), walking $48/$49 $4A/$4B pairs,
kissing poses $24 $25 / $34 $35 + $2E $2F / $3E $3F; heart $84; the plane with
both riders (32x16): $0E $4F $2D $4C / $1E $3C $3D $4D (later $26 $27 in the
left column); clouds behind the BG (attr $80): $7C $61 $7D $6F $7E $7B.
Tile sources in the user's ROM: {'0x0': '0x8032', '0x20': '0x8232', '0x21': '0x8242', '0x30': '0x8332', '0x31': '0x8342', '0x49': '0x84c2', '0x4e': '0x8512', '0x50': '0x8532', '0x51': '0x8542', '0x9e': '0x8a12', '0xac': '0x48b2', '0xad': '0x48c2', '0xae': '0x48d2', '0xaf': '0x48e2', '0xbc': '0x49b2', '0xbd': '0x49c2', '0xbe': '0x49d2', '0xbf': '0x49e2', '0xc7': '0x4a62', '0xcb': '0x4aa2', '0x48': '0x84b2', '0x4a': '0x84d2', '0x4b': '0x84e2', '0x84': '0x8872', '0x24': '0x8272', '0x25': '0x8282', '0x2e': '0x8312', '0x2f': '0x8322', '0x34': '0x8372', '0x35': '0x8382', '0x3e': '0x8412', '0x3f': '0x8422', '0xc': '0x80f2', '0xd': '0x8102', '0x1c': '0x81f2', '0x1d': '0x8202', '0x22': '0x8252', '0x23': '0x8262', '0x2c': '0xb', '0x2d': '0x8302', '0x32': '0x8352', '0x33': '0x8362', '0x3c': '0x83f2', '0x3d': '0x8402', '0x4c': '0x84f2', '0x4d': '0x8502', '0x4f': '0x8522', '0xe': '0x8112', '0x1e': '0x8212', '0x61': '0x4512', '0x6f': '0x4522', '0x7b': '0x4532', '0x7c': '0x4542', '0x7d': '0x4552', '0x7e': '0x4562', '0x7f': '0x4572', '0x26': '0x8292', '0x27': '0x82a2'}

Frame log: build/gbend_log.json (t, state, c200..c203, c210..c213, c240..c242,
ffa4, text cursor, fffb, dfe8, LCDC); contact sheets gbend_sheet0..5.png.

## Built: the 4-3 text ending (2026-09-05)

Stage 1 of the ending is implemented and gated. On Biokinton's ($60) defeat,
kit_sky43 veh_clear sets ending13=3; the goal sequence runs the jingle + tally
as usual, then goal_seq's phase-4 setup (main.s) branches on ending13==3 into a
new flow: goal_phase=5, e_phase=5 (>=E_WIPE), e_own=1, and l3e_room_copy loads
the L13E overlay. l3e_seq (unchanged) sees e_phase>=E_WIPE and jmp l3e_room,
which now dispatches ending13==3 -> l3e43 (the new overlay routine).

l3e43 (L13E overlay, so FIXED stays full): clears the framebuffer + the ring
tail ($5E00-$5FFF), points bgc at the resident font (bg_chardata -- 4-3's own
BG charset has scenery, not letters), pins the view to 0 and blanks the HUD
shadow every frame (calc_view still runs under e_own and the NMI still flushes
the HUD, so both are neutralised or they smear the score bar / clip the text /
leave a garbage strip). It then TYPES "OH DAISY", "THANK YOU MARIO", "YOUR
QUEST IS OVER" (resident font tiles, one glyph / 4 frames), holds, clears, and
shows "THE END" (holds). Verified on the real core: the boss kill leads into
the ending (no wrap to 1-1); text is centered and clean. svgold 9/9 identical
(the shared goal_seq edits do not disturb the x-3 rescue), battery31 all pass.

FIXED was full; the trigger's bytes came from: jsr clear_objects replacing the
inline object-clear loop, clear_objects preserving A (so ending13 is tested
without reload), the bonus @ring table's unused leading byte, and three local
jmp->bra. E_BEAT1 etc. unchanged.

REMAINING (stage 2+, docs/46 spec above): the animated Daisy/Mario/plane
cutscene, the heart, the plane flight over clouds, and the scrolling credits
roll. Those need the sprite tiles ($48-$51 Daisy, plane, heart, clouds)
extracted and placed. The text ending makes the game completable now.

## Stage 2: the credits roll (2026-09-05)

After the three Daisy lines the ending now rolls the credits: paged role-over-
name cards (PRODUCER/G YOKOI, DIRECTOR/S OKADA, PROGRAMMER/M YAMAMOTO), each
cleared and held ~2.5s, cycling forever (SML has no THE END card). All text is
the resident font. Verified on the real core: the pages render centered and
cycle.

The typewriter opening and both text blocks share one compact format to fit the
overlay: length-prefixed tile strings (`e43g_data` for the 3 lines, `e43c_data`
for the credits), drawn by `@drawline` (centering = 20 - len byte-columns,
computed at runtime). This was forced by a hard bank-1 wall: the L13E overlay is
STORED between L11CODE and the W3 tables at $B000 (slot = $AB45..$B000 = 1211
bytes), so the 4-array glyph format (608 B for the credits alone) did not fit --
it ran into the W3 tables. The compact strings + shared drawer brought L13E to
$4B4 (1204 B), just under. The credits were trimmed to 3 pages for the same
reason; more pages need either the credit data moved to a mapped bank-1 gap
($B195-$B520 is free) or the W3 tables relocated.

STILL NOT DONE (the animated cutscene): Daisy/Mario in the brick room, the
heart, boarding the Sky Pop, and the flight over clouds. Those need the sprite
tiles ($48-$51 Daisy, the plane, heart, clouds) extracted and a way to draw
non-resident tiles during the ending; the bank-1 space wall makes adding that
art non-trivial. The text ending + credits is what ships.
