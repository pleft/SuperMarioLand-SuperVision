.proc suu_frame                  ; X = slot -> A = 0/2 (tile offset)
    lda o_tmr,x
    cmp #78
    bcc @a
    cmp #183
    bcs @a
    sec
    sbc #78
    lsr
    lsr
    lsr
    lsr
    and #1
    beq @a
    lda #2
    rts
@a:
    lda #0
    rts
.endproc

.proc draw_suu
    ldx oi
    lda o_y,x
    cmp o_vy,x                   ; fully retracted into the pipe: invisible
    bcs @done
    jsr suu_frame
    sta tmpL3
    ldx oi
    lda o_y,x                    ; top tile
    sta dy
    lda spr_col
    sta dcol
    lda #SUU_TA
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ldx oi
    lda o_y,x                    ; bottom tile -- only once clear of the rim
    clc
    adc #8
    cmp o_vy,x
    bcs @done
    sta dy
    lda spr_col
    sta dcol
    lda #SUU_TA+1
    clc
    adc tmpL3
    tax
    jsr draw_quad
@done:
    rts
.endproc

.ifndef YUR22
.proc draw_rock
    lda #ROCK_TL
    sta tmpL3
    lda #ROCK_TL+1
    sta tmpH3
    jmp l3_pair
.endproc
.endif

.proc l3_pair                    ; tmpL3/tmpH3 = left/right tiles, at o_y+8
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    ldx tmpL3
    jsr draw_quad
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    ldx tmpH3
    jmp draw_quad
.endproc

.proc l3_one                     ; X = tile, at o_y+8 (8x8 items)
    ldy oi
    lda o_y,y
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    jmp draw_quad
.endproc
