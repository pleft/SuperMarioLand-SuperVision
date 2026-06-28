; Level tilemap data (Watara-Supervision flat format).
; RULE 5: BUILD ARTIFACT generated from the user's ROM by tools/extract_levels.py
; (build/levels/level_NN.bin, gitignored). Column-major, 16 tile bytes per column.

.segment "LEVELS"
.export level0_map
level0_map:
    .incbin "build/levels/level_00.bin"      ; World 1-1, 16 tiles/column
level0_end:
.export level0_cols
level0_cols = (level0_end - level0_map) / 16  ; column count (data-driven camera limits)
