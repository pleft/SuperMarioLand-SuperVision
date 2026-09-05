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
