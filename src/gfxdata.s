; Converted tile graphics (Watara-Supervision-packed) for the port.
; RULE 5: these binaries are BUILD ARTIFACTS generated from the user's own ROM by
; tools/extract_gfx.py (build/gfx/*.svt, gitignored). Only the .incbin directives
; are committed, never the ROM-derived bytes.

.segment "CHARS"

; OBJ tiles ($4032->$8000): sprites + UI. Also the $8800 half = BG tiles $80-$FF.
.export chardata
chardata:
    .incbin "build/gfx/w1_obj_8000.svt"      ; 256 tiles

; BG tiles ($5032->$9000): used by level tiles $00-$7F (LCDC.4=0, $8800 signed mode).
; In BANK0 (always mapped) -- FIXED ran out of room as the engine grew.
.segment "LEVELS"
.export bg_chardata
bg_chardata:
    .incbin "build/gfx/w1_bg_9000.svt"        ; 128 tiles
