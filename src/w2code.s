; ---------------------------------------------------------------------------
; W2CODE -- the WORLD 2 kit overlay. Assembled STANDALONE after the main link
; (engine addresses come from build/w2abi.inc), linked to run in the $1500
; window, shipped as a blob inside each W2 bank's level region (header +20/21
; points at it; ovl_bind copies it in and jumps $1500 = `init` below).
;
; This iteration: the safe scaffold -- init binds the vectors; every handler
; is a no-op that keeps the engine's contracts (spawn consumes with C=0).
; Next: suu/rock via shared kit includes, the $F0 rising lift, Honen, the
; Yurarin leaper.
; ---------------------------------------------------------------------------
.include "w2abi.inc"

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

.proc w2_spawn                   ; A = GB type, Y = spawn entry byte offset
    clc                          ; nothing ported yet: CONSUME every entry
    rts                          ; (a set carry would jam the spawner)
.endproc

.proc w2_update                  ; X = slot, types >= OBJ_GIFT (none exist yet)
    rts
.endproc

.proc w2_token                   ; anim token for kit types
    lda #0
    rts
.endproc

.proc w2_gift                    ; the $F0 rising lift -- next iteration
    rts
.endproc

.proc w2_draw                    ; render pass for kit types (none yet)
    rts
.endproc

.proc w2_width                   ; erase width for kit types
    lda #2
    rts
.endproc
