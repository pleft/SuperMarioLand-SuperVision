; Level tilemap data (Watara-Supervision flat format).
; RULE 5: BUILD ARTIFACT generated from the user's ROM by tools/extract_levels.py
; (build/levels/level_NN.bin, gitignored). Column-major, 16 tile bytes per column.
;
; MULTI-LEVEL CONTRACT: this object is linked LAST into the LEVELS segment, so
; level_hdr sits at a fixed address right after the common (per-bank duplicated)
; prefix. tools/pack_banks.py replicates the same header+blobs layout for banks
; 1+ at the identical offset; load_level reads everything through the header.

.segment "LEVEL0"

.export level_hdr
level_hdr:                                    ; 18-byte level header
    .addr level0_map                          ; +0  surface map (column-major, 16 B/col)
    .word (level0_end - level0_map) / 16      ; +2  column count
    .addr room0_map                           ; +4  room 0 map (0 = none)
    .addr room1_map                           ; +6  room 1 map
    .word 0                                   ; +8  room 2 map (1-1 has two rooms)
    .addr pipe_table                          ; +10 pipe entries (5 B each)
    .byte (pipe_table_end - pipe_table) / 5   ; +12 pipe count
    .addr block_table                         ; +13 ?-block contents (4 B each)
    .byte (block_table_end - block_table) / 4 ; +15 block count
    .addr spawn_table                         ; +16 enemy spawns ($FFFF-terminated)

level0_map:
    .incbin "build/levels/level_00.bin"      ; World 1-1, 16 tiles/column
level0_end:

; Underground pipe rooms (one 20-column screen each) + the pipe table.
room0_map:
    .incbin "build/levels/level_00_room0.bin"
room1_map:
    .incbin "build/levels/level_00_room1.bin"

pipe_table:                                   ; 5 bytes/pipe: entry_col(16), room, resume_col(16)
    .incbin "build/levels/level_00_pipes.bin"
pipe_table_end:

block_table:                                  ; 4 bytes/block: col(16), row, content value
    .incbin "build/levels/level_00_blocks.bin"
block_table_end:

spawn_table:                                  ; 4 bytes/entry: fire_cam(16), o_y, type;
    .incbin "build/levels/level_00_spawns.bin" ; $FFFF-terminated (enemy spawn list)
