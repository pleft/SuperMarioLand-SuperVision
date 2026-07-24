; --- pass-4 erase widths ---
.proc l3_width                   ; Y = type -> A = o_pw
    cpy #OBJ_SUU
    bne :+
    lda #$82                     ; 8 wide, 16 tall
    rts
:   cpy #OBJ_GAO
    beq @w83
    cpy #OBJ_GCORP
    beq @w83
    cpy #OBJ_BAT
    bne :+
    lda #$C5                     ; 32 wide + tall + EXTRA-tall (24px, bit6)
    rts
:   cpy #OBJ_FIRE
    beq @w2
    cpy #OBJ_GIFT
    beq @w2
    lda #3                       ; rock / bull / gsq: 16 wide
    rts
@w83:
    lda #$83                     ; 16 wide + tall
    rts
@w2:
    lda #2
    rts
.endproc

; --- anim tokens (MUST mirror the draw-frame choices above) ---
.proc l3_token                   ; X = slot -> A = token
    lda o_type,x
    cmp #OBJ_SUU
    bne :+
    jmp suu_frame
:   cmp #OBJ_GAO
    bne :+
    lda o_tmr,x
    cmp #89
    lda #0
    rol                          ; C -> bit0: the mouth state
    rts
:   cmp #OBJ_BAT
    bne :+
    lda o_tmr,x
    cmp #31
    lda #0
    rol
    rts
:   cmp #OBJ_BULL
    bne :+
    lda frame_count
    and #8
    rts
:   lda #0                       ; rock/fire/gift/gsq static; gcorp moves every frame
    rts
.endproc
