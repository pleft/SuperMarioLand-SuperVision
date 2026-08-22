; ---------------------------------------------------------------------------
; KIT_MAR23 -- the 2-3 MARINE POP kit (blob build -D MAR23; pack_banks level 5).
; Everything here is GB-measured (2026-08-18 PyBoy captures + bank0/1/3 RE):
;   State_0D vehicle: dpad 1px/f (left 2px/f while the autoscroll runs), screen
;   clamps x[8,152] y[25,126]. THE FRAME (OAM-measured 2026-08-20, hull quad
;   $70-$73): hull top-left = (c202-15, c201-22), so port spr_x = c202-8 and
;   spr_y = c201-22 = the hull's VISUAL TOP. A probe at GB $ffad = c201+d reads
;   the row ($ffad-16)>>3, i.e. screen y = spr_y+d+6 -- the kit used spr_y+d and
;   was reading one tile row high everywhere. Autoscroll
;   0.5px/f to cam 2720; a wall costs the sub 1px of screen x per scroll step
;   and NOTHING else (there is no screen-edge crush death in State_0D), tile $E1 (and $83) = THE SPHERE -> level clear (GB 1b45: clear
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
; --- the boss arena, all four sprites OAM-measured on the GB (docs/40) ---
TAM_T   = $B8                    ; tamao frame A = four FLIPS of GB $AA...
TAM_TB  = $C6                    ; ...frame B = four flips of $AB; 30f apiece
DRG_MTH = $BC                    ; dragon 16x32, MOUTH frame (GB $AE/$BE/$CE/$BC)
DRG_RST = $CA                    ; ...REST frame (GB $BA/$CA/$DA/$CC). 25 : 39
                                 ; frames of his 64-frame shot cycle, in that order
DSH_A   = $C4                    ; his SHOT: ONE 8x8 ball, from the ARENA'S OWN
DSH_B   = $C5                    ; obj sheet (dshot23.svt), $E2/$E3 every 4f
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
vlastfc: .byte $FF                ; frame_count as of the last scroll decision
vacc:   .byte 0                  ; elapsed-frame accumulator (2 frames = 1px)
vhome:  .byte 1                  ; pending "take the sub's own start x" (ovl_bind
                                 ; runs BEFORE load_level writes the shared spawn)
subdead: .byte 0                 ; 1 = the hull died with Mario; sub_ensure must
                                 ; not bring it back for the death animation
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
    lda #1                       ; the sub's own start x, applied on the first
    sta vhome                    ; step (the shared spawn lands after this)
    stz subdead                  ; a fresh life starts with the hull alive
    lda #5                       ; 56% of combat frames carry 4-8 movers: the
    sta bud_base                 ; 3-cap deferral holes were the user's flashing
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
:   lda subdead                  ; A NEW LIFE STARTS WITH THE HULL BACK. do_respawn
    beq @live                    ; resets the engine's state but cannot reach the
    lda death_anim               ; kit's, and veh_step never runs while the death
    bne @live                    ; animation owns the frame -- so subdead still set
    stz subdead                  ; HERE means the respawn has already happened
                                 ; (user: "if I lose a life the sub remains
                                 ;  disappeared when gameplay starts again")
    lda #1                       ; ...and do_respawn used the WALKING start x
    sta vhome
@live:
    lda vhome
    beq :+
    stz vhome
    jsr veh_home
:
    lda spr_x                    ; the walk normally derives mario_vx; the dead
    clc                          ; pose draws from it -- stale, it threw every
    adc scroll_s                 ; death hop far from the sub (user-diagnosed:
    sta mario_vx                 ; "the real player position is where the sub is")
    jsr sub_ensure               ; the sub sprite object (survives respawns)
    ; --- autoscroll: +1px every other frame until cam 2720 ($4fb2) ---
    ; Decide ONCE PER FRAME, not once per call. Sampling frame_count's parity
    ; alone assumes the game loop runs exactly once per frame; measured on the
    ; real core it does not, and the camera came out at 0.4715 px/frame against
    ; the GB's 0.5000 -- 5.7% slow, with cam_x stepping +2 on 45 frames and 0 on
    ; 159 that should have moved. That drift desynchronised the whole level
    ; (the boss arrived 211 frames late; the first school latched its chase
    ; direction off the wrong Mario position).
    jsr veh_scrolls              ; C=1 -> this frame gets a scroll step (W2FAR)
    bcc @move
@scroll:
    inc cam_x
    bne :+
    inc cam_x+1
    ; GB $4fcb, byte for byte: the camera moved right, so DROP the screen x
    ; first (that keeps the sub's WORLD position, and makes the probe below
    ; read the same column it read last frame), then give the pixel back only
    ; if the way is clear. $50cc signals "solid" by POPPING its caller's return
    ; address ($50ff: pop hl / ret), which skips the `inc [hl]` at $4fea -- so
    ; a wall costs the sub one screen pixel per scroll step, and nothing else.
:   dec spr_x                    ; GB $4fdb: dec [$c202]
    lda spr_x
    cmp #$F8                     ; GB c202 == 0 (port x = GB c202 - 8)
    bne :+
    lda #$E8                     ; GB $4fe0: ld [hl],$f0 -- park it off-screen...
    sta spr_x
:   jsr veh_crush                ; ...and then $515e KILLS (W2FAR: no room here)
    lda #8                       ; GB $4fe2: probe 8px right of the NEW position
    jsr vprobe_h
    bcs @move                    ; blocked: the dec stands (GB skips $4fea)
    inc spr_x                    ; clear: the sub is carried by the scroll
@move:
    ; --- vertical (falls through into horizontal = GB diagonals) ---
    lda pad_held
    and #VGB_UP
    beq @try_dn
    jsr vprobe_up
    bcs @horiz
    lda spr_y
    cmp #26                      ; top clamp (GB c201 $30 -> hull top 25)
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
    cmp #126                     ; bottom clamp (GB c201 $94 -> hull top 126)
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
    lda #<-6                     ; GB $4fff probes ONCE for the whole move...
    jsr vprobe_h
    bcs @fire
    lda spr_x
    cmp #9                       ; ...guards the FIRST dec against the clamp
    bcc @fire                    ; (GB $5008: cp $10 / ret c)
    dec spr_x
    jsr at_max                   ; ...and the second dec, taken while the scroll
    bcs @fire                    ; still runs ($5012), is UNGUARDED -- which is
    dec spr_x                    ; why holding left reaches c202 = 14, two below
                                 ; the $10 clamp (OAM-measured: hull left -1).
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
.segment "W2FAR"
; veh_home: the Marine Pop's start x. do_respawn hands every level the WALKING
; start (spr_x 40), but the GB puts the sub at $c202 = 50 -- OAM-measured, the
; hull quad sits at screen x 35..51, y 112..128, and the kit's own draw is
; c202-15 = spr_x-7, so spr_x must be 42. At 40 the hull sat 2px left of the
; GB's for the whole level (it is CARRIED by the autoscroll, so the error never
; washes out) and every probe read 2px early.
.proc veh_home
    lda #42                      ; GB c202 = 50 at every level start -> hull left
    sta spr_x                    ; 35; the kit draws at spr_x-7, so 42.
    rts
.endproc

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
.segment "W2C"


; probes ($50cc/$5046/$5089 in port coords). All classify through vh_class:
; C=1 blocked; coins collect in passing; E1/$83 = the sphere -> level clear.
.proc vprobe_h                   ; A = x offset (+8 right / -6 left)
    jsr veh_col                  ; feet_col = (cam + spr_x + A) >> 3
    lda spr_y
    clc
    adc #11                      ; GB $50cc row = c201+5; c201 = spr_y+22 and the
    jsr vrowset                  ; row is ($ffad-16)>>3, so the screen y probed
                                 ; is spr_y+5+6. The kit read spr_y+5 -- a whole
                                 ; tile row HIGH, all level long.
    jsr vh_read
    bcs @out                     ; blocked (or clear/coin handled)
    lda mario_big                ; big sub: a second row at c201-3 ($50cc e=2)
    beq @out
    lda spr_y
    clc
    adc #3
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
    clc
    adc #3                       ; GB $5046: c201-3 small, c201-4 big
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
    adc #16                      ; GB $5089: c201+$0a
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
    jsr col_shift                ; -> a COLUMN, then fold it into the GB's ring
    jmp veh_fold                 ; (veh_fold lives in W2FAR: the RAM kit window
.endproc                         ;  is full)

.segment "W2FAR"
.proc yur_stair                  ; X = the spitter's slot: o_y += the latched step
    lda o_y,x                    ; (o_vy, set once at spawn -- see mar_spawn)
    clc
    adc o_vy,x
    sta o_y,x
    rts
.endproc

.proc veh_crush                  ; GB $515e: death when c202 == 0 or c202 >= $ED
    lda spr_x                    ; (port x = c202 - 8, so 229..248). The $f0 park
    cmp #229                     ; the scroll does at c202 == 0 is ITSELF >= $ED,
    bcc @ok                      ; so being shoved off the left edge ends the
    cmp #249                     ; life. Measured on the CLEAN rom: holding right
    bcs @ok                      ; in 2-3 dies at f403 with c202 = 241, again at
    pla                          ; f1014, lives 2 -> 1 -> 0.
    pla                          ; drop veh_step's return: the kill is a TAIL
    stz mario_big                ; call, exactly as it was before.
    jsr sub_off
    jmp hurt_mario
@ok:
    rts
.endproc

.proc veh_scrolls                ; C=1 -> take a scroll step this call.
    lda frame_count              ; Advances the camera by exactly 0.5px per FRAME
    sec                          ; regardless of how many times the game loop runs
    sbc vlastfc                  ; in a frame. Measured on the real core: the loop
    beq @no                      ; is NOT 1:1 with frames -- sampling frame_count's
    cmp #3                       ; parity per call gave 0.4715 px/frame against the
    bcc :+                       ; GB's 0.5000, and that 5.7% drift desynchronised
    lda #2                       ; the level. So accumulate ELAPSED FRAMES -- but
                                 ; CLAMP them: the 80-frame grow flash freezes the
                                 ; whole action (main.s: "game frozen"), and the GB
                                 ; does not scroll one pixel through it. Banking
                                 ; those 80 frames cashed them out as a ~40px camera
                                 ; jump the instant the sub finished growing.
:   clc
    adc vacc
    sta vacc
    lda frame_count
    sta vlastfc
    lda vacc
    cmp #2
    bcc @no
    sbc #2
    sta vacc
    jsr at_max
    bcs @no
    sec                          ; ONE step per call, never more: the caller's step
    rts                          ; is the GB's whole protocol -- cam_x, the spr_x
@no:                             ; give-back, and the column the engine feeds off
    clc                          ; that move. Surplus poked straight into cam_x here
    rts                          ; scrolled the MAP without drawing the BACKGROUND,
.endproc                         ; which is the "collision shifted left" report.

.proc veh_fold
    ; --- the GB's 32-column BG RING (GB $3ee6: col = ($ffae - 8) >> 3, and
    ; $ffae is a BYTE) --- the probe cannot see past the streamed window: a
    ; column beyond it wraps 32 back and reads STALE map. Reachable in ordinary
    ; play: hold right into the wall and the autoscroll parks the sub off the
    ; left edge (GB-measured: $c202 -> $f0, then it drifts back in), and from
    ; there the probe sits ~30 columns ahead.
    ;
    ; The frontier is (cam_x >> 3) + 27, MEASURED: every tilemap slot rewrite in
    ; a hooked GB trace (slots 5, 29, 30, 31) gives exactly 27, no scatter. It
    ; must be compared against cam_x >> 3 and NOT fb_col0 -- fb_col0 advances 4
    ; columns per 32px shift, so it lags cam_x >> 3 by 0..3 and no constant
    ; threshold against it can be right. ($c0ab, the pointer 192px ahead of the
    ; view, understates the frontier by 3 columns; using it left the sub blocked
    ; ~100 frames longer than the GB's.)
    lda cam_x+1                  ; tmpL/tmpH = cam_x >> 3 (safe scratch here:
    lsr                          ; read_map_tile recomputes its own, and no
    sta tmpH                     ; caller holds a tmp across vprobe_h).
    lda cam_x                    ; (A -1 here matches the GB's streaming by one
    ror                          ; more pixel -- it fires just AFTER the column
    lsr tmpH                     ; boundary -- but costs 9 bytes the window does
    ror                          ; not have, and buys 1px. The school chase below
    lsr tmpH                     ; bought a death.)
    ror
    sta tmpL
    lda feet_col                 ; d = feet_col - (cam_x >> 3)
    sec
    sbc tmpL
    pha
    lda feet_col+1
    sbc tmpH
    beq @maybe
    pla                          ; behind the camera, or absurdly far: never fold
    rts
@maybe:
    pla
    cmp #28                      ; resident iff d <= 27
    bcc @done
    lda feet_col
    sec
    sbc #32
    sta feet_col
    lda feet_col+1
    sbc #0
    sta feet_col+1
@done:
    rts
.endproc
.segment "W2C"

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
    lda subdead                  ; killed this life? stay gone (the death hop
    beq :+                       ; plays alone, GB-true)
    rts
:   ldx #9
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
    lda spr_y                    ; draw_subv paints its quad at o_y + 0 (sq_dy is
    sta o_y,x                    ; 0,0,8,8, like every quad table here), so o_y IS
                                 ; the hull's drawn top -- and the GB's hull top is
                                 ; c201-22 = spr_y exactly. The -8 that used to sit
                                 ; here was written for the engine's "visual =
                                 ; o_y+8" law, which draw_subv does not follow, so
                                 ; it lifted the whole sub 8px: at the floor limit
                                 ; the GB's hull spans 126..141 and the port's spanned
                                 ; 118..133, floating a tile above the ground and
                                 ; putting the (correct) torpedo below the hull.
                                 ; o_ndy/o_pvy derive from o_y, so the erase box
                                 ; follows this shift on its own.
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
    adc #2                       ; nose at (spr_x+2, spr_y+4): GB OAM, tile $7A,
    adc cam_x
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda spr_y
    sec
    sbc #4                       ; measured at two different depths = hull top + 4,
    sta o_y,x                    ; not -2. o_y = visual - 8 (the draw_one/erase law).
                                 ; 6px too high put the torpedo in the tile ROW ABOVE
                                 ; the floor blocks, so at the bottom of the arena it
                                 ; sailed over the wall you have to shoot to get out.
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
:   cmp #$80                     ; ?-block: GB $2097 semantics (torp_qblock)
    bne @gone
    jsr torp_qblock
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


.segment "W2FAR"
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
    sta tmpL2                    ; box = the MEASURED GB kill window (PyBoy slot
    lda o_type,x                 ; sweeps, 2026-08-18): rel_x in [-w8-1..+2],
    sec                          ; rel_y in [-8..ymax(h)] with ymax 6/15/20 for
    sbc #OBJ_HONEN               ; h=1/2/4. The x half agrees with $0aaf's algebra
    tay                          ; to a pixel; the y half does NOT, and the SWEEP
                                 ; is the one to trust -- see docs/38 finding 13:
                                 ; the GB's $0aaf reports contact on frames where
                                 ; it then does no damage, so its box alone is not
                                 ; the kill rule.
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
    sta tmpL3
    lda tmpH3
    and #$F0
    lsr                          ; w*8
    sta tmpH2
    ina                          ; val = rel_x + w8 + 1  (>= 0 iff rel >= -w8-1)
    clc
    adc tmpL3
    cmp #$80
    bcs @no                      ; wrapped negative: left of the window
    sta tmpL3
    lda tmpH2
    clc
    adc #4                       ; bound: accept val <= w8+3 (right edge +2..3,
    cmp tmpL3                    ; the MEASURED static GB edge)
    bcc @no
    lda tmpH3                    ; --- vertical: the GB's own algebra ($0aaf) ---
    and #$0F                     ; N = height in 8px units
    asl
    asl
    asl
    sta tmpH2                    ; 8N
    lda o_y,x                    ; rel_y = o_y - spr_y
    sec
    sbc spr_y
    clc
    adc tmpH2                    ; val = rel_y + 8N + 1 (>= 0 iff rel >= -(8N+1))
    ina
    cmp #$80
    bcs @no
    sta tmpL3
    lda tmpH2
    clc
    adc #5                       ; accept val <= 8N+5, i.e. rel_y <= 4
    cmp tmpL3
    bcc @no
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
    jsr sub_off                  ; the hull vanishes with the hit: the death
    jsr hurt_mario               ; shows ONE clean hop at the true spot
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
    jsr yur_stair                ; step 4px toward Mario (W2FAR: the window is full)
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
.proc torp_qblock                ; GB $2097: award ONLY registered content,
    jsr find_block               ; then shatter -- NO bonk-hop, NO coin default
    bcc @shatter                 ; (hit_qblock is the BONK handler; using it
    cmp #$28                     ; here gave the user a coin + a hopping block)
    beq @pow
    cmp #$2A
    beq @heart
    cmp #$2C
    beq @star
    bra @shatter                 ; multicoin/$F0/unknown: shatter only
@pow:
    lda mario_big                ; the SML size rule, same as the bonk path
    bne @flower
    lda #1                       ; OBJ_MUSH
    jsr spawn_walker
    bra @shatter
@flower:
    jsr spawn_flower
    bra @shatter
@heart:
    lda #5                       ; OBJ_HEART
    jsr spawn_walker
    bra @shatter
@star:
    jsr spawn_star
@shatter:
    jmp break_brick              ; erase + repaint + debris + 50 (the GB shape)
.endproc

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
.proc upd_yfire                  ; $30 rectangle sweep (capture): LEFT 1px/f
    jsr l3_cull                  ; ~144f -> 24px VERTICAL toward Mario -> RIGHT
    bcc :+                       ; off the screen
    rts
:   inc o_tmr,x
    lda o_st,x
    bne @s12
    lda o_xl,x                   ; the left leg
    bne :+
    dec o_xh,x
:   dec o_xl,x
    lda o_tmr,x
    cmp #112                     ; GB-measured: the left leg turns after 112f
    bcc @foe                     ; (144 ran it off the screen edge -- it was
                                 ; CULLED before the turn, so the sweep looked
                                 ; like a plain right-to-left swim)
@adv:
    stz o_tmr,x
    inc o_st,x
    lda #1                       ; aim the vertical leg at Mario's depth
    ldy o_y,x
    cpy spr_y
    bcc :+
    lda #$FF
:   sta o_vy,x
    bra @foe
@s12:
    cmp #2
    bcs @right
    lda o_y,x                    ; the vertical leg
    clc
    adc o_vy,x
    sta o_y,x
    lda o_tmr,x
    cmp #32                      ; GB-measured: the vertical leg is 32px, not 24
    bcs @adv
    bra @foe
@right:
    inc o_xl,x
    bne :+
    inc o_xh,x
:   lda o_xl,x                   ; the return leg BEGINS off the left edge: the
    sec                          ; left+vertical legs end around screen x -7, so
    sbc cam_x                    ; culling on "screen x went negative" killed the
    tay                          ; fish two frames into its swim back -- it flipped
    lda o_xh,x                   ; to face right and then vanished (user-reported).
    sbc cam_x+1                  ; Only drop it past the RIGHT edge; l3_cull still
    beq @onscr                   ; retires it at -20 if it never turns around.
    cmp #$FF                     ; high byte $FF = off the LEFT: keep swimming
    beq @foe
    bra @gone
@onscr:
    cpy #176                     ; screen is 160 wide; the GB drops them just past
    bcc @foe
@gone:
    stz o_type,x
    rts
@foe:
    lda #1                       ; ball col $27: star kills
    jmp veh_touch
.endproc
.segment "W2C"


.segment "W2FAR"
.proc draw_yura2                 ; the school fish: a 16x8 pair, side by side
    ldx oi                       ; (GB param $2C/$2E = [a8][a9]/[b8][b9]); the
    stz do_flip                  ; flap picks the pair. The tiles face LEFT
    lda o_type,x                 ; natively; the SCHOOL fish ($30) turns round for
    cmp #OBJ_YFIRE               ; its return leg -- GB-measured, its direction
    bne @faced                   ; byte flips HALFWAY through the 32f vertical leg
    lda o_st,x                   ; (leg starts f112, $02 -> $03 at f128) and stays
    beq @faced                   ; right for the whole right-hand leg. The spitter
    cmp #2                       ; ($2F) shares this draw and never turns, so the
    bcs @flip                    ; test is gated on the type.
    lda o_tmr,x
    cmp #16
    bcc @faced
@flip:
    lda #1
    sta do_flip
@faced:
    ldx oi
    jsr foe_frame
    asl
    clc
    adc #YUR2_T
    ldy do_flip
    beq @first
    ina                          ; mirrored: the two halves swap sides as well, or
@first:                          ; the head lands where the tail should be
    tax
    phx
    jsr draw_one                 ; sets dy = o_y+8; the other half rides it
    ldx oi
    lda spr_col
    ina
    ina
    sta dcol
    plx
    ldy do_flip
    bne @mirror
    inx
    jmp draw_quad
@mirror:
    dex
    jmp draw_quad
.endproc
.segment "W2FAR"

.proc draw_tamao                 ; pre-mirrored quad via the shared 16q
    ldx oi                       ; GB OAM: frame A = four flips of $AA, frame B of
    lda o_tmr,x                  ; $AB, 30 frames apiece. o_tmr is free here (his
    cmp #30                      ; bounce keeps direction in o_st), so it carries
    lda #TAM_T                   ; the phase; upd_tamao winds it 0..59.
    bcc :+
    lda #TAM_TB
:   jmp draw_16q_f               ; ...and NOT draw_16q: its foe_frame flap would
.endproc                         ; add 4 and land on the DRAGON's tiles

.segment "W2FAR"
.proc upd_tamao                  ; $48: the invincible 0.5px/f diagonal bouncer
    jsr l3_cull                  ; (screen-bounds bounce; he lives only in the
    bcc :+                       ; fixed boss chamber)
    rts
:   ldx oi                       ; the 60-frame animation phase (draw_tamao splits
    inc o_tmr,x                  ; it 30/30); it winds every frame, unlike the
    lda o_tmr,x                  ; movement below, which is gated to every other
    cmp #60
    bcc :+
    stz o_tmr,x
:   lda frame_count
    lsr
    bcs @foe
    ldx oi
    lda o_st,x                   ; bit0 = x right, bit1 = y down
    lsr
    bcs @xr
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
    bra @xchk
@xr:
    inc o_xl,x
    bne @xchk
    inc o_xh,x
@xchk:
    lda o_xl,x
    sec
    sbc cam_x
    tay
    lda o_xh,x
    sbc cam_x+1
    bne @xf
    cpy #16
    bcc @xf
    cpy #132
    bcc @y
@xf:
    lda o_st,x
    eor #1
    sta o_st,x
@y:
    lda o_st,x
    and #2
    beq @yu
    inc o_y,x
    lda o_y,x
    cmp #124
    bcc @foe
    bra @yf
@yu:
    dec o_y,x
    lda o_y,x
    cmp #33
    bcs @foe
@yf:
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

.segment "W2FAR"
.proc upd_dragon                 ; $1A: right-edge vertical patrol + spits
    jsr l3_cull
    bcc :+
    rts
:   jsr drgb_ensure              ; the glued lower half (its own erase slot)
    ldx oi
    lda o_vy,x                   ; GB-measured: 65px per 116-frame leg = 0.560 px/f;
    clc                          ; a 143/256 subpixel accumulator gives 0.559 (the
    adc #143                     ; old frame_count>>1 gate was a flat 0.50)
    sta o_vy,x
    bcc @tick
    lda o_st,x                   ; 0 = up, 1 = down
    bne @dn
    dec o_y,x
    lda o_y,x
    cmp #40                      ; GB-measured patrol, in SCREEN pixels off his
    bcs @tick                    ; OAM over the whole fight: top 39..104, turning
                                 ; dead clean at both ends, 65px of travel. (The
                                 ; old 87..120 came from a short window plus the
                                 ; +24 anchor rule, which is wrong for a 32-tall
                                 ; sprite -- it put him half a screen too low and
                                 ; gave him half his range. His visual top IS o_y.)
    lda #1
    sta o_st,x
    bra @tick
@dn:
    inc o_y,x
    lda o_y,x
    cmp #104
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
    lda o_tmr,x                  ; the halves must pick the SAME animation frame,
    sta o_tmr,y                  ; and the lower one is a separate object
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

.segment "W2C"
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
.segment "W2FAR"


.segment "W2C"
.proc spawn_dshot                ; GB OAM, every shot of the fight: it appears at
    lda #OBJ_DSHOT               ; HIS OWN x (his leftmost tile -- he faces left,
    jsr spawn_at_parent          ; so that is the mouth) and settles at his visual
    bcs @full                    ; top + 6. The shot draws at o_y+8, so o_y - 2.
    lda o_y,y
    sec
    sbc #2
    sta o_y,y
@full:
    rts
.endproc
.segment "W2FAR"


.segment "W2FAR"
.proc upd_dshot                  ; LEVEL flight left at 1px/f, after 3 frames of
    jsr l3_cull                  ; nothing. The GB does climb 11px first -- but it
    bcc :+                       ; climbs during the 3 frames it is drawn with tile
    rts                          ; $FE, which is BLANK, so not one pixel of that
:   lda o_st,x                   ; climb is ever on screen. The port used to fly it
    bne @level                   ; up 32px over 16 VISIBLE frames instead.
    inc o_tmr,x
    lda o_tmr,x
    cmp #3
    bcc @foe
    inc o_st,x
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
.proc draw_dshot                 ; ONE 8x8 BALL. OAM in the arena: never a stack --
    ldx oi                       ; it was drawn as three rows of the DRAGON'S OWN
    lda o_st,x                   ; BODY ($BE/$C0/$C2), which is the "graphics mess"
    bne @fly                     ; in the user's photo. GB tile $FE is BLANK: the
    lda o_tmr,x                  ; shot is invisible for its first 3 frames, the
    cmp #3                       ; ones it spends inside his mouth.
    bcc @none
@fly:
    stz do_flip
    lda frame_count              ; $E2/$E3 alternate every 4 frames, in step across
    and #4                       ; every shot on screen (GB-measured: both balls
    beq :+                       ; always show the same tile)
    lda #DSH_B
    bra @go
:   lda #DSH_A
@go:
    tax
    ldy oi
    lda o_y,y
    clc
    adc #8                       ; visual top = o_y + 8 (law A1)
    sta dy
    lda spr_col
    sta dcol
    jmp draw_quad
@none:
    rts
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
.proc drg_half                   ; A = 0 (upper half) or 4 (lower)
    pha                          ; His frame rides the SHOT CYCLE, GB-measured:
    ldx oi                       ; mouth open for the 15 frames after a shot and
    lda o_tmr,x                  ; the 10 before the next, rest for the other 39.
    cmp #15                      ; o_tmr is exactly that cycle (0 = just fired,
    bcc @mouth                   ; upd_dragon fires at 64), so no new state is
    cmp #54                      ; needed -- the port simply never had the second
    bcs @mouth                   ; frame's tiles and stood on the mouth one.
    lda #DRG_RST
    bra @base
@mouth:
    lda #DRG_MTH
@base:
    sta tmpH3
    pla
    clc
    adc tmpH3
    sta tmpH3                    ; this half's first tile
    stz do_flip
    ldy #0
@t: phy
    ldx oi
    lda o_y,x
    clc
    adc quad_rows,y              ; the FIXED 2x2 quadrant tables (bank5 diet:
    sta dy                       ; dg_dy/dg_dc were byte-identical copies)
    lda spr_col
    clc
    adc quad_cols,y
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
.endproc

; ---------------------------------------------------------------------------
.segment "W2FAR"
.segment "W2C"
.proc veh_clear                  ; = goal_check's body: jingle freeze -> tally
    lda #1
    sta goal_phase
    lda #240
    sta goal_tmr
    stz goal_top
    jsr veh_arm                  ; ...and the x-3 rescue follows it (docs/25)
    lda #3
    sta mus_rate
    jsr mus_stop
    lda #MUS_GOAL_
    jmp mus_start
.endproc
.segment "W2FAR"

.proc veh_arm                    ; sphere touched: arm the rescue machine
    lda #2                       ; ending13=2 = the 2-3 flavor (the room
    sta ending13                 ; machine swaps in the W2 creature tiles)
    lda #<358                    ; the 2-3 rope column, rows 6-9 (GB-captured:
    sta e_cap                    ; $EC->$2C bottom-up in state $1E, SFX $0B;
    rts                          ; l3e_rope_tile reads the low byte from e_cap)
.endproc

; sub_step: the hull slot's step. Idle through play and the jingle/tally; at
; the LAST phase-4 frame the kit hands the player back -- the GB swaps the
; sub for standing Mario exactly at $06 -> $1C (OAM-captured: the sub quad
; persists through $07 and the whole tally).
.proc sub_step
    lda goal_phase
    beq @rts                     ; play: idle (real GIFT pickups share this row)
    cmp #2
    bne :+
    lda goal_tmr                 ; the LAST hold frame: dodge the tally burst --
    cmp #1                       ; OBJ_GIFT (22) sits below l3e_boom's range and
    bne @rts                     ; stops drawing, so the hull's pixels freeze on
    lda #OBJ_GIFT                ; screen (GB: the sub is static and visible
    sta o_type,x                 ; through the whole tally). The GIFT dispatch
    rts                          ; row also runs sub_step: the handover below
:   cmp #4                       ; still fires from the re-typed slot.
    bne @rts
    lda goal_tmr
    cmp #1
    bne @rts
    stz veh_vec+1                ; draw_player resumes: standing, facing right
    stz mario_frame
    stz mario_facing
    stz o_type,x                 ; the hull despawns (pipeline-erased: the swap
@rts:                            ; lands exactly at the GB's $06 -> $1C)
    rts
.endproc

; mar_spawn: the 2-3 spawn cases (A = GB type, Y = entry offset). Same C
; contract as w2_spawn: C=0 consumed, C=1 = pool full (the spawner retries).
.segment "W2FAR"
.proc sub_off                    ; the LETHAL hit despawns the hull AND wipes its
                                 ; pixels: once death_anim is set the main loop
                                 ; runs only death_frame, so the object pipeline
                                 ; never gets another chance to erase it (user:
                                 ; "sub remains, mario's death animation plays").
    lda mario_big                ; a hit while BIG only shrinks the sub -- it
    ora hurt_inv                 ; keeps playing, so the hull must stay. Same for
    ora mario_grow               ; a hit that hurt_mario will THROW AWAY (i-frames,
    ora mario_shrink             ; mid grow/shrink): despawning the hull there left
    bne @rts                     ; Mario alive with no sub at all, for the rest of
    lda #1                       ; the level -- caught by the 2-3 ending regression
    sta subdead                  ; and sub_ensure must not bring it back
    ldy #9
@scan:
    lda o_type,y
    cmp #OBJ_SUBV
    bne @next
    lda #0
    sta o_type,y
    lda o_pvx,y                  ; the rect the pipeline last drew it into
    sec
    sbc #4
    bcs @xok
    lda #0
@xok:
    sta rb_vx
    lda o_pvy,y
    sec
    sbc #8
    bcs @yok
    lda #0
@yok:
    sta rb_y
    lda #4                       ; 16px hull + a margin, in 8px cells
    sta rb_cols
    sta rb_rows
    phy
    jsr restore_bg
    ply
@next:
    dey
    bpl @scan
@rts:
    rts
.endproc

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
    ; --- spawn-time y aim, shared by the two types that have one ---
    ; $2F latches the SCHOOL'S STAIR here and keeps it for all three fish: the
    ; GB decides from where Mario is when the spitter appears, so driving Mario
    ; up makes every fish rise (108/104/100) even after he comes back down,
    ; while no input makes every fish sink (116/120/124). Re-deciding per spit
    ; reverses the third one and does NOT match the GB.
    cpy #2
    bne @tor
    lda #4                       ; the school's stair, 4px per spit
    bra @aimy
@tor:
    cpy #0                       ; torion: the spawn-time y aim (F0 $90), 1px
    bne @ok
    lda #1
@aimy:
    ldy o_y,x                    ; object BELOW Mario -> negate, i.e. rise to him
    cpy spr_y
    bcc @sty
    eor #$FF
    ina
@sty:
    sta o_vy,x
@ok:
    clc
@full:
    rts
mst_gb:   .byte $1D, $20, $2F, $48, $1A
mst_port: .byte OBJ_TORION, OBJ_GUNION, OBJ_YURA2, OBJ_TAMAO, OBJ_DRAGON
mst_hp:   .byte 1, 2, 0, $FF, 19
.endproc
