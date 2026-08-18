; ---------------------------------------------------------------------------
; KIT_MAR23 -- the 2-3 MARINE POP kit (blob build -D MAR23; pack_banks level 5).
; Everything here is GB-measured (2026-08-18 PyBoy captures + bank0/1/3 RE):
;   State_0D vehicle: dpad 1px/f (left 2px/f while the autoscroll runs), screen
;   clamps x[8,152] y[32,132] (port coords = GB c202-8 / c201-16), autoscroll
;   0.5px/f to cam 2720, wall-scroll crush pushes the sub left (death at the
;   edge), tile $E1 (and $83) = THE SPHERE -> level clear (GB 1b45: clear
;   jingle track $01 + state $07 -- NOT a death), $F4 coins collect by probe,
;   torpedoes: 3 slots, +2px/f from (y-2,x+2), A/B press fires, held A
;   autofires /12f, bricks $82 break (+50 + debris), $80 awards content,
;   enemies take $3186 col+4 with the slot HP byte (clinks under $2aad).
; ---------------------------------------------------------------------------

; --- vehicle-only object ids (36+ = the 2-2 mek range, free here) ---
OBJ_SUBV   = 36                  ; the Marine Pop sprite (glued to Mario)
OBJ_TORP   = 37                  ; torpedo (3 max, fire-managed)
OBJ_TORION = 38                  ; $1D: swims left 2px/3f, y-aimed once (400)
OBJ_GUNION = 39                  ; $20: bobbing octopus; 3 torps -> SPLITS (800)
OBJ_GHALF  = 40                  ; $22: a split half, flies level 1px/f
OBJ_YURA2  = 41                  ; $2F: seahorse pacing the scroll, spits $30s
OBJ_YFIRE  = 42                  ; $30: the school seahorse, straight left 1px/f
OBJ_TAMAO  = 43                  ; $48: invincible diagonal bouncer (torp sponge)
OBJ_DRAGON = 44                  ; $1A: DRAGONZAMASU -- 20 torpedoes (19 clinks),
OBJ_DSHOT  = 45
OBJ_DRGB   = 46                  ; the dragon's lower 16x16 (erase codes cap at
                                 ; 24px -- the boss is two glued slots)                  ;   5000; $1F/$58: his shot (rise, then left)

; --- tiles ---
SUB_T   = $70                    ; base sheet: sub quad $70-$73 (OAM-verified)
TORP_T  = $7A                    ; base sheet: the torpedo dart (8x8)
GUN_TA  = $B0                    ; slice: gunion quad (frame A; bank5 is
YUR2_T  = $B4                    ; fish pair A ($B4/$B5), B ($B6/$B7): the flap
TAM_T   = $B8                    ; is back; tamao = a PRE-MIRRORED 16q quad
DRG_TA  = $BC                    ; dragon 16x32, frame A
MUS_GOAL_ = 3                    ; build/audio/music.inc (blob can't include it)

; pad bits (GB layout; supervision.inc isn't included in the blob)
VGB_A     = $01
VGB_B     = $02
VGB_RIGHT = $10
VGB_LEFT  = $20
VGB_UP    = $40
VGB_DOWN  = $80

VAUTO_HI = >2720                 ; the autoscroll ceiling (map 2880 - 160)
VAUTO_LO = <2720

; --- blob-local state (the window is RAM) ---
vfire:  .byte 1                  ; hold-A autofire countdown (GB $c0ae, /12)
vthp:   .res 10                  ; per-slot torpedo HP (GB slot+$0C & $3F)

.segment "W2FAR"
; ---------------------------------------------------------------------------
; veh_init: called from the blob init (level bind). Installs the player
; handler and disarms the walk-era goal door (cam never == $FFFF).
.segment "W2C"
.proc veh_init
    lda #<veh_step
    sta veh_vec
    lda #>veh_step
    sta veh_vec+1
    lda #$FF
    sta cam_max
    sta cam_max+1
    lda #1
    sta vfire
    rts
.endproc
.segment "W2FAR"


.segment "W2C"
; ---------------------------------------------------------------------------
; veh_step: the whole GB State_0D player, called instead of walk+jump+fire.
.proc veh_step
    lda goal_phase               ; sphere touched: the clear sequence owns the
    beq :+                       ; frame (jingle -> tally -> next level)
    rts
:   jsr sub_ensure               ; the sub sprite object (survives respawns)
    ; --- autoscroll: +1px every other frame until cam 2720 ($4fb2) ---
    lda frame_count
    lsr
    bcs @move
    jsr at_max                   ; C=1: the scroll is done
    bcs @move
@scroll:
    inc cam_x
    bne :+
    inc cam_x+1
:   lda #8                       ; the crush probe: solid right of the sub ->
    jsr vprobe_h                 ; the wall wins, the sub is pushed left
    bcc @move
    dec spr_x
    lda spr_x
    cmp #9
    bcs @move
    stz mario_big                ; crushed against the screen edge: death even
    jmp hurt_mario               ; when big (GB $515e forces small + state 1)
@move:
    ; --- vertical (falls through into horizontal = GB diagonals) ---
    lda pad_held
    and #VGB_UP
    beq @try_dn
    jsr vprobe_up
    bcs @horiz
    lda spr_y
    cmp #33                      ; top clamp (GB c201 $30)
    bcc @horiz
    dec spr_y
    bra @horiz
@try_dn:
    lda pad_held
    and #VGB_DOWN
    beq @horiz
    jsr vprobe_dn
    bcs @horiz
    lda spr_y
    cmp #132                     ; bottom clamp (GB c201 $94)
    bcs @horiz
    inc spr_y
@horiz:
    lda pad_held
    and #VGB_RIGHT
    beq @try_l
    lda #8
    jsr vprobe_h
    bcs @fire
    lda spr_x
    cmp #152                     ; right clamp (GB c202 $A0)
    bcs @fire
    inc spr_x
    bra @fire
@try_l:
    lda pad_held
    and #VGB_LEFT
    beq @fire
    jsr @lstep                   ; 1px... and a second while the scroll runs
    jsr at_max                   ; (GB $4fff: dec twice below the ceiling)
    bcs @fire
    jsr @lstep
    bra @fire
@lstep:
    lda #<-6
    jsr vprobe_h
    bcs @lout
    lda spr_x
    cmp #9                       ; left clamp (GB c202 $10)
    bcc @lout
    dec spr_x
@lout:
    rts
@fire:
    ; --- torpedoes: press A/B = fire now; hold A = every 12f ($498b) ---
    lda pad_pressed
    and #VGB_A|VGB_B
    bne @dofire
    lda pad_held
    and #VGB_A
    beq @done
    dec vfire
    bne @done
@dofire:
    lda #12
    sta vfire
    jmp torp_fire
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
.proc at_max                     ; C=1 when the autoscroll has reached 2720
    lda cam_x+1
    cmp #VAUTO_HI
    bcc @no
    bne @yes
    lda cam_x
    cmp #VAUTO_LO
    bcs @yes
@no:
    clc
    rts
@yes:
    sec
    rts
.endproc

; probes ($50cc/$5046/$5089 in port coords). All classify through vh_class:
; C=1 blocked; coins collect in passing; E1/$83 = the sphere -> level clear.
.proc vprobe_h                   ; A = x offset (+8 right / -6 left)
    jsr veh_col                  ; feet_col = (cam + spr_x + A) >> 3
    lda spr_y
    clc
    adc #5
    jsr vrowset                  ; mrow = ((spr_y+5)>>3) - 2
    jsr vh_read
    bcs @out                     ; blocked (or clear/coin handled)
    lda mario_big                ; big sub: a second row at y-3 ($50cc e=2)
    beq @out
    lda spr_y
    sec
    sbc #3
    jsr vrowset
    jsr vh_read
@out:
    rts
.endproc

.proc vprobe_up                  ; two corners at y-3 (small) / y-4 (big)
    lda #2
    jsr veh_col
    jsr @row
    jsr vh_read
    bcs @out
    lda #<-4
    jsr veh_col
    jsr @row
    jsr vh_read
@out:
    rts
@row:
    lda spr_y
    sec
    sbc #3
    ldy mario_big
    beq :+
    dea
:   jmp vrowset
.endproc

.proc vprobe_dn                  ; two corners at y+10 ($5089)
    lda #<-2
    jsr veh_col
    jsr @row
    jsr vh_read
    bcs @out
    lda #2
    jsr veh_col
    jsr @row
    jsr vh_read
@out:
    rts
@row:
    lda spr_y
    clc
    adc #10
    jmp vrowset
.endproc

.proc veh_col                    ; A = signed dx from spr_x -> feet_col
    clc                          ; (spr_x+dx stays in 2..168: no 8-bit wrap;
    adc spr_x                    ;  the engine's calc_feet_col force-carries,
    clc                          ;  so negative offsets break it)
    adc cam_x
    sta feet_col
    lda cam_x+1
    adc #0
    sta feet_col+1
    ; falls through
.endproc
.proc col_shift                  ; feet_col (a raw x16) >>= 3
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    rts
.endproc

.proc vrowset                    ; A = a y coordinate -> mrow (level row)
    lsr
    lsr
    lsr
    sec
    sbc #2
    sta mrow
    rts
.endproc

.proc vh_read                    ; read + classify the (feet_col, mrow) cell
    jsr read_map_tile
    cmp #$60
    bcc @open
    cmp #$F4                     ; a coin: collect in passing, keep moving
    beq @coin
    cmp #$E1                     ; THE SPHERE (GB 1b45 = the level clear)
    beq @clear
    cmp #$83
    beq @clear
    sec                          ; any other >= $60: a wall
    rts
@coin:
    jsr mod_test                 ; not already collected?
    bne @open
    jsr mod_set
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one
    jsr award_coin
@open:
    clc
    rts
@clear:
    jsr veh_clear
    clc
    rts
.endproc

; ---------------------------------------------------------------------------
; the sub sprite: one slot glued to Mario, draw-only (contact stays Mario's).
.proc sub_ensure
    ldx #9
:   lda o_type,x
    cmp #OBJ_SUBV
    beq @glue
    dex
    bpl :-
    lda #OBJ_SUBV
    jsr obj_alloc_typed
    bcs @none                    ; pool full this frame: retry next
    stz o_pdr,x
    stz o_tmr,x                  ; frame A forever
    lda #$FF
    sta o_hp,x                   ; no mirror
@glue:
    lda spr_x                    ; world x = cam + spr_x - 7 (OAM capture:
    sec                          ; sub quad at c202-15 = spr_x-7)
    sbc #7
    clc
    adc cam_x
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda spr_y
    sec
    sbc #6                       ; top = c201-22 = spr_y-6
    sta o_y,x
@none:
    rts
.endproc

.segment "W2FAR"
.proc draw_subv                  ; the sub quad: small $70-$73 / BIG $75-$78
    stz do_flip                  ; (a mushroom re-skins the hull -- OAM-captured
    stz tmpL2                    ; after the c203-bit4 lesson)
    lda mario_big
    beq :+
    lda #5                       ; the big hull tile base offset
    sta tmpL2
:   lda frame_count              ; the BL quad is the propeller: +2 more tiles
    and #4                       ; on blade-B frames (holds for BOTH hull sets:
    beq :+                       ; $72/$74 small, $77/$79 big -- OAM-captured)
    lda #2
:   sta tmpH2
    ldy #0
@q: phy
    ldx oi
    lda o_y,x
    clc
    adc sq_dy,y
    sta dy
    lda spr_col
    clc
    adc sq_dc,y
    sta dcol
    lda sq_t,y
    clc
    adc tmpL2
    cpy #2
    bne :+
    clc
    adc tmpH2                    ; the blade swap (REPLACES the tile)
:   tax
    jsr draw_quad
    ply
    iny
    cpy #4
    bne @q
    rts
sq_dy: .byte 0,0,8,8
sq_dc: .byte 0,2,0,2
sq_t:  .byte SUB_T, SUB_T+1, SUB_T+2, SUB_T+3
.endproc

.segment "W2C"
; ---------------------------------------------------------------------------
; torpedoes ($5118 + $4a1a): 3 live max, +2px/f, die past the screen edge or
; on any solid (bricks break $2097-style, ?-blocks award), kill via col+4.
.proc torp_fire
    ldy #0                       ; count the live fish
    ldx #9
:   lda o_type,x
    cmp #OBJ_TORP
    bne :+
    iny
:   dex
    bpl :--
    cpy #3
    bcs @full
    lda #OBJ_TORP
    jsr obj_alloc_typed
    bcs @full
    stz o_pdr,x
    lda spr_x
    clc
    adc #2                       ; nose at (spr_x+2, spr_y-2) ($4a2c)
    adc cam_x
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda spr_y
    sec
    sbc #10                      ; o_y = visual-8 (the draw_one/erase law)
    sta o_y,x
    lda #SFX_DFE0_02             ; the launch pop (GB $dfe0=$02)
    jsr sfx_play
@full:
    rts
.endproc

.proc upd_torp
    inc o_xl,x                   ; +2px/f, straight right
    bne :+
    inc o_xh,x
:   inc o_xl,x
    bne :+
    inc o_xh,x
:   lda o_xl,x                   ; off the right edge (GB kills at OAM $A9)
    sec
    sbc cam_x
    sta tmpL3
    lda o_xh,x
    sbc cam_x+1
    bne @gone
    lda tmpL3
    cmp #160
    bcs @gone
    ; --- the nose tile ($1fd2): bricks break, blocks award, walls stop ---
    lda o_xl,x
    clc
    adc #2
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    jsr col_shift
    ldx oi
    lda o_y,x
    clc
    adc #14                      ; visual y (+8) + the GB's +6 nose row
    jsr vrowset
    jsr read_map_tile
    cmp #$60
    bcc @fly
    cmp #$F4                     ; coins pass (state-$0D skips the collect)
    beq @fly
    cmp #$82                     ; brick: shards + 50 ($2097)
    bne :+
    ldx oi
    jsr break_brick
    bra @gone
:   cmp #$80                     ; ?-block: the content pops AND the block
    bne @gone                    ; is DESTROYED (GB $2097; user-caught: only a
    jsr hit_qblock               ; Mario bonk leaves a used block) + 50
    jsr mod_set
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one
    lda #$50
    ldx #0
    jsr add_score
@gone:
    ldx oi
    stz o_type,x
    rts
@fly:
    ldx oi
    jmp torp_scan
.endproc

; torp_scan: the $200a sweep -- one box test per live foe, col+4 semantics
; via tclass (indexed type-OBJ_HONEN): 0 pass, 1 puff+100, 2 puff+400,
; 3 gunion split+800, 4 tamao absorb, 5 the boss (clinks handled by vthp).
.proc torp_scan
    ldy #9
@loop:
    lda o_type,y
    sec
    sbc #OBJ_HONEN
    cmp #16
    bcs @next
    phy
    tay
    lda tclass,y
    ply
    ora #0                       ; ply set N/Z from Y -- re-derive them from A
    beq @next                    ; (the mek x_step lesson, verse two)
    sta tmpL3                    ; the reaction class
    ; box: |dx| < 12; |dy| < 20 (the dragon's 32-tall box: < 36)
    lda o_xl,y
    sec
    sbc o_xl,x
    sta tmpH2
    lda o_xh,y
    sbc o_xh,x
    beq :+
    cmp #$FF
    bne @next
:   lda tmpH2
    clc
    adc #11
    cmp #23
    bcs @next
    lda o_y,x
    clc
    adc #8                       ; the torpedo's VISUAL y (o_y is top-8)
    sec
    sbc o_y,y
    clc
    adc #14                      ; foe box top-14 .. top+h
    ldx tmpL3
    cpx #5
    beq @tall
    cmp #34
    bcs @nxt2
    bra @hit
@tall:
    cmp #50
    bcs @nxt2
@hit:
    ldx oi
    jsr torp_hit
    ldx oi
    stz o_type,x                 ; the torpedo is consumed
    rts
@nxt2:
    ldx oi
@next:
    dey
    bpl @loop
    rts
.endproc
tclass:                          ; honen leap hcorp lcorp wball subv torp
    .byte 2, 2, 0, 0, 0, 0, 0
                                 ; torion gunion ghalf yura2 yfire tamao dragon dshot drgb
    .byte 2, 3, 0, 1, 1, 4, 5, 0, 6

.proc torp_hit                   ; Y = the victim slot (class in tmpL3)
    lda tmpL3
    cmp #6                       ; the lower half: the HP lives in the upper slot
    bne @own
    ldy #9
:   lda o_type,y
    cmp #OBJ_DRAGON
    beq @asboss
    dey
    bpl :-
    rts                          ; no upper half left: ignore
@asboss:
    lda #5
    sta tmpL3
@own:
    lda vthp,y                   ; HP first ($2aad: dec + clink while nonzero)
    beq @kill
    dea                          ; (no dec abs,y on the 65C02)
    sta vthp,y
    lda tmpL3
    cmp #5                       ; only the boss clinks (GB $dff0=1 for $1a)
    bne @silent
    lda #SFX_DFF0_01
    jmp sfx_play
@silent:
    rts
@kill:
    lda tmpL3
    cmp #4
    beq @silent                  ; tamao: absorbs silently forever (hp $FF
    cmp #3                       ; underflowed? re-arm it)
    beq @split
    cmp #5
    beq @boss
    phy
    tya
    tax
    jsr puff_slot                ; torion/honen/leap -> puff; 400 (class 2)
    ply                          ; or 100 (class 1)
    lda tmpL3
    cmp #2
    beq @v400
    lda #$01
    bra sc0
@v400:
    lda #$04
    bra sc0
@split:
    tya
    tax
    lda #OBJ_GHALF               ; the split machine (o_st 0 = rising phase)
    sta o_type,x
    stz o_st,x
    stz o_tmr,x
    lda #$08                     ; 800 (class 2)
    bra sc0
@boss:
    tya
    tax
    jsr puff_slot
    ldx #9                       ; the arena clears with him (capture: Tamao +
@swp:
    lda o_type,x                 ; the in-flight shot both puffed)
    cmp #OBJ_TAMAO
    beq @puf
    cmp #OBJ_DSHOT
    beq @puf
    cmp #OBJ_DRGB
    bne @nxt
@puf:
    jsr puff_slot
@nxt:
    dex
    bpl @swp
    lda #$50                     ; 5000 (class 3)
sc0:
    tax                          ; the class code is BCD HUNDREDS (GB $0A29):
    lda #0                       ; hundreds ride add_score's X
    jmp add_score
.endproc

.proc puff_slot                  ; slot X -> the 32f explosion puff
    lda #OBJ_BOOM
    sta o_type,x
    lda #32
    sta o_tmr,x
    rts
.endproc


.segment "W2FV"
.proc draw_torp                  ; one 8x8 dart
    ldx #TORP_T
    bra draw_one
.endproc
.proc draw_one                   ; X = the tile. o_y is the 16px-box TOP; the
    phx                          ; 8px sprite draws at +8 to match the engine's
    ldx oi                       ; erase (the wball trail law) -- spawns store
    lda o_y,x                    ; visual_y - 8 in o_y.
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    plx
    jmp draw_quad
.endproc

; ---------------------------------------------------------------------------
; foes. Contact is state-$0D style: ANY overlap = the touch column (no stomp);
; star applies the ball column (torion/tamao/dragon/shots: $00 = no effect).
.proc veh_touch                  ; A-in = the star reaction (0 none, 1 puff+100)
    sta tmpL2                    ; the GB $0aaf test, bit-exact (docs/12):
    lda o_type,x                 ; rel_x = (o_x-cam)-spr_x in [-3 .. w*8+2],
    sec                          ; rel_y = o_y-spr_y in [-b .. 6+h*8] (b=2 big)
    sbc #OBJ_HONEN
    tay
    lda vbox,y
    beq @no                      ; boxless (drgb: the upper slot owns contact)
    sta tmpH3
    lda o_xl,x
    sec
    sbc cam_x
    sta tmpL3
    lda o_xh,x
    sbc cam_x+1
    bne @no                      ; far offscreen
    lda tmpL3
    sec
    sbc spr_x                    ; rel_x
    clc
    adc #3
    sta tmpL3
    lda tmpH3
    and #$F0                     ; w*8 (the high nibble is already w*16/2)
    lsr
    clc
    adc #5                       ; accept rel_x <= w*8+2 (GB-exact; +5 vs the
    cmp tmpL3                    ; +3 bias -- the first cut was 1px generous)
    bcc @no
    lda tmpL3                    ; negative rel_x+3 wrapped: reject
    cmp #$80
    bcs @no
    lda o_y,x
    sec
    sbc spr_y                    ; rel_y
    clc
    adc #2                       ; +b (the GB big-band; small errs 2px generous)
    sta tmpL3
    lda tmpH3
    and #$0F
    asl
    asl
    asl                          ; h*8
    clc
    adc #8                       ; accept rel_y <= 6+h8 (GB-exact, +2 bias)
    cmp tmpL3
    bcc @no
    lda tmpL3
    cmp #$80
    bcs @no
    ldx oi
    lda tmpL2
    ldy mario_starT
    beq @hurt
    and #1
    beq @no                      ; star + ball col $00: they just coexist
    jsr foe_corpse
    ldx oi
    jsr victim_xy
    lda o_y,x
    sta tmpH3
    lda #$01
    jsr award_kill_at
    sec
    rts
@no:
    clc
    rts
@hurt:
    jsr hurt_mario
    sec
    rts
vbox:                            ; GB phys byte1 per type (docs/12 table)
    .byte $12,$22,0,0,0,0,0      ; honen leap hcorp lcorp wball subv torp
    .byte $22,$22,$11,$21,$21    ; torion gunion ghalf yura2 yfire
    .byte $22,$24,$11,0          ; tamao dragon dshot drgb
.endproc

.segment "W2C"
.proc upd_torion                 ; $1D: -2x (+1y aimed at spawn) every 3rd frame
    jsr l3_cull
    bcc :+
    rts
:   inc o_tmr,x                  ; free-running (the flap)
    inc o_st,x                   ; the 1-in-3 divider
    lda o_st,x
    cmp #3
    bcc @foe
    stz o_st,x
    lda o_xl,x
    sec
    sbc #2
    sta o_xl,x
    bcs :+
    dec o_xh,x
:   lda o_y,x
    clc
    adc o_vy,x                   ; the spawn aim: +-1 toward Mario, forever
    sta o_y,x
@foe:
    lda #0                       ; star: ball col $00 -> passes through
    jmp veh_touch
.endproc

.proc upd_gunion                 ; $20: bobs in place, 8px triangle at 1px/3f
    jsr l3_cull
    bcc :+
    rts
:   inc o_vy,x                   ; the 1-in-3 divider (o_vy is free here;
                                 ; o_tmr stays 0 = the single shipped frame)
    lda o_vy,x
    cmp #3
    bcc @foe
    stz o_vy,x
    lda o_st,x                   ; bit7 = up, low bits = phase step 0..7
    bmi @up
    inc o_y,x
    bra @phase
@up:
    dec o_y,x
@phase:
    inc o_st,x
    lda o_st,x
    and #$0F
    cmp #8
    bcc @foe
    lda o_st,x
    and #$80
    eor #$80                     ; flip the direction, restart the count
    sta o_st,x
@foe:
    lda #1                       ; star: the ball column morphs it -- a puff
    jmp veh_touch                ; reads the same at play speed
.endproc

.proc upd_ghalf                  ; $22 half (o_st>=2) / the split machine (0/1)
    ldx oi
    lda o_st,x
    cmp #2
    bcs @half
    ; the machine: sink 4px, drop a half, rise 16px, drop the other, puff
    inc o_tmr,x
    lda o_tmr,x
    cmp #4
    bcc @sink
    cmp #20
    bcc @rise
    jsr spawn_half
    ldx oi
    lda #OBJ_BOOM                ; the parent puffs out ($37c2 params $14/$15)
    sta o_type,x
    lda #32
    sta o_tmr,x
    rts
@sink:
    inc o_y,x
    rts
@rise:
    cmp #4
    bne :+
    jsr spawn_half               ; the first half at the sunk position
    ldx oi
:   dec o_y,x
    rts
@half:
    jsr l3_cull
    bcc :+
    rts
:   lda o_xl,x                   ; a half: level flight, 1px/f, spawn-side dir
    clc
    adc o_vx,x
    sta o_xl,x
    lda o_vx,x
    bmi @neg
    bcc @foe
    inc o_xh,x
    bra @foe
@neg:
    bcs @foe
    dec o_xh,x
@foe:
    lda #0
    jmp veh_touch
.endproc

.segment "W2FAR"
.proc spawn_half
    lda #OBJ_GHALF
    jsr spawn_at_parent
    bcs @full
    lda #2                       ; a flying half (o_st>=2), fleeing LEFT
    sta o_st,y
    lda #$FF
    sta o_vx,y
@full:
    rts
.endproc
.segment "W2C"


.segment "W2FAR"
.proc draw_ghalf                 ; the flickering blob (GB $45/$46 = $E2/$E3)
    ldx oi
    jsr foe_frame
    clc
    adc #FIRE_T
    tax
    jmp draw_one
.endproc

.segment "W2C"
.proc upd_yura2                  ; $2F: paces the scroll (+1x/2f), y toward
    jsr l3_cull                  ; Mario 1px/8f, spits a $30 every 48f; after
    bcc :+                       ; 3 spits it JOINS the school (morphs $30)
    rts
:   lda frame_count
    lsr
    bcs @slow
    inc o_xl,x
    bne @slow
    inc o_xh,x
@slow:
    inc o_tmr,x
    lda o_tmr,x
    cmp #34                      ; GB cadence: a spit every ~34f
    bcc @foe
    stz o_tmr,x
    lda o_y,x                    ; the stair: +4px down before each spit
    clc                          ; (capture: y 128->132->136->140 = the school
    adc #4                       ; forms a diagonal, never a stack)
    sta o_y,x
    lda o_st,x
    cmp #2
    bcs @join
    inc o_st,x
    lda #SFX_DFF8_04
    jsr sfx_play
    ldx oi
    jsr spawn_yfire
    ldx oi
    bra @foe
@join:
    lda #OBJ_YFIRE               ; the third fish IS the parent (GB morph --
    sta o_type,x                 ; three per school, not four)
    stz o_st,x
@foe:
    lda #1                       ; ball col $27: star kills
    jmp veh_touch
.endproc

.segment "W2FAR"
.proc spawn_yfire
    lda #OBJ_YFIRE
    ; falls through
.endproc
.proc spawn_at_parent            ; A = type: allocate at the spawner's position;
    jsr obj_alloc_typed          ; C=0 with the NEW slot in Y (X back to oi)
    bcs @full
    stz o_pdr,x
    ldy oi
    lda o_xl,y
    sta o_xl,x
    lda o_xh,y
    sta o_xh,x
    lda o_y,y
    sta o_y,x
    stz o_st,x
    stz o_tmr,x
    stz vthp,x
    txa
    tay
    clc
@full:
    ldx oi
    rts
.endproc
.segment "W2C"


.segment "W2FAR"
.proc upd_yfire                  ; $30: the rectangle sweep (capture): LEFT
    jsr l3_cull                  ; 1px/f ~144f, then VERTICAAL 24px toward
    bcc :+                       ; Mario's depth, then RIGHT off the screen
    rts
:   lda o_st,x
    cmp #1
    beq @vert
    bcs @right
    inc o_tmr,x
    lda o_tmr,x
    cmp #144
    bcc @left
    lda #1                       ; -> the vertical leg: pick the y direction
    sta o_st,x
    stz o_tmr,x
    lda #1
    ldy o_y,x
    cpy spr_y
    bcc :+
    lda #$FF
:   sta o_vy,x
@left:
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
    bra @foe
@vert:
    lda o_y,x
    clc
    adc o_vy,x
    sta o_y,x
    inc o_tmr,x
    lda o_tmr,x
    cmp #24
    bcc @foe
    lda #2
    sta o_st,x
    bra @foe
@right:
    inc o_xl,x
    bne :+
    inc o_xh,x
:   lda o_xl,x                   ; past the right edge: gone
    sec
    sbc cam_x
    sta tmpL3
    lda o_xh,x
    sbc cam_x+1
    bne @gone
    lda tmpL3
    cmp #168
    bcs @gone
@foe:
    lda #1                       ; ball col $27: star kills
    jmp veh_touch
@gone:
    stz o_type,x
    rts
.endproc
.segment "W2C"


.segment "W2FAR"
.segment "W2C"
.proc draw_yura2                 ; the school fish: a 16x8 pair, side by side
    ldx oi                       ; (GB param $2C/$2E = [a8][a9]/[b8][b9]); the
    jsr foe_frame                ; flap picks the pair
    asl
    clc
    adc #YUR2_T
    tax
    phx
    jsr draw_one                 ; sets dy = o_y+8; the right half rides it
    ldx oi
    lda spr_col
    ina
    ina
    sta dcol
    plx
    inx
    jmp draw_quad
.endproc
.segment "W2FAR"

.proc draw_tamao                 ; pre-mirrored quad via the shared 16q
    lda #TAM_T                   ; (o_tmr stays 0 = frame A; o_hp $FF = native)
    jmp draw_16q
.endproc

.segment "W2FV"
.proc upd_tamao                  ; $48: the invincible 0.5px/f diagonal bouncer
    jsr l3_cull                  ; (screen-bound bounce: he lives only in the
    bcc :+                       ; fixed boss chamber)
    rts
:   lda frame_count
    lsr
    bcs @foe
    lda o_st,x                   ; bit0 = x right, bit1 = y down
    and #1
    beq @xl
    inc o_xl,x
    bne @xchk
    inc o_xh,x
    bra @xchk
@xl:
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
@xchk:
    lda o_xl,x
    sec
    sbc cam_x
    sta tmpL3
    lda o_xh,x
    sbc cam_x+1
    bne @xflip
    lda tmpL3
    cmp #16
    bcc @xflip
    cmp #132
    bcc @ystep
@xflip:
    lda o_st,x
    eor #1
    sta o_st,x
@ystep:
    lda o_st,x
    and #2
    beq @yu
    inc o_y,x
    lda o_y,x
    cmp #124
    bcc @foe
    bra @yflip
@yu:
    dec o_y,x
    lda o_y,x
    cmp #33
    bcs @foe
@yflip:
    lda o_st,x
    eor #2
    sta o_st,x
@foe:
    ldx oi
    lda #0                       ; invincible: star passes too
    jmp veh_touch
.endproc

.segment "W2FAR"
.proc draw_gunion
    lda #GUN_TA
    jmp draw_16q                 ; o_hp stays $FF (faces left, native)
.endproc

.segment "W2FV"
.proc upd_dragon                 ; $1A: right-edge vertical patrol + spits
    jsr l3_cull
    bcc :+
    rts
:   jsr drgb_ensure              ; the glued lower half (its own erase slot)
    ldx oi
    lda frame_count
    lsr
    bcs @tick
    lda o_st,x                   ; 0 = up, 1 = down (0.5px/f)
    bne @dn
    dec o_y,x
    lda o_y,x
    cmp #63
    bcs @tick
    lda #1
    sta o_st,x
    bra @tick
@dn:
    inc o_y,x
    lda o_y,x
    cmp #124
    bcc @tick
    stz o_st,x
@tick:
    ldx oi
    inc o_tmr,x
    lda o_tmr,x
    cmp #64                      ; a shot every ~64f (capture cadence)
    bcc @foe
    stz o_tmr,x
    lda #SFX_DFF8_04
    jsr sfx_play
    ldx oi
    jsr spawn_dshot
@foe:
    ldx oi
    lda #0                       ; star: ball col $00 -> no effect
    jmp veh_touch
.endproc

.proc drgb_ensure                ; keep the lower half allocated + glued
    ldy #9
:   lda o_type,y
    cmp #OBJ_DRGB
    beq @glue
    dey
    bpl :-
    lda #OBJ_DRGB
    jsr obj_alloc_typed
    bcs @none
    stz o_pdr,x
    txa
    tay
@glue:
    ldx oi
    lda o_xl,x
    sta o_xl,y
    lda o_xh,x
    sta o_xh,y
    lda o_y,x
    clc
    adc #16
    sta o_y,y
@none:
    ldx oi
    rts
.endproc

.proc upd_drgb                   ; glued by the upper half; orphaned -> gone
    ldy #9
:   lda o_type,y
    cmp #OBJ_DRAGON
    beq @ok
    dey
    bpl :-
    stz o_type,x                 ; orphaned (the upper half died): vanish
    rts
@ok:
    lda #0
    jmp veh_touch
.endproc

.proc spawn_dshot
    lda #OBJ_DSHOT
    jsr spawn_at_parent          ; at the body (visual +8 = the mouth band);
    bcs @full                    ; nudge 4 left
    lda o_xl,y
    sec
    sbc #4
    sta o_xl,y
    bcs @full
    lda o_xh,y
    dea
    sta o_xh,y
@full:
    rts
.endproc

.segment "W2FAR"
.proc upd_dshot                  ; $1F rise 2px/f x16f -> $58 level left 1px/f
    jsr l3_cull
    bcc :+
    rts
:   lda o_st,x
    bne @level
    dec o_y,x
    dec o_y,x
    lda o_y,x
    cmp #34                      ; never into the HUD
    bcc @tolevel
    inc o_tmr,x
    lda o_tmr,x
    cmp #16
    bcc @foe
@tolevel:
    lda #1
    sta o_st,x
    bra @foe
@level:
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
@foe:
    ldx oi
    lda #0                       ; star: col $00 -> a starred sub just tanks it
    jmp veh_touch
.endproc
.segment "W2C"


.segment "W2FAR"
.proc draw_dshot
    jmp draw_ghalf               ; same blob
.endproc

.segment "W2FAR"
.proc draw_dragon                ; the upper 16x16 (tiles 0-3 of the frame)
    lda #0
    bra drg_half
.endproc
.proc draw_drgb                  ; the lower 16x16 (tiles 4-7)
    lda #4
    ; falls through
.endproc
.proc drg_half
    clc
    adc #DRG_TA
    sta tmpH3                    ; this half's first tile
    stz do_flip
    ldy #0
@t: phy
    ldx oi
    lda o_y,x
    clc
    adc dg_dy,y
    sta dy
    lda spr_col
    clc
    adc dg_dc,y
    sta dcol
    tya
    clc
    adc tmpH3
    tax
    jsr draw_quad
    ply
    iny
    cpy #4
    bne @t
    rts
dg_dy: .byte 0,0,8,8
dg_dc: .byte 0,2,0,2
.endproc

; ---------------------------------------------------------------------------
.segment "W2FAR"
.proc veh_clear                  ; = goal_check's body: jingle freeze -> tally
    lda #1
    sta goal_phase
    lda #240
    sta goal_tmr
    stz goal_top
    lda #3
    sta mus_rate
    jsr mus_stop
    lda #MUS_GOAL_
    jmp mus_start
.endproc

; mar_spawn: the 2-3 spawn cases (A = GB type, Y = entry offset). Same C
; contract as w2_spawn: C=0 consumed, C=1 = pool full (the spawner retries).
.proc mar_spawn                  ; A = GB type, Y = entry offset. Table-driven
    sty tmpL3                    ; (bank5 diet). C contract = w2_spawn's.
    ldy #4
:   cmp mst_gb,y
    beq @hit
    dey
    bpl :-
    clc                          ; not a 2-3 type: consume-and-forget
    rts
@hit:
    lda mst_port,y
    phy
    ldy tmpL3
    jsr w2_go
    ply
    bcs @full
    lda mst_hp,y
    sta vthp,x
    lda #$FF                     ; face left / no mirror (16q reads bit7)
    sta o_hp,x
    cpy #0                       ; torion: the spawn-time y aim (F0 $90)
    bne @ok
    lda #1
    ldy o_y,x
    cpy spr_y
    bcc :+
    lda #$FF
:   sta o_vy,x
@ok:
    clc
@full:
    rts
mst_gb:   .byte $1D, $20, $2F, $48, $1A
mst_port: .byte OBJ_TORION, OBJ_GUNION, OBJ_YURA2, OBJ_TAMAO, OBJ_DRAGON
mst_hp:   .byte 1, 2, 0, $FF, 19
.endproc
