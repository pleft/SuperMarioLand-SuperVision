; Level tilemap data (Watara-Supervision flat format).
; RULE 5: BUILD ARTIFACT generated from the user's ROM by tools/extract_levels.py
; (build/levels/level_NN.bin, gitignored). Column-major, 16 tile bytes per column.
;
; MULTI-LEVEL CONTRACT: bank 0 links the TITLE plus ONE level's data; the other
; banks get theirs written by tools/pack_banks.py at the TITLE0 address. Bank 0
; hosts 1-2 (the smallest W1 level) so the title+level pair leaves headroom;
; 1-1 lives in bank 1 (see lvl_bank_tab in main.s).

.segment "LEVEL0"

.import chardata
.import bg_chardata
.export level_hdr
level_hdr:                                    ; 22-byte level header
    .addr level0_map                          ; +0  surface map: the column POINTER
    .word L12_COLS                            ; +2  table (2B/col -> unique-col pool;
                                              ;     docs/33) + column count
    .word 0                                   ; +4  room 0 map (0 = none — 1-2's two ROM
    .word 0                                   ; +6  room 1 map   rooms are unreachable
    .word 0                                   ; +8  room 2 map   leftovers: empty pipe list)
    .addr pipe_table                          ; +10 pipe entries (5 B each)
    .byte (pipe_table_end - pipe_table) / 5   ; +12 pipe count
    .addr block_table                         ; +13 ?-block contents (4 B each)
    .byte (block_table_end - block_table) / 4 ; +15 block count
    .addr spawn_table                         ; +16 enemy spawns ($FFFF-terminated)
    .addr chardata                            ; +18 quad-tile $A0-$DC base (W1: FIXED)
    .word 0                                   ; +20 overlay blob address (W1: none)
    .addr bg_chardata                         ; +22 bg charset base (W3: bank-1 copy)

    .include "levels/level_01_dedup.inc"     ; World 1-2: ptr table + column pool

; (1-2's two room blobs are dropped: its pipe list is empty in the ROM, so they are
;  unreachable leftovers — see docs/24. The header's room ptrs are 0.)
pipe_table:                                   ; 5 bytes/pipe: entry_col(16), room, resume_col(16)
    .incbin "build/levels/level_01_pipes.bin"
pipe_table_end:

block_table:                                  ; 4 bytes/block: col(16), row, content value
    .incbin "build/levels/level_01_blocks.bin"
block_table_end:

spawn_table:                                  ; 4 bytes/entry: fire_cam(16), o_y, type;
    .incbin "build/levels/level_01_spawns.bin" ; $FFFF-terminated (enemy spawn list)
