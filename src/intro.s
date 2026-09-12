; ---------------------------------------------------------------------------
; INTRO -- the port's own pre-title boot splash (docs/48), in the spirit of the
; Watara Supervision / Travellmate boot logo but ORIGINAL: the author tag
; "ELEFAS" rises smoothly from the bottom of a white screen to the centre while
; a rising C-E-G-C major arpeggio chimes on square 1; it holds, then returns to
; the boot flow (reset then clears + draws the title).
;
; It is stored in a free 512K page (13). reset maps that page and JSRs its
; $8000; the stub below (running there) copies the whole blob into the $1500 RAM
; overlay window, jumps into that copy, maps bank 0 back (so the HUD font at
; bg_chardata is readable and the title is reachable) and runs. It calls the
; always-mapped FIXED primitives (set_dst/blit_tile/get_tile_src/blit_blank/
; bank_set) via the engine ABI, exactly like the W2/W3/E43 overlays. Keeping the
; relocation here (not in reset) keeps the FIXED bank within budget. The blob
; must stay <= 256 bytes (the stub copies one page).
; ---------------------------------------------------------------------------
.setcpu "65C02"
.include "w2abi.inc"             ; engine addresses (dcol, dy, set_dst, blit_tile,
                                 ; get_tile_src, blit_blank, frame_flag, bank_set, tmpL..)

CH1_FLO     = $2010              ; square 1 (supervision.inc); the jingle owns it,
CH1_FHI     = $2011              ; then silences it before returning
CH1_VOLDUTY = $2012              ; bit6 enable | bits5:4 duty | bits3:0 volume
CH1_LEN     = $2013

TOP_BOTTOM  = 136               ; word starts here (row 17) ...
TOP_CENTRE  = 72                ; ... and rises to here (row 9)
CENTER_DCOL = 14                ; 6 tiles centred in 20 cols -> cols 7..12

.segment "INTRO"                ; page 13 $8000 (run there first), then $1500

; --- self-relocation stub: entry at $8000 (page 13 mapped). Copy the blob into
;     the $1500 window (one page), then jump into that copy. ---
    ldx #0
@reloc:
    lda $8000,x
    sta $1500,x
    inx
    bne @reloc
    jmp run                      ; absolute $1500-region label (now populated)

run:
    lda #0
    jsr bank_set                 ; map bank 0: the HUD font + title live there
    jsr clear_vram               ; white screen for the splash
    lda #TOP_BOTTOM
    sta tmpL2                    ; tmpL2 = the word's current top scanline
    jsr draw_word                ; initial draw at the bottom
    stz tmpH3                    ; jingle/frame counter
@rise:
    jsr wait1                    ; advance one displayed frame
    jsr jingle
    lda tmpL2
    cmp #TOP_CENTRE
    beq @hold                    ; reached the centre -> hold
    jsr blank_word               ; erase the old position (8 rows)
    lda tmpL2
    sec
    sbc #2                       ; 2 px/frame up
    sta tmpL2
    jsr draw_word                ; redraw 2 px higher (top 2 px new, bottom 2 cleared)
    bra @rise
@hold:
    ldx #80                      ; hold the settled logo while the chime finishes
@hloop:
    jsr wait1
    jsr jingle
    dex
    bne @hloop
    stz CH1_FLO                  ; return square 1 to its boot state (FLO/LEN/VOLDUTY
    stz CH1_LEN                  ; = 0) so the level starts exactly as before the splash
    stz CH1_VOLDUTY              ; existed -- a leftover CH1 state nudges a W3 object's
    jsr clear_vram               ; phase (E-gate). Then clear + run the SML title (waits
    jmp title_screen             ; for Start, sets cur_level) and return to reset

; --- draw the 6 "ELEFAS" tiles at the current top scanline (tmpL2) ---
.proc draw_word
    stz tmpL                     ; letter index (X is clobbered by set_dst's ldx dy)
@l:
    lda tmpL
    asl
    clc
    adc #CENTER_DCOL
    sta dcol
    lda tmpL2
    sta dy
    jsr set_dst
    ldx tmpL
    lda letters,x
    jsr get_tile_src
    jsr blit_tile
    inc tmpL
    lda tmpL
    cmp #6
    bne @l
    rts
.endproc

; --- white-fill the 6-tile band at the current top scanline ---
.proc blank_word
    stz tmpL
@l:
    lda tmpL
    asl
    clc
    adc #CENTER_DCOL
    sta dcol
    lda tmpL2
    sta dy
    jsr set_dst
    jsr blit_blank
    inc tmpL
    lda tmpL
    cmp #6
    bne @l
    rts
.endproc

; --- wait one displayed frame (the NMI drives frame_flag) ---
.proc wait1
    lda frame_flag
    beq wait1
    stz frame_flag
    rts
.endproc

; --- one rising note every 8 frames (C-E-G-C), sustained into the next ---
.proc jingle
    lda tmpH3
    cmp #96
    bcs @done
    inc tmpH3
    lda tmpH3
    and #7
    bne @done                    ; only on multiples of 8 (frames 8/16/24/32)
    lda tmpH3
    lsr
    lsr
    lsr                          ; /8 -> 1..
    sec
    sbc #1                       ; note index 0..
    cmp #4
    bcs @done                    ; only the first four
    tax
    lda notes,x
    sta CH1_FLO
    stz CH1_FHI
    lda #$FF
    sta CH1_LEN
    lda #$6E                     ; enable | duty 2 | vol 14
    sta CH1_VOLDUTY
@done:
    rts
.endproc

letters: .byte $0E,$15,$0E,$0F,$0A,$1C   ; E L E F A S (HUD font, A=$0A..Z=$23)
notes:   .byte 235,186,157,117           ; C5 E5 G5 C6 (period ~122900/Hz)
