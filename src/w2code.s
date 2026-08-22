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
SFX_IDS_ONLY = 1                 ; ids only -- the engine owns the tables
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
.ifdef EAS3
OBJ_W3     = 36                  ; W3: every AI-VM enemy shares one port id
.endif                           ; (its GB type index lives in w3_ti, docs/34)
OBJ_MEK    = 36                  ; $16 MEKABON (2-2; user-ID'd): walks, THROWS ITS HEAD
OBJ_MHEAD    = 37                  ; $17: the thrown head (out-and-back loop)
OBJ_MSQ    = 38                  ; $1C: the stomped squash (harmless, ~93f)
OBJ_MCORP  = 39                  ; $19/$0D: the dead-flip fall
SUU_TA  = $92
ROCK_TL = $DD
GAO_TL  = $A4
GAO_SQA = $B9
FIRE_T  = $E2
GIFT_T  = $E6
; PORT tile ids (the packer's compact slice; GB sources in pack_banks.py):
LEAP_TA = $A4                    ; 16x16 quad: TL,TR,BL,BR; frame B = +4
HON_TA  = $AC                    ; 8x16: top,bottom; frame B = +2
.ifdef YUR22                     ; 2-2's extra slice (pack_banks level 4)
MEK_TA  = $B0                    ; swim quad A $B0-$B3 (GB C4,C5,D4,D5), B +4
MHEAD_T   = $B4                    ; child 16x8 = the frame-B top row (GB C6,C7)
MSQ_T   = $B8                    ; squash/corpse 16x8 (GB D8,D9)
.endif

.segment "W2C"

init:                            ; $1500: bind our vector table
    ldx #11
:   lda vec_tab,x
    sta ovl_vec,x
    dex
    bpl :-
.ifdef MAR23
    jmp veh_init                 ; 2-3: install the vehicle player (veh_vec)
.elseif .defined(EAS3)
    lda #<w3_read                ; W3: the window serves read_map_tile -- the
    sta mapread_vec              ; map data lives in BANK 6 and only this RAM
    lda #>w3_read                ; code can juggle the mapping (docs/33)
    sta mapread_vec+1
    stz W3CMB                    ; a fresh level starts with an empty column cache
    jmp w3_cinval
.else
    rts
.endif

vec_tab:
    .addr w2_spawn, w2_update, w2_token, w2_gift, w2_draw, w2_width

.ifdef EAS3
.include "kit_w3.inc"

; --- read_map_tile, served from the window (W3): identical semantics to the
; FIXED reader, but the pool/pointer read happens with BANK 6 mapped. The
; mod/multi-coin transforms and the past-edge template run after the bank is
; restored (they touch prefix-resident state). Mirrors main.s byte-for-byte
; in behavior; any change THERE must land HERE too. ---
W3SYS   = $2026
W3FLAGS = $0B                    ; NMI | TIMER_IRQ | LCD
.proc w3_read
    jsr w3_goal                  ; 3-3's sphere gate (the kit's per-frame hook)
    lda mrow
    cmp #16
    bcs @off
    lda feet_col+1               ; past the level's right edge? open space
    cmp lvl_cols+1
    bcc :+
    bne @off
    lda feet_col
    cmp lvl_cols
    bcs @off
:   lda map_base+1               ; a room swap reuses low column numbers, so the
    cmp W3CMB                    ; cache must be dropped when the map changes
    beq :+
    sta W3CMB
    jsr w3_cinval
:   lda feet_col                 ; --- DIRECT-MAPPED probe: slot = col & 15 ---
    and #W3CSLOTS-1              ; (round-robin kept evicting the column we were
    asl                          ; about to re-read -- docs/36)
    tax                          ; X = slot*2 = the tag pair
    lda W3CTAG,x
    cmp feet_col
    bne @miss
    lda W3CTAG+1,x
    cmp feet_col+1
    bne @miss
    jsr @slotptr
@read:
    ldy mrow
    lda (tmpL2),y
    jmp map_transform            ; the mod/multi-coin rules live in FIXED
@off:
    jmp map_offmap
@slotptr:                        ; X = slot*2 -> tmpL2 = the slot's 16 tile bytes.
    txa                          ; The data page is ALIGNED, so this is a shift and
    asl                          ; a constant -- no 16-bit add at all.
    asl
    asl
    sta tmpL2
    lda #>W3CDATA
    sta tmpH2
    rts
@miss:                           ; claim this column's own slot (no victim counter)
    lda feet_col
    sta W3CTAG,x
    lda feet_col+1
    sta W3CTAG+1,x
    jsr @slotptr
    lda feet_col                 ; map_ptr = map_base + col*2 (the pointer table)
    asl
    sta map_ptr
    lda feet_col+1
    rol
    sta map_ptr+1
    lda map_ptr
    clc
    adc map_base
    sta map_ptr
    lda map_ptr+1
    adc map_base+1
    sta map_ptr+1
    stz W3LINKV      ; ONE bank switch per COLUMN, not per read:
    lda #6                    ; every SYS_CTRL write restarts the LCD scan
    sta W3LINK
    lda #$0F
    sta W3LINKV
    lda (map_ptr)
    tax
    ldy #1
    lda (map_ptr),y
    sta map_ptr+1
    stx map_ptr
    ldy #15
:   lda (map_ptr),y
    sta (tmpL2),y
    dey
    bpl :-
    stz W3LINKV
    lda #1
    sta W3LINK
    lda #$0F
    sta W3LINKV
    bra @read
.endproc

.segment "W2FAR"                 ; (neither runs with bank 6 mapped)
; The pipeline stores o_pvx/o_pvy BEFORE asking us for the width, so this is
; where a metasprite reaching outside the default box gets its erase rectangle
; corrected -- otherwise it smears the background as it moves.
.proc w3_width                   ; X = slot -> A = the engine's width byte
    lda o_st,x                   ; the metasprite param drawn last
    ldy #W3_NEXC-1
:   cmp w3_excp,y
    beq @big
    dey
    bpl :-
    jsr @left8                   ; default box: 8px left, 24px tall, 40px wide
    lda #$C5
    rts
@big:
    lda o_pvy,x                  ; a taller metasprite: lift the erase origin
    sec
    sbc w3_excy,y
    bcs :+
    lda #0
:   sta o_pvy,x
    phy
    jsr @left8
    ply
    lda w3_excw,y
    rts
@left8:
    lda o_pvx,x                  ; every W3 metasprite reaches 8px left of the
    sec                          ; anchor (Batadon's [wing|head|wing] band)
    sbc #8
    bcs :+
    lda #0
:   sta o_pvx,x
    rts
.endproc

.proc w3_cinval                  ; drop every cached column
    ldx #(W3CSLOTS*2)-1          ; poison every slot's col-HI (odd bytes of the
    lda #$FF                     ; tag pairs); $FF never matches a real column
:   sta W3CTAG,x
    dex
    dex
    bpl :-
    rts
.endproc
.segment "W2C"
.endif

.proc w2_gift                    ; content $F0 (GB $18C0, READ this time): the
    jmp mark_used                ; hidden cell MATERIALIZES as a solid block (GB
.endproc                         ; stamps $80; our mod renders $5F as used-solid).
                                 ; No object, no lift -- a stepping block. Its
                                 ; re-bonk = the content-0 "nothing" case.

.proc w2_spawn                   ; A = GB type, Y = spawn entry byte offset
.ifdef YUR22
    cmp #$16
    bne @not16
    lda #OBJ_MEK
    jsr @go
    bcs @full
    jsr aim_leap                 ; face Mario (script F0 $40 at cycle start)
    lda #3
    sta o_vy,x                   ; walk step divider (1px/3f, capture)
    bra @consume
@not16:
.endif
.ifndef MAR23
    cmp #$02
    bne :+
    lda #OBJ_SUU
    bra @go
.endif
.ifndef YUR22                    ; 2-2 spawns no rock/honen (types nop'd there)
.ifndef MAR23
:   cmp #$0C
    bne :+
    lda #OBJ_ROCK
    bra @go
.endif
.ifndef EAS3
:   cmp #$10
    bne :+
    lda #OBJ_HONEN
    bra @go
.endif
.endif
:
.ifndef EAS3
    cmp #$24
.ifdef MAR23
    bne @mar23                   ; the 2-3 types dispatch in kit_mar23.inc
.else
    bne @consume
.endif
    lda #OBJ_LEAP
    jsr @go                      ; common body, then the pre-hop aim (F0 $60:
    bcs @full                    ; the script faces Mario before the first rise)
    jsr aim_leap
    clc                          ; consumed (aim's cmp may leave C set)
    rts
.endif
@go = w2_go
@consume:
.ifdef EAS3
    jmp w3_spawn                 ; W3: the AI-VM owns every remaining type
.endif
    clc                          ; unknown W2 types consume
@full:
    rts
.ifdef MAR23
@mar23:
    jmp mar_spawn
.endif
.endproc

.proc w2_go                      ; the shared allocate+seed (A=type, Y=entry)
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
    clc
@full:
    rts
.endproc

.proc w2_update                  ; X = slot; kit types 22+
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
.ifdef MAR23
    .word sub_step-1, w2_nop-1, w2_nop-1
    .word upd_honen-1, upd_leap-1, w2_nop-1, w2_nop-1, upd_wball-1
    .word sub_step-1, upd_torp-1, upd_torion-1, upd_gunion-1
    .word upd_ghalf-1, upd_yura2-1, upd_yfire-1, upd_tamao-1
    .word upd_dragon-1, upd_dshot-1, upd_drgb-1
.elseif .defined(YUR22)
    .word w2_rts-1, upd_suu-1, w2_nop-1
    .word w2_nop-1, upd_leap-1, w2_nop-1, w2_nop-1, upd_wball-1
    .word upd_mek-1, upd_mhead-1, upd_msq-1, upd_mcorp-1
.else
.ifdef EAS3
    .word w2_rts-1, upd_suu-1, upd_rock-1     ; W3 spawns no honen/leaper:
    .word w2_nop-1, w2_nop-1, w2_nop-1, w2_nop-1, w2_nop-1
    .word w3_step-1              ; OBJ_W3: the AI-VM
.else
    .word w2_rts-1, upd_suu-1, upd_rock-1
    .word upd_honen-1, upd_leap-1, w2_nop-1, w2_nop-1, upd_wball-1
.endif
.endif

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
.ifdef MAR23
    .word w2_rts-1, w2_nop-1, w2_nop-1
    .word draw_honen-1, draw_leap-1, w2_nop-1, w2_nop-1, draw_wball-1
    .word draw_subv-1, draw_torp-1, draw_leap-1, draw_gunion-1
    .word draw_ghalf-1, draw_yura2-1, draw_yura2-1, draw_tamao-1
    .word draw_dragon-1, draw_dshot-1, draw_drgb-1
.elseif .defined(YUR22)
    .word w2_rts-1, draw_suu-1, w2_nop-1
    .word w2_nop-1, draw_leap-1, w2_nop-1, w2_nop-1, draw_wball-1
    .word draw_mek-1, draw_mhead-1, draw_msq-1, draw_mcorp-1
.else
.ifdef EAS3
    .word w2_rts-1, draw_suu-1, draw_rock-1
    .word w2_nop-1, w2_nop-1, w2_nop-1, w2_nop-1, w2_nop-1
    .word w3_draw-1              ; OBJ_W3
.else
    .word w2_rts-1, draw_suu-1, draw_rock-1
    .word draw_honen-1, draw_leap-1, w2_nop-1, w2_nop-1, draw_wball-1
.endif
.endif

w2_rts:
    rts

; ---------------------------------------------------------------------------
; The MUDA LEAP (script $36D1/$37EB under the decoded AI-VM, docs/12): a
; symmetric ~111px arc from the spawn line. UP: 52f at 2px + 7f at 1px + 3f
; hang; DOWN mirrored, clamped at the base line (o_vy); then ~36f rest.
; arc_step: X = slot. tmpH3 = this frame's |dy| (the leaper moves x by it).
; On a phase transition tmpL2 = the NEW phase; else tmpL2 = $FF.
.ifndef EAS3                     ; W3 spawns neither $10 nor $24
.proc arc_step
    lda #$FF
    sta tmpL2
    stz tmpH3
    lda o_st,x
    bne @notup
    lda o_tmr,x                  ; UP
    cmp #52                      ; NOTE: 2-3's honen DOES bob, like 2-1/2-2's --
    bcs :+                       ; rise, fall, REST on its base line, repeat. A
    lda #2                       ; 130-frame capture showed only the first leap
    bra @up                      ; and led to a "single leap, no bob" rewrite that
:   cmp #59                      ; was wrong and user-visible. Over 300+ frames the
    bcs :+                       ; GB reads 166 -> 54 -> 168 -> 168,168,168 (the
    lda #1                       ; rest) -> 148 -> 55 -> ... Measure a full CYCLE
    bra @up                      ; before concluding what a periodic enemy does.
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
.endif

.proc foe_frame                  ; X = slot -> A = 0/1 (the ~15f wing flap)
    lda o_tmr,x
    lsr
    lsr
    lsr
    lsr
    and #1
    rts
.endproc

.ifndef EAS3                     ; W3 spawns neither $10 nor $24
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
.endif

; foe contact: star -> corpse+points at the victim; stomp side -> corpse +
; Mario's fixed bounce + combo-chained points; side -> hurt. A = value code.
.proc w2_foe
    jsr l3_box
    bcs :+
    rts
:   ldx oi
    lda mario_starT
    bne @kill
.ifdef MAR23                     ; VEHICLE LEVEL (law B1): nothing is stompable,
    jsr sub_off                  ; contact always hurts whatever the vertical
    jmp hurt_mario               ; relation, and the hull dies with the hit
.else
    jsr l3_above
    bcc @stomp
    jmp hurt_mario
.endif
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

.ifndef YUR22                    ; 2-2 has no Honen -- reclaim the bytes
.ifndef EAS3                     ; W3 spawns neither $10 nor $24
.proc upd_honen
    jsr l3_cull
    bcc :+
    rts
:   txa                          ; 30Hz motion, SLOT-STAGGERED (the bee-proven
    eor frame_count              ; pattern): two arc steps every other frame =
    lsr                          ; same trajectory, half the redraws, neighbours
    bcs @foe                     ; on opposite parities -- the 2-1 sky cluster's
    jsr arc_step                 ; 100-118% frames were honen-bob blit volume
    jsr arc_step                 ; (profiled)
@foe:
    lda #$01                     ; class 0 = 100
    jmp w2_foe
.endproc
.endif
.endif

.ifndef EAS3                     ; W3 spawns neither $10 nor $24
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
.endif

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
.ifndef EAS3                     ; W3 spawns neither $10 nor $24
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
.endif

.ifndef EAS3                     ; W3 spawns neither $10 nor $24
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
.endif

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

.ifndef YUR22
.ifndef EAS3                     ; W3 spawns neither $10 nor $24
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
.endif
.endif

.ifdef MAR23
.segment "W2FAR"
.endif
.ifndef EAS3                     ; W3 spawns neither $10 nor $24
.ifdef MAR23
.proc w2_width23                 ; every 2-3 body: 16 wide, 16 tall
    lda #$83
    rts
.endproc

                        ; on the GB's own box (which IS the object).
.endif
.proc draw_leap
    lda #LEAP_TA
    ; falls through
.endproc
.endif
.proc draw_16q                   ; A = frame-A TL tile: 16x16 flap quad + TRUE
    sta tmpH3                    ; mirror when facing right (GB OAM: columns
    ldx oi                       ; swapped AND each tile x-flipped; tiles face
    jsr foe_frame                ; left natively)
    asl
    asl
    clc
    adc tmpH3
    ; falls through with A = this flap frame's TL tile
.endproc
.proc draw_16q_f                 ; A = the FINAL TL tile. Same quad, but NO flap:
    sta tmpH3                    ; for sprites whose animation is not foe_frame's
    ldx oi                       ; 16-frame wing beat (tamao's is a GB-measured 30)
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
.ifdef MAR23
.segment "W2C"
.endif


w2_nop: rts                      ; dead dispatch rows (corpse types unused)


.ifdef MAR23
.segment "W2FAR"
.endif
.proc w2_token                   ; anim tokens (mirrors the draw choices)
    lda o_type,x
.ifndef MAR23
    cmp #OBJ_SUU
    bne :+
    jmp suu_frame
:
.endif
    cmp #OBJ_HONEN
    beq @flap
    cmp #OBJ_LEAP
    beq @flap
.ifdef YUR22
    cmp #OBJ_MEK
    bne @notmek
    jsr foe_frame
    ldy o_st,x                   ; the headless phase must dirty the redraw
    beq @mekf
    ora #4
@mekf:
    rts
@notmek:
.endif
.ifdef MAR23
    cmp #OBJ_TORION
    beq @flap2
    cmp #OBJ_GHALF
    beq @flap2
    cmp #OBJ_DSHOT
    beq @flap2
    cmp #OBJ_YURA2
    beq @flap2
    cmp #OBJ_YFIRE
    bne @none
@flap2:
    jmp foe_frame                ; anim bit dirties the redraw
@none:
.endif
    lda #0                       ; gift/rock/corpses: position-only redraws
    rts
@flap:
    jsr foe_frame                ; flap bit + facing bit: a flip during the
    ldy o_hp,x                   ; static rest phase must still dirty the redraw
    bmi :+
    ora #2
:   rts
.endproc
.segment "W2C"


.proc w2_width                   ; erase widths (W2 roster only)
.ifdef MAR23
    cpy #OBJ_TORP
    bne :+
    lda #2                       ; the dart: one tile
    rts
:   cpy #OBJ_GHALF
    bne :+
    lda #2
    rts
:   cpy #OBJ_DSHOT
    bne :+
    ldy o_st,x                   ; the shot is 16px WIDE and 16 (rising) or 24
    beq @dsh16                   ; (flying) TALL -- a 2-col box left half of it
    lda #$C3                     ; on the floor. bit7+bit6 = 24px, 3 cols
    rts
@dsh16:
    lda #$83                     ; bit7 = 16px tall, 3 cols
    rts
:   cpy #OBJ_YURA2
    beq @wfish
    cpy #OBJ_YFIRE
    bne :+
@wfish:
    lda #3                       ; the school fish: 16 wide, 8 tall (short band)
    rts
:   cpy #OBJ_SUBV
    bcc @wbase23                 ; honen/leap/wball keep the shared rows
    jmp w2_width23               ; the 2-3 bodies (W2FAR: the window is full)
@wbase23:
.endif
.ifdef YUR22
    cpy #OBJ_MEK
    beq @w83
    cpy #OBJ_MHEAD
    bcc @wbase
    cpy #OBJ_MCORP+1
    bcs @wbase
    lda #3                       ; child/squash/corpse: 16 wide, 8 tall
    rts
@wbase:
.endif
.ifdef EAS3
    cpy #OBJ_W3
    bne :+
    jmp w3_width                 ; per-metasprite erase box (bank-resident)
:
.endif
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

.ifdef YUR22
; ---------------------------------------------------------------------------
; YURARIN $16 (2-2), fully GB-captured (docs/12): swims horizontally 1px/3f
; facing Mario for ~120f (flap C4..C7/D4..D7), then spawns the child $17
; 8px above and HOLDS ~120f ($18), then re-faces and swims again. Stomp ->
; $1C squash (harmless, ~93f static) -> the dead-flip fall ($19/$0D: the
; 23-delta hop arc, squash tiles Y-FLIPPED, drift away, ~2px/f fall).
; Ball/star kill -> the same corpse chain (unlike Boo/Honen, Yurarin IS
; superball-killable: $3186[$16]+3 = $19). Child: any contact pops it
; ($3186[$17] all $FF): touch hurts, stomp/ball/star despawn it.

.proc upd_mek
    jsr l3_cull
    bcc :+
    rts
:   lda o_st,x
    bne @hold
    lda o_tmr,x                  ; WALK 162f at 1px/3f (GB morph timestamps)
    inc o_tmr,x
    cmp #162
    bcs @fire
    dec o_vy,x
    bne @coll
    lda #3
    sta o_vy,x
    ; phys-$07 LEDGE TURN (user-confirmed on GB: walks to the platform edge
    ; and turns back): probe the map tile under the LEADING foot; open -> flip.
    lda o_hp,x
    bmi @pl
    lda #14                      ; leading edge, facing right
    bra @ps
@pl:
    lda #1                       ; facing left
@ps:
    clc
    adc o_xl,x
    sta tmpL2
    lda o_xh,x
    adc #0
    lsr
    ror tmpL2
    lsr
    ror tmpL2
    lsr
    ror tmpL2                    ; /8 -> world tile column
    sta feet_col+1
    lda tmpL2
    sta feet_col
    lda o_y,x                    ; standing on row o_y/8 (on-top rule)
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid
    ldx oi                       ; (read_map_tile clobbers X; ldx also clobbers
    lsr                          ;  the flags -- re-test A: solid=1 -> C)
    bcs @step
    lda o_hp,x                   ; ledge: turn around
    eor #$FF
    ina
    sta o_hp,x
    bra @coll
@step:
    lda o_hp,x
    jsr x_step
    bra @coll
@fire:
    jsr mek_fire                 ; throw the head, then hold ($18)
    inc o_st,x
    stz o_tmr,x
    bra @coll
@hold:
    lda o_tmr,x
    inc o_tmr,x
    cmp #121
    bcc @coll
    stz o_st,x
    stz o_tmr,x
    jsr aim_leap                 ; re-face for the new swim (F0 $40)
@coll:
    lda o_st,x                   ; headless phase: the $18 all-$FF row
    beq :+
    jmp mek_popc
:   jmp mek_contact
.endproc

mek_award:                       ; +100 tag at the victim, slot X
    ldx oi
    jsr victim_xy
    lda o_y,x
    sta tmpH3
    lda #$01
    jmp award_kill_at

.proc mek_fire                   ; child $17: 16x8, 8px above the mouth
    lda #OBJ_MHEAD
    jsr obj_alloc_typed
    bcs @full
    stz o_pdr,x
    ldy oi
    lda o_xl,y
    sta o_xl,x
    lda o_xh,y
    sta o_xh,x
    lda o_y,y
    sec
    sbc #8
    sta o_y,x
    jsr aim_leap                 ; the throw aims AT MARIO (user-confirmed GB),
    stz o_tmr,x                  ; not along the walk facing
    stz o_st,x                   ; segment index
@full:
    ldx oi
    rts
.endproc

.proc upd_mhead                  ; the thrown head: the GB's OCTAGON, per-frame
    ldy o_st,x                   ; capture verbatim (user: "more orthogonal"):
    cpy #7                       ; rise23, up-out15, out15, down-out15, down8,
    bcs @merge                   ; down-back15, pure-back30 -- 121f, lands on
    lda mh_dy,y                  ; the neck as the body regrows
    clc
    adc o_y,x
    sta o_y,x
    lda mh_dx,y
    beq @nod
    ldy o_hp,x                   ; dx rides the throw direction
    bpl @go
    eor #$FF
    ina
@go:
    ora #0                       ; x_step branches on A's SIGN FLAG -- the ldy
    jsr x_step                   ; above clobbered it (right-throw returns bug)
@nod:
    inc o_tmr,x
    ldy o_st,x
    lda mh_len,y
    cmp o_tmr,x
    bne @cc
    stz o_tmr,x
    inc o_st,x
@cc:
    jmp mek_popc
@merge:
    stz o_type,x
    rts
mh_len: .byte 23,15,15,15,8,15,30
mh_dy:  .byte $FF,$FF,0,1,1,1,0
mh_dx:  .byte 0,1,1,1,0,$FF,$FF
.endproc

.proc mek_popc                   ; the all-$FF contact row: touch hurts;
    jsr mek_ballhit              ; stomp/star/ball pop it silently (+100)
    bcc :+
    lda #0
    sta o_type,y                 ; the ball expires against it
    bra @pop
:   jsr wball_box                ; the GB-exact tiny band (the head is 8px tall
                                 ; like the ball; l3_box's +/-14 Y let the head
                                 ; hit Mario where the GB flies past, user-caught)
    bcs :+
    rts
:   ldx oi
    lda mario_starT
    bne @pop
    jsr l3_above
    bcc @stomp
    jmp hurt_mario
@stomp:
    jsr mek_bounce
@pop:
    jsr mek_award
    ldx oi
    stz o_type,x
    rts
.endproc

.proc mek_bounce                 ; the fixed stomp bounce (RE $08C7)
    lda #1
    sta jump_state
    lda #14
    sta arc_idx
    stz fall_v
    stz ride
    rts
.endproc

.proc mek_contact                ; the walk phase's row: 1c/19/ff/19/19
    jsr mek_ballhit
    bcc :+
    lda #0
    sta o_type,y                 ; the ball expires against it
    bra @kill                    ; ball col +3 = $19: the corpse chain
:   jsr l3_box
    bcs :+
    rts
:   ldx oi
    lda mario_starT
    bne @kill                    ; star -> the corpse chain (col +4 = $19)
    jsr l3_above
    bcc @stomp
    jmp hurt_mario
@stomp:
    lda #OBJ_MSQ                 ; -> $1C: harmless squash, ~93f static
    sta o_type,x
    stz o_tmr,x
    jsr mek_bounce
    lda #$01
    jmp award_stomp
@kill:
    jsr mek_corpse
    jmp mek_award
.endproc

.proc mek_corpse                 ; -> the dead-flip fall, thrown away from Mario
    lda #OBJ_MCORP
    sta o_type,x
    stz o_st,x
    lda o_hp,x                   ; o_hp faces Mario -> drift the OTHER way
    eor #$FF
    ina
    sta o_vx,x
    rts
.endproc

.proc upd_msq                    ; $1C: static, harmless, ~93f -> the fall
    lda o_tmr,x
    inc o_tmr,x
    cmp #93
    bcc :+
    jsr mek_corpse
:   rts
.endproc

.proc upd_mcorp                  ; the captured hop arc, then 2px/f off-screen
    lda o_st,x
    cmp #23
    bcs @fall
    tay
    lda mc_dy,y
    clc
    adc o_y,x
    sta o_y,x
    inc o_st,x
    lda o_vx,x                   ; away-drift rides the 23f arc: +23px total,
    jsr x_step                   ; exactly the capture (X 159->182)
    bra @clip
@fall:
    lda o_y,x
    ina
    ina
    sta o_y,x
@clip:
    lda o_y,x
    cmp #160
    bcc :+
    stz o_type,x                 ; off the bottom -> gone
:   rts
.endproc
mc_dy:                           ; kill_flip's captured trajectory, verbatim
    .byte $FF,$FF,$FF,$FF,$FF,$00,$FF,$00,$FF,$00,$00,$00,$00
    .byte $01,$00,$01,$00,$01,$01,$01,$01,$01,$01

.proc mek_ballhit                ; C=1: the superball overlaps slot oi (Y=ball)
    ldy #9
@s: lda o_type,y
    cmp #4                       ; engine OBJ_BALL
    beq @got
    dey
    bpl @s
    clc
    rts
@got:
    lda o_xl,y
    sec
    sbc o_xl,x
    sta tmpL2
    lda o_xh,y
    sbc o_xh,x
    beq @pos
    cmp #$FF
    bne @no
    lda tmpL2
    cmp #$F8                     ; -8..-1
    bcc @no
    bra @dy
@pos:
    lda tmpL2
    cmp #10
    bcs @no
@dy:
    lda o_y,y
    sec
    sbc o_y,x
    clc
    adc #12
    cmp #25
    bcs @no
    sec
    rts
@no:
    clc
    rts
.endproc

.proc draw_mek                   ; walking: the full quad; headless: D6/D7 pair
    ldx oi
    lda o_st,x
    beq @full
    lda #MHEAD_T+2               ; $B6 = the frame-B bottom row (capture)
    jmp mek_pair
@full:
    lda #MEK_TA
    jmp draw_16q
.endproc

.proc mek_pair                   ; A = left tile; a 16x8 pair at o_y+8
    sta tmpH3
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    ldx tmpH3
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
    inx
    jmp draw_quad
.endproc

draw_mhead:
    lda #MHEAD_T
    jmp mek_pair
draw_msq:
    lda #MSQ_T
    jmp mek_pair

.proc draw_mcorp                 ; the squash pair Y-FLIPPED (GB attr $40; no
    stz do_flip                  ; column swap -- capture f=95)
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    ldx #MSQ_T
    jsr draw_tile_yflip
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    ldx #MSQ_T+1
    jmp draw_tile_yflip
.endproc
.endif

; --- the shared kit bodies (source-identical with the 1-3 kit) ---
.ifdef MAR23
.include "kit_mar23.inc"         ; the 2-3 Marine Pop kit (vehicle + foes)
.endif
.include "kit_sh1.inc"           ; l3_cull, l3_box, upd_suu, upd_rock
.include "kit_sh2.inc"           ; l3_hurt
.include "kit_sh3.inc"           ; l3_xoff
; (kit_sh4 rising-lift: DEAD in W2 -- $F0 materializes, no object spawns)
.include "kit_sh5.inc"           ; suu_frame, draw_suu, draw_rock, l3_pair, l3_one
; (kit_sh6 draw_gift: dead too)
; (kit_sh7 l3_width/l3_token replaced by the W2-native w2_width/w2_token)
