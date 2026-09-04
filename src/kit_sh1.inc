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
.if .not (.defined(MAR23) .or .defined(EAS3)) ; (not 2-3: its bank is full to 10
                                 ;  bytes and its enemies never escape rightward;
                                 ;  not the W3/W4 kit: w3_step bounds every VM slot
                                 ;  itself, every frame -- the window is full)
    lda o_xl,x                   ; RIGHT-side bound: an object >= 256px ahead of
    sec                          ; the camera (96px past the screen's right edge;
    sbc cam_x                    ; spawns land at +192..204 and walk in) is gone
    lda o_xh,x                   ; for good. 4-2: a $4B missile fired rightward
    sbc cam_x+1                  ; ran 1700px ahead of Mario for 1400 frames,
    bmi @keep                    ; holding its slot and its per-frame cost
    cmp #1                       ; (docs/45; the GB lets one fly ~220px past the
    bcs @cull                    ; edge before it vanishes -- never 1700).
.endif                           ;  enemies never escape rightward there)
@keep:                           ; (bmi: within the 20px grace LEFT of the camera
    clc                          ;  the difference is negative -- not a cull)
    rts
@cull:
    stz o_type,x
    sec
    rts
.endproc

; Mario overlap (the enemy_contact box): |dx|<10 (centres); the y window is
; the GB's own per-type collision height. PhysicsParam byte 1's LOW NIBBLE is
; the box height in rows (the hi nibble is width; bit7 = standable, docs/41),
; and the art sits at the BOTTOM of the cell -- so for a 16-tall type the old
; |spr_y - o_y| < 14 is exact, but for the 8-tall missile it overcounted by
; 8px: the $4B fired from the pipe cannon passed 6px under STANDING Mario's
; feet and got "stomped" at the muzzle (user-reported; GB-measured: the same
; pass at 8px does nothing). Window: 3-h <= spr_y - o_y <= 13.
.proc l3_box                     ; C=1 -> touching
    jsr mario_dx
    lda tmpH3
    bne @no
    lda tmpL3
    cmp #10
    bcs @no
.ifdef EAS3
    lda #16                      ; kit types (suu): the full-cell box
    sta tmpH3                    ; h lives in tmpH3: w3_touch stores its stomp
    lda o_type,x                 ; target in tmpL2 right after this returns, and
    cmp #OBJ_W3                  ; it still needs h for the stomp/side division
    bne :+
    lda w3_ph1,x                 ; the per-slot phys1 mirror (w3_init_keepdir)
    and #$0F
    asl
    asl
    asl
    sta tmpH3                    ; h = the GB box height in px
:   lda spr_y
    sec
    sbc o_y,x                    ; dy (signed)
    clc
    adc tmpH3
    sec
    sbc #3                       ; dy + h - 3: in [0, h+10] -> touching
    sta tmpH2
    lda tmpH3
    clc
    adc #10
    cmp tmpH2
    bcc @no
    sec
    rts
.else
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
.endif
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
.ifndef EAS3                     ; W3 spawns no $0C -- reclaim the window
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
.endif
