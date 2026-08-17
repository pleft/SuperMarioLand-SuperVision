; ---------------------------------------------------------------------------
; W2CODE -- the WORLD 2 kit overlay. Assembled STANDALONE after the main link
; (engine addresses come from build/w2abi.inc), linked to run in the $1500
; window, shipped as a blob inside each W2 bank's level region (header +20/21
; points at it; ovl_bind copies it in and jumps $1500 = `init` below).
;
; Content: the SHARED kit pieces (src/kit_sh*.inc -- byte-identical source
; with the 1-3 kit): Suu the pipe spider ($02), the spiky ball ($0C), and the
; RISING LIFT (content $F0 -> l3_gift/upd_gift = 2-1/2-2's blocked passages).
; Next: Honen ($10) and the Yurarin leaper ($24).
; ---------------------------------------------------------------------------
.include "w2abi.inc"
.include "../build/audio/sfx.inc"

; --- object ids + kit tiles (mirror main.s; the GB sheets are common) ---
OBJ_BOOM   = 16                  ; engine explosion (the GB $27 corpse visual)
OBJ_GIFT   = 22
OBJ_SUU    = 23
OBJ_ROCK   = 24
OBJ_GAO    = 25                  ; referenced by shared width/token chains only
OBJ_FIRE   = 26
OBJ_BAT    = 27
OBJ_BULL   = 28
OBJ_GSQ    = 29
OBJ_GCORP  = 30
OBJ_HONEN  = 31                  ; $10: the leaping fishbone (script $36D1)
OBJ_LEAP   = 32                  ; $24: YURARIN BOO -- vertical bob + shoots (script $37EB)
OBJ_HCORP  = 33                  ; their ball/stomp corpses (dead-flip hop+fall)
OBJ_LCORP  = 34
OBJ_WBALL  = 35                  ; Yurarin Boo's shot: tile $E2 (the common
                                 ; fireball), aimed at Mario once at launch
SUU_TA  = $92
ROCK_TL = $DD
GAO_TL  = $A4
GAO_SQA = $B9
FIRE_T  = $E2
GIFT_T  = $E6
; PORT tile ids (the packer's compact slice; GB sources in pack_banks.py):
LEAP_TA = $A4                    ; 16x16 quad: TL,TR,BL,BR; frame B = +4
HON_TA  = $AC                    ; 8x16: top,bottom; frame B = +2

.segment "W2C"

init:                            ; $1500: bind our vector table
    ldx #11
:   lda vec_tab,x
    sta ovl_vec,x
    dex
    bpl :-
    rts

vec_tab:
    .addr w2_spawn, w2_update, w2_token, w2_gift, w2_draw, w2_width

.proc w2_gift                    ; content $F0 (GB $18C0, READ this time): the
    jmp mark_used                ; hidden cell MATERIALIZES as a solid block (GB
.endproc                         ; stamps $80; our mod renders $5F as used-solid).
                                 ; No object, no lift -- a stepping block. Its
                                 ; re-bonk = the content-0 "nothing" case.

.proc w2_spawn                   ; A = GB type, Y = spawn entry byte offset
    cmp #$02
    bne :+
    lda #OBJ_SUU
    bra @go
:   cmp #$0C
    bne :+
    lda #OBJ_ROCK
    bra @go
:   cmp #$10
    bne :+
    lda #OBJ_HONEN
    bra @go
:   cmp #$24
    bne @consume
    lda #OBJ_LEAP
    jsr @go                      ; common body, then the pre-hop aim (F0 $60:
    bcs @full                    ; the script faces Mario before the first rise)
    jsr aim_leap
    clc                          ; consumed (aim's cmp may leave C set)
    rts
@go:
    jsr obj_alloc_typed
    bcs @full                    ; pool full: C=1 -> the spawner retries
    stz o_pdr,x                  ; fresh slot: NOTHING to erase (a stale "was
                                 ; drawn" flag ghost-restored map tiles)
    jsr spawn_tabx               ; world x = fire + 192 + x_off*4 (the GB rule)
    lda spawn_tab+2,y
    sta o_y,x
    stz o_vx,x
    sta o_vy,x                   ; base y = the column rim (draw clip + hold)
    stz o_tmr,x
    stz o_st,x
@consume:
    clc                          ; unknown W2 types (honen/leaper: next) consume
@full:
    rts
.endproc

.proc w2_update                  ; X = slot; types 22..24
    lda o_type,x
    sec
    sbc #OBJ_GIFT
    cmp #9                       ; 25-30 never exist in W2: collapse the gap
    bcc :+
    sbc #6
:   asl
    tay
    lda w2_updtab+1,y
    pha
    lda w2_updtab,y
    pha
    rts
.endproc
w2_updtab:
    .word w2_rts-1, upd_suu-1, upd_rock-1
    .word upd_honen-1, upd_leap-1, w2_nop-1, w2_nop-1, upd_wball-1

.proc w2_draw                    ; A = o_type (engine convention), X = slot
    sec
    sbc #OBJ_GIFT
    cmp #9
    bcc :+
    sbc #6
:   asl
    tay
    lda w2_drwtab+1,y
    pha
    lda w2_drwtab,y
    pha
    rts
.endproc
w2_drwtab:
    .word w2_rts-1, draw_suu-1, draw_rock-1
    .word draw_honen-1, draw_leap-1, w2_nop-1, w2_nop-1, draw_wball-1

w2_rts:
    rts

; ---------------------------------------------------------------------------
; The MUDA LEAP (script $36D1/$37EB under the decoded AI-VM, docs/12): a
; symmetric ~111px arc from the spawn line. UP: 52f at 2px + 7f at 1px + 3f
; hang; DOWN mirrored, clamped at the base line (o_vy); then ~36f rest.
; arc_step: X = slot. tmpH3 = this frame's |dy| (the leaper moves x by it).
; On a phase transition tmpL2 = the NEW phase; else tmpL2 = $FF.
.proc arc_step
    lda #$FF
    sta tmpL2
    stz tmpH3
    lda o_st,x
    bne @notup
    lda o_tmr,x                  ; UP
    cmp #52
    bcs :+
    lda #2
    bra @up
:   cmp #59
    bcs :+
    lda #1
    bra @up
:   cmp #62
    bcc @tick                    ; hang (dy 0)
    lda #1                       ; -> DOWN
    sta o_st,x
    sta tmpL2
    stz o_tmr,x
    rts
@up:
    sta tmpH3
    eor #$FF                     ; o_y -= dy
    ina
    clc
    adc o_y,x
    sta o_y,x
    bra @tick
@notup:
    cmp #2
    beq @rest
    lda o_tmr,x                  ; DOWN
    cmp #3
    bcc @tick                    ; hang
    cmp #10
    bcs :+
    lda #1
    bra @dn
:   lda #2
@dn:
    sta tmpH3
    clc
    adc o_y,x
    sta o_y,x
    cmp o_vy,x                   ; the base line clamps the fall
    bcc @tick
    lda o_vy,x
    sta o_y,x
    lda #2                       ; -> REST
    sta o_st,x
    sta tmpL2
    stz o_tmr,x
    stz tmpH3
    rts
@rest:
    lda o_tmr,x
    cmp #36
    bcc @tick
    stz o_st,x                   ; -> UP again
    stz o_tmr,x
    stz tmpL2
    rts
@tick:
    inc o_tmr,x
    rts
.endproc

.proc foe_frame                  ; X = slot -> A = 0/1 (the ~15f wing flap)
    lda o_tmr,x
    lsr
    lsr
    lsr
    lsr
    and #1
    rts
.endproc

.proc aim_leap                   ; o_hp = +1 if Mario is right of slot X, else -1
    lda cam_x
    clc
    adc spr_x
    sta tmpH2                    ; mario world x (16-bit)
    lda cam_x+1
    adc #0
    cmp o_xh,x
    bcc @left
    bne @right
    lda tmpH2
    cmp o_xl,x
    bcs @right
@left:
    lda #$FF
    bra :+
@right:
    lda #1
:   sta o_hp,x                   ; (o_hp is free for kit foes; o_pdr is the
    rts                          ;  ENGINE'S was-drawn flag -- hands off)
.endproc

; foe contact: star -> corpse+points at the victim; stomp side -> corpse +
; Mario's fixed bounce + combo-chained points; side -> hurt. A = value code.
.proc w2_foe
    jsr l3_box
    bcs :+
    rts
:   ldx oi
    lda mario_starT
    bne @kill
    jsr l3_above
    bcc @stomp
    jmp hurt_mario
@stomp:
    jsr foe_code                 ; class code from the type, BEFORE the despawn
    pha                          ; (a tmp would die under mario_dx's scratch)
    stz o_type,x                 ; stomp = SILENT DESPAWN, no corpse/animation
                                 ; (GB $3186 row +0 = $FF for $10/$24; user-observed)
    lda #1                       ; the fixed stomp bounce (RE $08C7)
    sta jump_state
    lda #14
    sta arc_idx
    stz fall_v
    stz ride
    pla
    jmp award_stomp
@kill:
    jsr foe_code
    pha
    jsr foe_corpse
    ldx oi
    jsr victim_xy
    lda o_y,x
    sta tmpH3
    pla
    jmp award_kill_at
.endproc

.proc foe_code                   ; X = slot -> A = value code (honen 100, leap 400)
    lda o_type,x
    cmp #OBJ_LEAP
    beq :+
    lda #$01
    rts
:   lda #$04
    rts
.endproc

.proc foe_corpse                 ; slot X's foe -> the GB $27 corpse = a static
    ldx oi                       ; 16x16 explosion puff, ~32f (PyBoy star-kill
    lda #OBJ_BOOM                ; capture: tiles $9D/$9E quad, no motion) --
    sta o_type,x                 ; the engine's cloud IS that visual.
    lda #32
    sta o_tmr,x
    rts
.endproc

.proc upd_honen
    jsr l3_cull
    bcc :+
    rts
:   jsr arc_step
    lda #$01                     ; class 0 = 100
    jmp w2_foe
.endproc

.proc upd_leap                   ; YURARIN BOO: the mover's velocity low nibble
    jsr l3_cull                  ; is 0 -> NO x movement ever (GB $2879 masks
    bcc :+                       ; $0F for x); F0's track-Mario bit sets FACING
    rts                          ; only. It bobs the script arc and SHOOTS at
:   jsr aim_leap                 ; GB capture: re-faces Mario IMMEDIATELY
    jsr arc_step                 ; (flip within ~2f of him crossing sides,
    lda tmpL2                    ; mid-bob) -- track every frame, not per phase
    cmp #1                       ; dive transition: F9 $04 + F1 -> child $23
    bne @foe
    lda #SFX_DFF8_04
    jsr sfx_play
    ldx oi
    jsr spawn_wball              ; launch the aimed ball
@foe:
    jmp w2_foe
.endproc

.proc spawn_wball                ; child type $23: single-aimed slow ball
    lda #OBJ_WBALL
    jsr obj_alloc_typed
    bcs @full                    ; pool full: the shot fizzles
    stz o_pdr,x
    ldy oi                       ; from the shooter's mouth
    lda o_xl,y
    sta o_xl,x
    lda o_xh,y
    sta o_xh,x
    lda o_y,y
    clc
    adc #4
    sta o_y,x
    lda o_hp,y                   ; x-dir = the shooter's facing (F0 $C0 aims
    sta o_vx,x                   ; both axes at Mario at init)
    jsr rc_wball_aim             ; GB: straight line to Mario (engine RCODE)
@full:
    ldx oi
    rts
.endproc

; the ball: GB-captured motion -- x 0.5px/f, y = the aimed Bresenham slope
; (rc_wball_move), no gravity, lives until it leaves the screen; ANY contact
; hurts (a projectile).
.proc upd_wball
    jsr rc_wball_move
    lda o_y,x
    cmp #16
    bcc @gone
    cmp #152
    bcs @gone
    jsr l3_cull                  ; camera passed it
    bcc :+
    rts
:   jsr wball_box                ; a projectile: any touch hurts (tight 8px box)
    bcs @hit
    rts
@hit:
    lda mario_starT              ; starred Mario: the ball passes harmlessly
    beq :+                       ; (GB $3186 row $23, star col = $00 -> no effect)
    rts
:   jmp hurt_mario
@gone:
    stz o_type,x
    rts
.endproc

.proc draw_wball                 ; one 8x8: the common fireball tile
    ldx oi
    lda o_y,x
    clc
    adc #8                       ; o_y is the 16px-box top; the 8px ball sits +8
    sta dy                       ; (matches the engine's erase at o_ndy=o_y+8 --
    lda spr_col                  ;  without this the ball is drawn in the top half
    sta dcol                     ;  and the bottom-half erase never clears it -> trail)
    ldx #FIRE_T
    jmp draw_quad
.endproc

; GB-EXACT ball-vs-Mario box (2026-08-17 PyBoy sweep + $0aaf RE, docs/12):
; Mario's contact band is tiny -- X: a ~6px strip ([c202-3..c202+2]), Y:
; [c201-2..c201+6] -- vs the ball's own 8x8 tile. Translated to port coords:
; X: |mario_dx| < 7 (centre distance); Y: o_y - spr_y in [-10..+6].
.proc wball_box                  ; C=1 -> touching
    jsr mario_dx
    lda tmpH3
    bne @no
    lda tmpL3
    cmp #7
    bcs @no
    lda o_y,x
    sec
    sbc spr_y
    clc
    adc #10
    cmp #17
    bcs @no
    sec
    rts
@no:
    clc
    rts
.endproc


; (pair16/quad16 live in the engine's RCODE now -- shared, RAM-resident)

.proc draw_honen                 ; 8x16 fishbone, flap frame
    ldx oi
    jsr foe_frame
    asl
    clc
    adc #HON_TA+1
    sta tmpL2                    ; bottom
    dea
    jmp pair16
.endproc

.proc draw_leap                  ; 16x16 seahorse: flap frame + TRUE mirror when
    ldx oi                       ; facing right (GB OAM: columns swapped AND each
    jsr foe_frame                ; tile x-flipped; tiles face left natively)
    asl
    asl
    clc
    adc #LEAP_TA
    sta tmpH3                    ; this flap frame's TL tile
    lda o_hp,x                   ; facing: +1 = Mario is right -> mirror
    and #$80
    eor #$80                     ; $80 -> 0 (left, native); 0 -> $80 (flip)
    sta tmpL3
    ldy #0
@q: phy
    ldx oi
    lda o_y,x
    clc
    adc lq_dy,y
    sta dy
    lda spr_col
    clc
    adc lq_dc,y
    sta dcol
    lda tmpL3
    sta do_flip
    beq @nf
    lda lq_tf,y                  ; mirrored: swapped columns
    bra @tl
@nf:
    lda lq_tn,y
@tl:
    clc
    adc tmpH3
    tax
    jsr draw_quad
    ply
    iny
    cpy #4
    bne @q
    stz do_flip
    rts
lq_dy: .byte 0,0,8,8
lq_dc: .byte 0,2,0,2
lq_tn: .byte 0,1,2,3
lq_tf: .byte 1,0,3,2
.endproc

w2_nop: rts                      ; dead dispatch rows (corpse types unused)


.proc w2_token                   ; anim tokens (mirrors the draw choices)
    lda o_type,x
    cmp #OBJ_SUU
    bne :+
    jmp suu_frame
:   cmp #OBJ_HONEN
    beq @flap
    cmp #OBJ_LEAP
    beq @flap
    lda #0                       ; gift/rock/corpses: position-only redraws
    rts
@flap:
    jsr foe_frame                ; flap bit + facing bit: a flip during the
    ldy o_hp,x                   ; static rest phase must still dirty the redraw
    bmi :+
    ora #2
:   rts
.endproc

.proc w2_width                   ; erase widths (W2 roster only)
    cpy #OBJ_SUU
    beq @w82
    cpy #OBJ_HONEN
    beq @w82
    cpy #OBJ_HCORP
    beq @w82
    cpy #OBJ_GIFT
    bne :+
    lda #2
    rts
:   cpy #OBJ_ROCK
    bne :+
    lda #3                       ; rock: 16 wide
    rts
:   cpy #OBJ_WBALL
    bne @w83
    lda #2                       ; the ball: one tile
    rts
@w83:
    lda #$83                     ; leaper/lcorp: 16 wide + tall
    rts
@w82:
    lda #$82                     ; suu/honen/hcorp: 8 wide, 16 tall
    rts
.endproc

; --- the shared kit bodies (source-identical with the 1-3 kit) ---
.include "kit_sh1.inc"           ; l3_cull, l3_box, upd_suu, upd_rock
.include "kit_sh2.inc"           ; l3_hurt
.include "kit_sh3.inc"           ; l3_xoff
; (kit_sh4 rising-lift: DEAD in W2 -- $F0 materializes, no object spawns)
.include "kit_sh5.inc"           ; suu_frame, draw_suu, draw_rock, l3_pair, l3_one
; (kit_sh6 draw_gift: dead too)
; (kit_sh7 l3_width/l3_token replaced by the W2-native w2_width/w2_token)
