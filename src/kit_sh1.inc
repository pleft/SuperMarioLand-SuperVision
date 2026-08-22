; cull once the camera passes 20px beyond (the walker rule)
.proc l3_cull                    ; C=1 -> culled (slot freed)
.ifdef MAR23
    lda o_y,x                    ; VERTICAL cull, BOTH ways. 2-3's enemies leave
    cmp #168                     ; the screen downward (the honen's leap) and
    bcs @cull                    ; upward (the torion aims at Mario), and o_y is
    cmp #8                       ; a BYTE: off the bottom it runs past 255 and
    bcc @cull                    ; wraps; off the top it hits 0 and wraps the
.endif                           ; other way, in ONE step. Either way the enemy
                                 ; re-enters from the
                                 ; TOP and falls forever. Found twice by the
                                 ; anomaly sweep (honen, then torion at visual
                                 ; y 263) -- the second one nobody had noticed.
    lda o_xl,x
    clc
    adc #20
    sta tmpL3
    lda o_xh,x
    adc #0
    cmp cam_x+1
    bcc @cull
    bne @keep
    lda tmpL3
    cmp cam_x
    bcc @cull
@keep:
    clc
    rts
@cull:
    stz o_type,x
    sec
    rts
.endproc

; Mario overlap (the enemy_contact box): |dx|<10 (centres) and |spr_y-o_y|<14
.proc l3_box                     ; C=1 -> touching
    jsr mario_dx
    lda tmpH3
    bne @no
    lda tmpL3
    cmp #10
    bcs @no
    lda spr_y
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #14
    bcs @no
    sec
    rts
@no:
    clc
    rts
.endproc

; --- SUU $02: 200f cycle -- 62f hold low, 16f rise, 105f hold high (anim
; toggles every ~16f), 16f descend (trace: y 120<->104 GB) ---
.ifndef MAR23                    ; 2-3 spawns no Suu -- reclaim
.proc upd_suu
    jsr l3_cull
    bcc :+
    rts
:   lda o_tmr,x
    cmp #62
    bcs :+
    jsr mario_dx                 ; classic pipe-plant rule (GB capture): while
    lda tmpH3                    ; Mario is flush with the column it stays down
    bne @tick
    lda tmpL3
    cmp #10
    bcs @tick
    ldx oi
    stz o_tmr,x
    bra @tick
:   cmp #78
    bcs :+
    dec o_y,x                    ; rising 1px/f
    bra @tick
:   cmp #183
    bcc @tick                    ; top hold (anim via l3_token/draw)
    inc o_y,x                    ; descending
@tick:
    inc o_tmr,x
    lda o_tmr,x
    cmp #199
    bcc :+
    stz o_tmr,x
:   ; contact: star -> silent despawn +100 ($3186 +3 = $FF); else ANY touch hurts
    jsr l3_box
    bcs :+
    rts
:   lda mario_starT
    beq @hurt
    stz o_type,x
    lda #$01
    jmp award_kill
@hurt:
    jmp l3_hurt                  ; hurt from the side only (see l3_hurt)
.endproc
.endif

; --- ROCK $0C: hangs 174f, then falls 1px/f THROUGH terrain; gone at y>=168.
; Spiky: any contact hurts; star/ball have no effect ($3186: 00 00 FF 00 00) ---
.if .not (.defined(YUR22) .or .defined(MAR23)) ; 2-2/2-3: no spiky ball
.proc upd_rock
    lda o_tmr,x
    cmp #174
    bcs @fall
    inc o_tmr,x
    bra @touch
@fall:
    inc o_y,x
    lda o_y,x
    cmp #168
    bcc @touch
    stz o_type,x
    rts
@touch:
    jsr l3_box
    bcs :+
    rts
:   lda mario_starT              ; the star does NOT clear it -- but it must not
    bne @no                      ; hurt starred Mario either
    jmp l3_hurt    
@no:
    rts
.endproc
.endif
