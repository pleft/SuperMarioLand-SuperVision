.proc l3_xoff                    ; X = slot; C=1 -> off-screen (slot freed)
    lda o_xl,x
    sec
    sbc cam_x
    sta tmpL3
    lda o_xh,x
    sbc cam_x+1
    bne @off
    lda tmpL3
    cmp #200
    bcc @on
@off:
    stz o_type,x
    sec
    rts
@on:
    clc
    rts
.endproc
