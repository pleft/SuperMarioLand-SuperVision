; --- GIFT $13: sits on its block; stomp -> floats away 0.5px/f to the top row,
; holds ~230f, pops with the kill thump (capture f395). No score, no hurt ---
.proc upd_gift                   ; the hidden-block LIFT ($13->$14, the stone's
    lda o_st,x                   ; ride-morph pattern: LANDING arms the rise)
    beq @sit
    cmp #1
    beq @rise
    inc o_tmr,x                  ; holding at the top row (~229f), then pops
    lda o_tmr,x
    cmp #229
    bcc @done
    lda #SFX_DFF8_03             ; the thump ($14's script tail); the rider falls
    jsr sfx_play                 ; (ride_support clears when the slot dies)
    ldx oi
    stz o_type,x
@done:
    rts
@rise:
    txa                          ; 0.5px/f up, CARRYING the rider (GB: it hauls
    eor frame_count              ; Mario 68px to the upper corridor)
    lsr
    bcs @done
    dec o_y,x
    jsr carry_y_up
    ldx oi
    lda o_y,x
    cmp #9                       ; GB-exact top (GB holds at y=32 = o_y 8). The rider
    bcs @done                    ; is hidden under the HUD up there until the over-HUD
    lda #2                       ; sprite renderer ships (parked) — user-accepted
    sta o_st,x
    stz o_tmr,x
    rts
@sit:
    lda o_tmr,x                  ; emerge: 4px rise over 8f
    cmp #8
    bcs @armed
    inc o_tmr,x
    lsr
    bcs @done
    dec o_y,x
    rts
@armed:
    lda ride                     ; ridden -> start rising (the $13->$14 morph fires
    beq @done                    ; on the LANDING, like the stone's $36->$37)
    dea
    cmp oi
    bne @done
    lda #1
    sta o_st,x
    stz o_tmr,x
    rts
.endproc

.proc l3_gift                    ; hit_qblock content $07: emerge on top of the block
    jsr spawn_item_snd           ; GB bonk capture: dfe0=$07 thud then $0B emerge --
                                 ; the emerge chime is the surviving/distinctive one
    jsr find_free_obj
    bcs @full
    lda #OBJ_GIFT
    sta o_type,x
    jsr obj_set_x8
    lda mrow
    asl
    asl
    asl
    clc
    adc #4                       ; emerges 4px (rises to mrow*8 over 8 frames)
    sta o_y,x
    stz o_st,x
    stz o_tmr,x
    stz o_vx,x
@full:
    rts
.endproc
