; ---------------------------------------------------------------------------
; KIT_SKY43 -- the 4-3 SKY POP vehicle (blob build -D EAS3 -D W4KIT -D SKY43;
; pack_w4 pair 11/12). The GB runs the aeroplane on the SAME State_0D code as
; 2-3's submarine (docs/12), so this is kit_mar23's vehicle player, measured
; there, with the plane's own constants (GB OAM/RAM at 4-3, 2026-09-04):
;   hull quad = base sheet $63 $64 / $65 $66, the propeller alternates the
;   BOTTOM-RIGHT tile $66/$67 on frame_count bit 2 (the sub swaps its BL +2);
;   start c202 = 49, c201 = 134 (hull top 112) -- veh_home 42 as the sub;
;   missile = tile $6E, from (c202+5, c201-2), 2px/f, A/B fire, held A /12f;
;   autoscroll 0.5px/f to cam 3680 (map 480 cols x 8 - 160). The enemies are
;   World 4's AI-VM types ($52/$53/$59 + Tatanga $61): contact stays
;   kit_w3's w3_touch; missiles hit VM slots through torp_scan below.
; Everything lives in SKYFAR (page 11's resident far segment, $A680-$AFFF):
; the resident page is mapped whenever the engine calls in.
; ---------------------------------------------------------------------------
OBJ_TORP   = 37                  ; the missile (3 max, fire-managed)
OBJ_SUBV   = 38                  ; the plane sprite (glued to Mario); 36 = OBJ_W3
SUB_T   = $63                    ; base sheet: plane quad $63 $64 $65 $66 (+1 blade)
TORP_T  = $6E                    ; base sheet: the missile (8x8)
VGB_A     = $01
VGB_B     = $02
VGB_RIGHT = $10
VGB_LEFT  = $20
VGB_UP    = $40
VGB_DOWN  = $80
VAUTO_HI = >3680                 ; the autoscroll ceiling (map 3840 - 160, GB-measured)
VAUTO_LO = <3680
MUS_GOAL_ = 3

.segment "SKYFAR"
; 2-3 kept these as .byte in its RAM window; SKYFAR is ROM (page 11), so the
; same lines here were write-once constants: vacc never accumulated and the
; autoscroll never started (blank-scroll 4-3, 2026-09-04). Kit RAM instead,
; after the composer's CX_* bytes ($1FE0-6); E37: $1F80-~$1FE9 is the loader
; during a load, so veh_init (which runs after it) writes the initial values.
vfire   = $1FE7                  ; hold-A autofire countdown (GB $c0ae, /12)
vlastfc = $1FE8                  ; frame_count as of the last scroll decision
vacc    = $1FE9                  ; elapsed-frame accumulator (2 frames = 1px)
vhome   = $1FEA                  ; pending "take the plane's own start x"
subdead = $1FEB                  ; 1 = the hull died with Mario
vstep   = $1FEC                  ; 1 = the camera stepped THIS frame (missiles ride it)
                                 ; ($1FE7-$1FEB: inside the loader's footprint
                                 ; during a LOAD only (E37) -- veh_init writes
                                 ; them after it; w3_hp owns $1FF4-$1FFD)
.proc veh_init
    lda #1                       ; the blob-local state (see the equates)
    sta vfire
    sta vhome
    lda #$FF
    sta vlastfc
    stz vacc
    stz subdead
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
.segment "SKYFAR"


.segment "SKYFAR"
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
    stz vstep
    bcc @move
@scroll:
    inc vstep                    ; the missiles are SCREEN-space on the GB (2px/f
                                 ; on screen while the level scrolls under them)
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
.segment "SKYFAR"
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
.segment "SKYFAR"


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

.segment "SKYFAR"

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
.segment "SKYFAR"

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

.segment "SKYFAR"
.proc draw_subv                  ; the PLANE quad: $63 $64 / $65 $66|$67 (GB OAM,
    stz do_flip                  ; 4-3 f5..f64): the BR quad is the propeller and
    stz tmpL2                    ; alternates $66/$67 every 4 frames (captured
                                 ; 6667777666677776666...). BIG form: not yet
                                 ; captured on the GB (needs the level's mushroom);
                                 ; drawn with the small tiles until it is (docs/45).
    lda frame_count
    and #4
    beq :+
    lda #1
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
    cpy #3
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

.segment "SKYFAR"
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
    lda spr_x                    ; the missile shows at (hull left + 9, hull top + 4) on
    clc                          ; its first frame and moves 2/f from there (GB OAM 4-3:
                                 ; 44,46,48.. with the hull at 35). The port's upd_torp
                                 ; runs in the launch frame too, so spawn 2px short of
                                 ; that: hull left = spr_x - 7 -> spr_x + 0.
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
    lda vstep                    ; +2px/f ON SCREEN (GB OAM: 44,46,48,... per frame
    clc                          ; while the camera advances 0.5/f), so the world
    adc #2                       ; step is 2 + this frame's camera step (vstep) --
    adc o_xl,x                   ; summed FIRST: a second adc after the low-byte
    sta o_xl,x                   ; add ate its carry and missiles wrapped 256px left
    bcc :+
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


.proc puff_slot                  ; slot X -> the 32f explosion puff
    lda #OBJ_BOOM
    sta o_type,x
    lda #32
    sta o_tmr,x
    rts
.endproc


.segment "SKYFAR"
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

.segment "SKYFAR"

; --- the lethal hit hides the hull (from kit_mar23, verbatim) ---------------
.segment "SKYFAR"
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

; --- missiles vs the AI-VM (GB $2aad, State_0D: contact column +4) ----------
; torp_scan: X = the missile slot. A VM slot within |dx| < 12 and the foe's
; box height takes the hit: HP (phys byte2 & $3F, hits kept in w3_hp like the
; Superball's) decrements with a clink for the boss ($61 -- GB $dff0=1 for
; $1a/$61/$60) and, at 0, the col+4 morph from w3_torpt (resident W3TAB) with
; the phys-byte2 score class -- the ball rule of main.s w3_ball, column +4.
.segment "SKYFAR"
.proc torp_scan
    ldy #9
@loop:
    lda o_type,y
    cmp #OBJ_W3
    bne @next
    lda o_xl,y                   ; |dx| < 12
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
    lda o_y,x                    ; the missile's VISUAL y (o_y is top-8)
    clc
    adc #8
    sec
    sbc o_y,y
    clc
    adc #14                      ; foe box: top-14 .. top + height
    sta tmpH2
    phx
    ldx w3_ti,y
    lda w3_phys1,x               ; phys byte1 low nibble = height in 8px units
    plx
    and #$0F
    asl
    asl
    asl
    clc
    adc #18
    cmp tmpH2
    bcc @next
    jsr torp_hit                 ; Y = the victim
    ldx oi
    stz o_type,x                 ; the missile is consumed
    rts
@next:
    dey
    bpl @loop
    rts
.endproc

.proc torp_hit                   ; Y = the victim VM slot
    sty tmpH3                    ; keep the victim across the popup/score calls
    ldx w3_ti,y
    lda w3_phys2,x
    and #$3F                     ; HP
    cmp w3_hp,y
    beq @kill
    lda w3_hp,y                  ; absorbed: one more hit taken
    ina
    sta w3_hp,y
    lda w3_typetab,x
    cmp #$61                     ; only the boss clinks
    bne @rts
    lda #SFX_DFF0_01
    jmp sfx_play
@kill:
    lda w3_torpt,x               ; column +4: the type to become ($00 = none)
    beq @rts
    sta tmpL3
    lda w3_phys2,x               ; score class = byte2 >> 6 -> 100/400/800/5000
    rol
    rol
    rol
    and #3
    tax
    lda @val,x
    tay                          ; Y = the score code
    ldx tmpH3
    phx                          ; the victim slot rides the stack: award_kill_at
    jsr victim_xy                ; reads the popup's Y from tmpH3 (OBJ_SUU sets it
    lda o_y,x                    ; so), and keeping the SLOT there put every
    sta tmpH3                    ; missile-kill popup at y ~245, off the screen
    tya
    jsr award_kill_at            ; popup at tmpL2/H2 (x) / tmpH3 (y)
    plx
    jmp w3_morph                 ; tmpL3 = the new type; fresh context (X = slot)
@rts:
    rts
@val: .byte $01, $04, $08, $50
.endproc

; --- the hull slot during the clear sequence (from kit_mar23, verbatim) ----
.segment "SKYFAR"
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

.segment "SKYFAR"
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

.proc veh_clear                  ; = goal_check's body: jingle freeze -> tally
    lda #1
    sta goal_phase
    lda #240
    sta goal_tmr
    stz goal_top
    ; (2-3 armed the rope rescue here -- 4-3's ending is the GAME ending:
    ;  Tatanga dead -> Daisy; TODO derive from the GB, docs/45)
    lda #3
    sta mus_rate
    jsr mus_stop
    lda #MUS_GOAL_
    jmp mus_start
.endproc

