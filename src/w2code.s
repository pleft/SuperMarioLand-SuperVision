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
OBJ_GIFT   = 22
OBJ_SUU    = 23
OBJ_ROCK   = 24
OBJ_GAO    = 25                  ; referenced by shared width/token chains only
OBJ_FIRE   = 26
OBJ_BAT    = 27
OBJ_BULL   = 28
OBJ_GSQ    = 29
OBJ_GCORP  = 30
SUU_TA  = $92
ROCK_TL = $DD
GAO_TL  = $A4
GAO_SQA = $B9
FIRE_T  = $E2
GIFT_T  = $E6

.segment "W2C"

init:                            ; $1500: bind our vector table
    ldx #11
:   lda vec_tab,x
    sta ovl_vec,x
    dex
    bpl :-
    rts

vec_tab:
    .addr w2_spawn, w2_update, l3_token, w2_gift, w2_draw, l3_width

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
    bne @consume
    lda #OBJ_ROCK
@go:
    jsr obj_alloc_typed
    bcs @full                    ; pool full: C=1 -> the spawner retries
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
    asl
    tay
    lda w2_updtab+1,y
    pha
    lda w2_updtab,y
    pha
    rts
.endproc
w2_updtab:
    .word upd_gift-1, upd_suu-1, upd_rock-1

.proc w2_draw                    ; A = o_type (engine convention), X = slot
    sec
    sbc #OBJ_GIFT
    asl
    tay
    lda w2_drwtab+1,y
    pha
    lda w2_drwtab,y
    pha
    rts
.endproc
w2_drwtab:
    .word draw_gift-1, draw_suu-1, draw_rock-1

; --- the shared kit bodies (source-identical with the 1-3 kit) ---
.include "kit_sh1.inc"           ; l3_cull, l3_box, upd_suu, upd_rock
.include "kit_sh2.inc"           ; l3_hurt
.include "kit_sh3.inc"           ; l3_xoff
.include "kit_sh4.inc"           ; upd_gift, l3_gift (the RISING LIFT)
.include "kit_sh5.inc"           ; suu_frame, draw_suu, draw_rock, l3_pair, l3_one
.include "kit_sh6.inc"           ; draw_gift
.include "kit_sh7.inc"           ; l3_width, l3_token
