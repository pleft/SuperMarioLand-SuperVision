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

; Underground pipe rooms (one 20-column screen each) + the pipe table.
.export room0_map, room1_map, room_ptrs
room0_map:
    .incbin "build/levels/level_00_room0.bin"
room1_map:
    .incbin "build/levels/level_00_room1.bin"
room_ptrs:                                    ; indexed by room number
    .addr room0_map
    .addr room1_map

.export pipe_table, pipe_count
pipe_table:                                   ; 5 bytes/pipe: entry_col(16), room, resume_col(16)
    .incbin "build/levels/level_00_pipes.bin"
pipe_table_end:
pipe_count = (pipe_table_end - pipe_table) / 5

.export block_table, block_count
block_table:                                  ; 4 bytes/block: col(16), row, content value
    .incbin "build/levels/level_00_blocks.bin"
block_table_end:
block_count = (block_table_end - block_table) / 4

.export spawn_table
spawn_table:                                  ; 4 bytes/entry: fire_cam(16), o_y, type;
    .incbin "build/levels/level_00_spawns.bin" ; $FFFF-terminated (enemy spawn list)
