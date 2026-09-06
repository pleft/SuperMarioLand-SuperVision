; ===========================================================================
; THE WORLD-3 AI-VM (docs/34): the GB's OWN enemy interpreter, ported.
;
; Super Mario Land drives every scripted enemy with one small VM ($2676 +
; $2879 + ObjectPhysics_Integrate, read out of the disassembly and confirmed
; against live slot dumps). Porting the VM instead of hand-writing a dozen
; movers keeps W3 (and later W4) behaviour GB-exact by construction: the
; scripts ship as DATA (build/w3scripts.bin, packed into bank 6) and the
; metasprite display lists ride in this window blob.
;
; Per-slot VM context (the GB keeps these in HRAM and swaps them per object):
;   o_st  = metasprite param      (ffc6)
;   o_tmr = wait counter          (ffc8)
;   o_hp  = (tick counter << 4) | tick divider   (ffc9)
;   o_vx  = current velocity byte (ffc1): hi nibble = Y px/tick, lo = X
;   o_vy  = direction flags       (ffc5): bit0 = moving RIGHT, bit1 = FALLING
;   w3_pc[slot] = script PC, w3_ti[slot] = VM type index
; ===========================================================================
; --- the GB's ball-vs-object box (Call_000_200a -> $0aaf; docs/12 + docs/38 s12)
; The engine's ball_hits used |dx|<10, |dy|<10 around the slot's top-left for
; every type; the GB tests the ball's tiny box [obj_x, obj_x+4] x [obj_y,
; obj_y+3] against the foe's size-byte box (phys1: N = &$0F height, W = >>4&7
; width, bit7 = ball-immune): x [obj_x-8(W-1), obj_x], y [obj_y-8(N-1),
; obj_y+8). obj = o_x+8 / o_y+24 on BOTH sides (the ball draws at o_y+8 like
; the 8px kit sprites; a 16px foe's o_y is its top), so in port coordinates:
;   dx = ball - foe in [4-8W, 0]      dy = ball - foe in [-3, 8N-1]
; A ball at a 16x16 foe's feet (dy 10..15) hits on the GB and passed here
; (user: 4-1's Pionpi "doesn't get killed" shooting continuously); a ball at
; its right side (dx > 0) passed on the GB and hit here.
; X = the foe slot (ball_hits' oi2), oi = the ball. C=1 overlap. Keeps X.
.segment "W3TAB"               ; FIRST in the resident tables area = the $B000 pin
.proc w3_ballbox                 ; FIXED calls (main.s W3BOX): W2C/X2 have no room
                                 ; for a vector case, and the resident page is
                                 ; mapped whenever ball_hits runs
    ldy w3_ti,x
    lda w3_phys1,y
    bmi @miss                    ; +$0A bit7: ball-immune
    sta tmpH2                    ; the size byte
    ldy oi
    lda o_xl,y
    sec
    sbc o_xl,x
    sta tmpL3
    lda o_xh,y
    sbc o_xh,x
    beq @pos                     ; dx >= 0: only dx == 0 still overlaps
    cmp #$FF
    bne @miss
    lda tmpL3                    ; dx < 0: need -dx <= 8W-4
    eor #$FF
    ina
    sta tmpL3
    lda tmpH2
    lsr
    lsr
    lsr
    lsr
    and #7                       ; W
    asl
    asl
    asl                          ; 8W
    sec
    sbc #4
    cmp tmpL3
    bcc @miss                    ; 8W-4 < -dx
    bra @ychk
@pos:
    lda tmpL3
    bne @miss                    ; dx > 0
@ychk:
    ldy oi
    lda o_y,y
    sec
    sbc o_y,x                    ; dy
    clc
    adc #3                       ; dy+3: 0..8N+2 overlaps (a far-negative dy wraps high)
    sta tmpL3
    lda tmpH2
    and #$0F
    asl
    asl
    asl                          ; 8N
    clc
    adc #2
    cmp tmpL3
    bcc @miss                    ; 8N+2 < dy+3
    lda o_y,x                    ; hit: hand the victim's y to award_kill_at
    sta tmpH3                    ; (its popup sits at tmpL2/H2/tmpH3; nothing on
    sec                          ; the ball path set tmpH3, so every kit foe's
    rts                          ; Superball "800" popped at a stale y -- off-screen
                                 ; in the Pompon capture, o_y 176. 2026-09-06)
@miss:
    clc
    rts
.endproc
.assert w3_ballbox = $B000, error, "w3_ballbox must sit at the W3BOX pin ($B000)"
.segment "W2C"

.if .defined(SKY43)               ; each kit carries ITS OWN data set: they live in
.include "w43data.inc"           ; that pair's COLD page and the overlays differ.
.elseif .defined(W4KIT)          ; 4-3 = "world 43" (gen_w3data), pages 11/12
.include "w4data.inc"            ; 4-1/4-2, pages 9/10
.else
.include "w3data.inc"            ; World 3, bank 6 (docs/45)
.endif
.include "w3auxabi.inc"        ; aux_compose/aux_uncompose (page 8, docs/42)            ; every table here is read BEFORE the reader or
                                 ; the draw maps bank 6, so some may live in the
                                 ; bank-RESIDENT far segment (see w3data.inc)

MUS_CLEAR3 = 3                   ; the course-clear jingle (build/audio/music.inc)
; --- the map-column cache -------------------------------------------------
; Reading a map tile means mapping bank 6, and EVERY SYS_CTRL write restarts
; the LCD scan on real hardware (docs/27: doing it once per frame already made
; a build unplayable -- banding). W3 was doing it ~22 times a frame. This
; caches whole 16-byte columns in the RAM tail the retired 2-3 loader stub
; used to borrow, so repeat probes (and the 16 reads the column streamer does)
; cost no switch at all. 4 slots x 32B stride = cheap (n<<5) indexing.
; --- the map-column cache (docs/36) -----------------------------------------
; Round-robin over 7 slots evicted the column we were about to re-read: 1.5
; misses/frame = 3.0 SYS_CTRL writes = the HUD instability the user kept
; seeing. Direct-mapped over 16 slots is the COMPULSORY floor (0.13/frame):
; a column only ever misses when the camera first scrolls it in.
; The 256 bytes of tile data live in shtab_lo's dead identity page, which is
; PAGE-ALIGNED -- so a slot's address is (slot << 4) with a constant high byte.
W3CDATA  = $0200                 ; 16 slots x 16 tile bytes (page-aligned)
W3CTAG   = $1F80                 ; 16 x [col lo][col hi]
W3CSLOTS = 16
W3CMB    = $1FFF                 ; map_base hi when the cache was filled
.ifdef W4KIT                     ; World 4's cold page (10) is laid out tighter
W3SCRB   = $B124                 ; (docs/45: window $8000, stash $86F8, maps
W3DLB    = $B71B                 ;   $8ABF-$B11E, spt, scripts, dlists, slice ->
W3TILB   = $B93C                 ;   $BDFC, walk $BE00 -- pack_w4 writes all)
.else
W3SCRB   = $B200                 ; bank 6 pins (pack_banks writes all three):
W3DLB    = $B540                 ;   scripts / metasprite display lists /
W3TILB   = $B740                 ;   the compact W3 tile slice
.endif
W3SYSC   = $2026
W3LINK   = $2021                 ; MAGNUM page (docs/37): banking here does
W3LINKV  = $2022                 ;   NOT restart the LCD scan. $2022 must read
                                 ;   0 at the $2021 write; $0F is the panel's
                                 ;   drive value, handed straight back.
W3FLG    = $0B                   ; NMI | TIMER_IRQ | LCD (load_level's mask)

; --- the group composer (docs/42 v2; MUST match src/w3aux.s) ---------------
; Per-slot STASH (20B each): +0 nt (0 = none; bit7 = dying) +1 dcol0 +2 dy0
; +3 cols +4 rows +5..8 tile ids +9..12 tile x (px, box-relative) +13..16 tile
; y +17 flags (2 bits/tile: bit0 x-flip, bit1 y-flip). Slots 0-6 live in the
; window tail, 7-9 in the $1FA0 gap.
CS_A       = $1C70               ; slots 0..6 (7 x 20 = 140B, to $1CFB); code cap $1C6F
CS_B       = $1FA0               ; slots 7..9 (3 x 20 = 60B, to $1FDB)
CX_EN      = $1FE0               ; nonzero = composer on (init sets 1)
; CX_BUILD: defined in w2code.s (the kit init reads it before this include)
CX_STAMP   = $1FE1               ; frame_count at the last per-frame sweep
CX_FB      = $1FE2               ; fb_col0 at the last sweep (shift fold)
CX_DYING   = $1FE3               ; nonzero = some entry needs a cleanup compose
CXA_DCOL0  = $01C6               ; the aux ABI block (w3aux.s AXV_*): NEW box
CXA_DY0    = $01C7
CXA_COLS   = $01C8
CXA_ROWS   = $01C9
CXA_ODCOL0 = $01CA               ; the OLD box of the object being composed
CXA_ODY0   = $01CB               ; (0 cols = none)
CXA_OCOLS  = $01CC
CXA_OROWS  = $01CD
CXA_SLOT   = $01CE               ; the object (its stash entry is the NEW state)
CXA_SKIP   = $01CF               ; 1 = nothing changed and nothing foreign touched
                                 ;     our cells: the dispatch skips the compose
; stash-walk scratch (SCRATCH area; consumed before the composer runs)
CXS_ID     = $0136               ; 4B tile ids
CXS_DC     = $013A               ; 4B dcol (biased +64)
CXS_DY     = $013E               ; 4B dy (biased +64)
CXS_FL     = $0142               ; 4B flip bits
CXS_N      = $0146
CXS_MNDC   = $0147
CXS_MXDC   = $0148
CXS_MNDY   = $0149
CXS_MXDY   = $014A
CXS_T0     = $014B
CXS_T1     = $014C
CXS_XF     = $014D
CXS_BASE   = $014E
CXS_SPRC   = $014F
CXS_MODE   = $0150               ; walk mode: 0 draw, 1 stash
CXS_T2     = $0151
CXS_T3     = $0152
CXS_BOXOK  = $0153               ; 1 = CXA_* box computed this walk

; --- spawn: A = GB type, Y = spawn entry offset. C=0 consumed. -------------
.segment "W2FAR"
.proc w3_spawn
    ldx #W3_NTYPES-1
:   cmp w3_typetab,x
    beq @found
    dex
    bpl :-
    clc                          ; not a VM type: consume and forget
    rts
@found:
    stx tmpH3
    lda #OBJ_W3
    jsr w2_go                    ; shared allocate + seed (x from the entry)
    bcs @full
    lda tmpH3
    sta w3_ti,x
    jsr w3_init
    clc
@full:
    rts
.endproc
.segment "W2C"

.proc w3_init                    ; X = slot, SPAWN entry: a fresh slot may hold
    stz o_vy,x                   ; the previous occupant's direction -- clear it
.endproc                         ; and fall through
.proc w3_init_keepdir            ; MORPH entry: the GB carries ffc5 (direction)
    ldy w3_ti,x                  ; mirror phys0/phys1 into per-slot RAM: the
    lda w3_phys0,y               ; ENGINE-side physics (w3_ffc7/w3_stand, in
    sta w3_ph0,x                 ; LEVELS -- the window is full and $1D00+ is
    lda w3_phys1,y               ; HUDSHADOW) cannot link the kit's tables
    sta w3_ph1,x
    lda #$FF                     ; poison the gravity cache: a recycled slot must
    sta w3_fcc,x                 ; not inherit the last occupant's floor verdict
    stz w3_hp,x                  ; the GB re-inits the slot's HP byte on a morph
                                 ; (Call_000_2cbb): the $60 after Tatanga starts
                                 ; at its own 24 hits, not at Tatanga's 19th
    stz w3_pc,x                  ; across F3 exactly like the param ffc6. Zeroing
    stz o_tmr,x                  ; it turned every faced missile LEFT (user:
    stz o_hp,x                   ; "always travelling left no matter where Mario
    stz o_vx,x                   ; stands") -- $4A runs F0 $40 (FACE MARIO) and
    rts                          ; THEN F3 $4B, so the facing must survive the
                                 ; morph. o_st (the param) is NOT reset either:
                                 ; $3D reads "F8 $27 / F3 $0D" and $0D never sets
                                 ; one -- clearing it left stomped enemies with
                                 ; no death sprite at all (both user-reported).
.endproc

; --- one frame of VM for slot X -------------------------------------------
.proc w3_step
    jsr w3_ffc7                  ; the GB's PER-FRAME ffc7 physics (below)
.if CX_BUILD
    jsr cs_composed              ; a COMPOSED object holds o_pdr=0 so pass 3a
    beq :+                       ; never erases it mid-frame -- but p4_one sets
    ldx oi                       ; o_pdr=1 after every draw; clear it again in
    stz o_pdr,x                  ; the update phase (after the render, docs/42)
:
.endif
    ldx oi                       ; AFTER ffc7: cs_entry clobbers tmpL2/tmpL3
    lda o_type,x                 ; gravity may have culled the slot
    cmp #OBJ_W3
    beq :+
    rts
:   lda o_xh,x                   ; RIGHT-side bound, every live slot every frame
    sec                          ; (l3_cull only runs on the contact path, which
    sbc cam_x+1                  ; a far object never enters): >= 2 pages ahead
    cmp #2                       ; of the camera (257..511px) is beyond anything
    bcc :+                       ; that can be seen -- spawns land at +192..204.
    stz o_type,x                 ; 4-2's $4B ran 1700px ahead for 1400 frames
    rts                          ; holding a slot (docs/45).
:   lda o_tmr,x                  ; wait == 0 -> run opcodes until one waits
    bne @tick
    jsr w3_fetch
@tick:
    lda o_hp,x                   ; tick gate: counter == divider ?
    and #$0F
    sta tmpL2
    lda o_hp,x
    lsr
    lsr
    lsr
    lsr
    cmp tmpL2
    beq @fire
    ina                          ; not yet: counter++
    asl
    asl
    asl
    asl
    ora tmpL2
    sta o_hp,x
    rts
@fire:
    lda tmpL2                    ; counter = 0, divider kept
    sta o_hp,x
    dec o_tmr,x
    ; falls through to the movement step
.endproc

.proc w3_move                    ; apply this tick's velocity (X = slot)
    jsr w3_touch
    ldx oi
    lda o_type,x                 ; a stomp morph may have retyped/freed the slot
    cmp #OBJ_W3
    beq :+
    rts
:
    lda o_vx,x
    and #$0F
    bne :+
    jmp @ystep
:   sta tmpH3
    lda o_vy,x
    and #$01
    bne @right
    lda #<-8                     ; GB $2879: probe one tile LEFT of the object
    jsr w3_wall                  ; ($2b84: col = (ffc3 + ffa4 - 8) >> 3, and ffc3 IS
                                 ; o_x for a VM object -- the $53 spawns at 192 on
                                 ; both; the GB's Tatanga turns 8px before the wall)
    bcs @xblocked
    ldy w3_ti,x                  ; GB $2891: phys byte 0 bit0 = TURN AT A LEDGE. No
    lda w3_phys0,y               ; floor under the leading edge (Call_000_2be4:
    lsr                          ; ffc3+3, one row below the wall row) flips the
    bcc @left                    ; direction outright (jr c,$28da), whatever bits
    lda #<-5                     ; 2-3 say. The Pompon Flower ($07) patrols its
    jsr w3_ledge                 ; platform on the GB (warp capture: dir flips at
    bcs @left                    ; the pit edge); the port walked it into 4-2's
    jmp @xflip                   ; pits (user: "committing suicide", 2026-09-06).
@left:
    lda o_xl,x                   ; default direction is LEFT (GB: ffc3 -= vx)
    sec
    sbc tmpH3
    sta o_xl,x
    bcs :+
    dec o_xh,x
:   jsr w3_carry_lf              ; the Ganchan carries its rider (engine side
    ldx oi                       ; checks ride == oi+1; tmpH3 = dx)
    bra @ystep
@right:
    lda w3_ph1,x                 ; GB $28f0: probe the RIGHT edge, x + W*8 - 8
    lsr
    lsr
    lsr
    lsr
    and #7
    asl
    asl
    asl
    sec
    sbc #8
    jsr w3_wall
    bcs @xblocked
    ldy w3_ti,x                  ; the ledge probe, right side (Call_000_2bfe:
    lda w3_phys0,y               ; ffc3 + 5 + W*8 - 8 -> W*8 - 11 in o_x terms)
    lsr
    bcc @rightgo
    lda w3_ph1,x
    lsr
    lsr
    lsr
    lsr
    and #7
    asl
    asl
    asl
    sec
    sbc #11
    jsr w3_ledge
    bcs @rightgo
    jmp @xflip
@rightgo:
    lda o_xl,x
    clc
    adc tmpH3
    sta o_xl,x
    bcc :+
    inc o_xh,x
:   jsr w3_carry_rt
    ldx oi
    bra @ystep
@xblocked:                       ; solid ahead: phys byte 0 & $0C (GB $28ce/$2958)
    ldy w3_ti,x                  ; $00 = walk on regardless, $04 = FLIP the x
    lda w3_phys0,y               ; direction (Tatanga bounces off the arena walls,
    and #$0C                     ; 4-3), $0C = RESTART the script. This probe was
    beq @xthrough                ; missing: every VM walker went through walls.
    cmp #$04
    bne @xrestart
@xflip:
    lda o_vy,x
    eor #$01
    sta o_vy,x
    bra @ystep
@xrestart:
    stz w3_pc,x
    stz o_tmr,x
    bra @ystep
@xthrough:
    lda o_vy,x
    and #$01
    bne @rightgo
    jmp @left
@ystep:
    lda o_vx,x
    lsr
    lsr
    lsr
    lsr
    beq @done
    sta tmpH3
    lda o_vy,x
    and #$02
    bne @fall
    ldy w3_ti,x                  ; phys byte 0 & $C0 -- $00 pass through, $40
    lda w3_phys0,y               ; turn to falling, $C0 RESTART the script. A
    and #$C0                     ; pass-through mover skips the PROBE itself:
    beq @rise                    ; its verdict was ignored, and 4-1's six bobbing
    pha                          ; $55 hazards re-probed the banked map every
    jsr w3_ceil                  ; tick (profiled: w3_read + mod_ptr = 10% of
    pla                          ; the frame in the pillar stretch, docs/45).
    bcc @rise                    ; (rising: solid above it? GB Call_000_2c21,
                                 ; probed BEFORE the move; PLA keeps C.) The
                                 ; Suu ($E0) climbs a scripted 96px but rests
                                 ; at its ceiling: 3-2 RE, GB restarts
    cmp #$40                     ; it at y55 -- without this the port Suu hung
    bne :+                       ; 16-40px above its tile.
    lda o_vy,x
    ora #$02
    sta o_vy,x
    rts
:   stz w3_pc,x
    stz o_tmr,x
    rts
@rise:
    lda o_y,x
    sec
    sbc tmpH3
    sta o_y,x
    rts
@fall:
    ldy w3_ti,x                  ; the response is the type's phys byte 0
    lda w3_phys0,y               ; (ffc7) & $30 -- $00 pass through, $10 land
    and #$30                     ; (stop falling), $30 RESTART the script
    beq @fmove                   ; (Batadon's hop loop). Pass-through: no probe.
    pha
    jsr w3_floor                 ; solid under it? (GB Call_000_2bbb)
    pla                          ; (PLA keeps C)
    bcc @fmove
    cmp #$10
    bne :+
    lda o_vy,x
    and #$FD
    sta o_vy,x
    rts
:   cmp #$30
    bne @done
    stz w3_pc,x
    stz o_tmr,x
    rts
@fmove:
    lda o_y,x
    clc
    adc tmpH3
    sta o_y,x
@done:
    rts
.endproc



                        ; sound mailbox the port has no capture for (FD)

; (w3_f6 lives in FIXED -- main.s -- the window is full; exported via w2abi)
.segment "W2C"
.segment "W2FAR"
.segment "W2C"

.proc w3_getop                   ; A = script[pc]; pc++ (the blob is in bank 6)
    ldy w3_ti,x
    lda w3_scrlo,y               ; script base (bank 6) + this slot's PC
    clc
    adc #<W3SCRB
    sta tmpL
    lda w3_scrhi,y
    adc #>W3SCRB
    sta tmpH
    lda tmpL
    clc
    adc w3_pc,x
    sta tmpL
    bcc :+
    inc tmpH
:   inc w3_pc,x
    stz W3LINKV
    lda w3_cold
    sta W3LINK
    lda #$0F
    sta W3LINKV
    ldy #0
    lda (tmpL),y
    tay
    stz W3LINKV        ; back to THIS LEVEL's resident bank -- hardcoding 1 here
    lda cur_bank       ; left World 4 running in World 3's bank after every single
    sta W3LINK         ; script fetch: its VM then read W3's blob at W4's offsets,
                       ; so waits and velocities came out of the bg charset (4-1's
                       ; upside-down Piranha travelled 36px instead of 16, docs/45)
    lda #$0F
    sta W3LINKV
    tya
    rts
.endproc

; --- F0: direction control (disasm $2711-$2789) ---------------------------
.segment "W2FAR"
.segment "W2C"

.segment "W2FAR"
.segment "W2C"

; --- terrain probes (the port's own tile semantics) -----------------------
; In the RESIDENT page's W3TAB area (mapped whenever the kit runs; w3_read's
; own page dance restores it before returning here): the $1500 window is
; full to the byte and the cold-page layout pins its size (docs/45).
.segment "W3TAB"
.proc w3_ceil                    ; C=1 when the tile ABOVE the object is SOLID:
    lda w3_ph1,x                 ; the GB probes ffc2 - (h-1)*8 at the floor
    and #$07                     ; probe's column (h = phys1 & 7). The port's
    eor #$FF                     ; "feet row" sits one row under the GB's probe
    ina                          ; row, so the delta is -(h-1): measured, the
    ina                          ; Suu restarts at GB y55 exactly like the GB
    bra w3_probe                 ; (-h fired a row early, y63).
.endproc
.proc w3_floor                   ; C=1 when the tile under the object is SOLID
    lda #0
.endproc                         ; falls through
; w3_wall: the GB's HORIZONTAL probe (Call_000_2b84 left / 2b9a right): the
; tile at (edge x, ffc2) is solid when $5F <= tile < $F0 (note $5F, one below
; read_solid's floor rule, and coins $F4 pass). A = the probed edge's x offset:
; -8 = one tile left of the object (GB $2b84), W*8-8 = the right edge ($2b9a:
; col = (ffae - 8) >> 3 with ffae = ffc3 + W*8; ffc3 = o_x for VM objects).
; Row: (o_y + 8) >> 3 - 2. C=1 solid. Keeps X and tmpH3 (dx).
.proc w3_probe                   ; A = row delta from the feet row
    pha
    lda o_xl,x                   ; column = (world x + 4) >> 3
    clc
    adc #4
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lda o_y,x                    ; GB ffc2+8 == port o_y+8+8 (the visual-8 law)
    clc
    adc #16
    lsr
    lsr
    lsr
    sec
    sbc #2
    sta mrow
    pla
    clc
    adc mrow
    sta mrow
    phx
    jsr read_solid               ; A = 1 solid / 0 open
    plx
    lsr                          ; -> C
    rts
.endproc
.proc w3_wall
    ldy #8
body:
    pha                          ; A = SIGNED x offset (-8, or W*8-8)
    clc
    adc o_xl,x
    sta feet_col
    pla
    and #$80                     ; sign-extend the offset into the high byte
    beq :+                       ; (AND keeps the carry of the low add)
    lda #$FF
:   adc o_xh,x
    sta feet_col+1
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    tya                          ; GB row = (ffc2 - $10) >> 3 with ffc2 = o_y + 24;
    clc                          ; the port's map rows exclude the 16px HUD (mrow =
    adc o_y,x                    ; screen y/8 - 2, as w3_probe does); Y = 8 (wall) or
    lsr                          ; 16 (ledge: one row lower)
    lsr
    lsr
    sec
    sbc #2
    sta mrow
    phx
    jsr read_solid               ; (for the read: feet_tile = the raw tile)
    plx
    lda feet_tile
    cmp #$5F
    bcc @open
    cmp #$F0
    bcs @open
    sec
    rts
@open:
    clc
    rts
.endproc
.proc w3_ledge                   ; A = x offset: the tile one row BELOW w3_wall's row
    ldy #16                      ; (GB Call_000_2be4/2bfe probe ffc2 + 8)
    bne w3_wall::body            ; (Y is never 0 here)
.endproc

; --- pure VM logic moved out of the $1500 window (full to the byte): these run
; with the resident page mapped and only call RAM code (w3_getop restores the
; page before returning), so the resident W3TAB area holds them (docs/45).
.proc w3_fetch
@loop:
    jsr w3_getop
    cmp #$FF
    bne :+
    stz w3_pc,x                  ; $FF = restart the script (NOT an end)
    bra @loop
:   cmp #$F0
    bcs @ext
    cmp #$E0
    bcs @wait
    sta o_vx,x                   ; a velocity byte: applies for one tick
    bra @set1                    ; (shares F9/FA's "tick ends here" tail)
@wait:
    and #$0F                     ; $E0-$EF = wait N ticks ($EF = 15)
    sta o_tmr,x
    rts
@ext:
    sta tmpH2
    jsr w3_getop
    sta tmpL3
    lda tmpH2
    cmp #$F8                     ; set metasprite param
    bne :+
    lda tmpL3
    sta o_st,x
    bra @loop
:   cmp #$F4                     ; set the tick divider
    bne :+
    lda o_hp,x
    and #$F0
    ora tmpL3
    sta o_hp,x
    bra @loop
:   cmp #$F0                     ; direction control
    bne :+
    jsr w3_face
    bra @loop
:   cmp #$F3                     ; morph to another type
    bne :+
    jsr w3_morph
    bra @loop
:   cmp #$F1                     ; SPAWN CHILD: the moai pillar's missiles ($49
    bne :+                       ; spawns $4A, which morphs to $4B). Never
    jsr w3_child                 ; implemented, so the cannon fired nothing at all
    bra @loop                    ; (user-reported).
:   cmp #$F6                     ; F6 nn: WAIT FOR MARIO (w3_f6, far)
    bne :+
    jsr w3_f6                    ; C set = condition met, proceed
    bcc @done                    ; else: PC rewound, retry next tick
    jmp @loop
:   cmp #$F9                     ; F9 sfx / FA music-cue: the GB stores the
    beq @endtick                 ; operand and RETs -- the tick ENDS here (the
    cmp #$FA                     ; next opcode runs on the following tick). The
    bne @other                   ; old fall-through fired $49's missile a tick
@endtick:                        ; early. The cue itself: w3_cue.
    jsr w3_cue
@set1:
    lda #1
    sta o_tmr,x
@done:
    rts
@other:
    cmp #$FB                     ; FB nn (GB $2839): RESTART the script unless the
    bne :+                       ; object is within nn px to the RIGHT of Mario --
    ldx oi                       ; (objx - c202) < nn unsigned. 4-3's $53 flies
    lda o_xl,x                   ; straight, restarting, until it is 32px from the
    sec                          ; plane, then dives (GB-traced: the port dived 70
    sbc cam_x                    ; frames early while this op was skipped). Port
    sec                          ; coords: (o_x - cam) - spr_x; the GB's +8 on
    sbc spr_x                    ; both sides cancels.
    cmp tmpL3
    bcs @restart
    jmp @loop                    ; within range: carry on with the dive
@restart:
    stz w3_pc,x                  ; else PC = 0 and keep interpreting
    jmp @loop
:   cmp #$FC                     ; FC nn (GB $2856): teleport to GB (x $70, y nn)
    bne :+
    ldx oi
    lda tmpL3
    sec
    sbc #24                      ; GB y -> port o_y (the +24 law)
    sta o_y,x
    lda cam_x
    clc
    adc #$70-8                   ; GB screen x $70 = sprite left $68 + cam
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
:   jmp @loop                    ; F2/F5/F7/FD/FE: unused by the kit types, or a
.endproc
.proc w3_cue                     ; tmpH2 = F9/FA, tmpL3 = the GB sound id.
    lda tmpL3                    ; F9 nn -> $dff8 nn (SFX_DFF8_01.. are 11..14,
    dec                          ; contiguous), FA nn -> $dfe0 nn (SFX_DFE0_01..
                                 ; 0B are 0..10: extract_sfx numbers them in id
                                 ; order; nn=0 wraps to $FF and fails the cmp)
    ldy tmpH2                    ; order, the cannon's $09 included). Ids outside
    cpy #$FA                     ; the captured sets are dropped.
    beq @fa
    cmp #4
    bcs @no
    adc #SFX_DFF8_01
    bra @play
@fa:
    cmp #11
    bcs @no
@play:
    jsr sfx_play
@no:
    ldx oi
    rts
.endproc
; --- opcode fetch: runs extended ops until one sets the wait counter ------
.proc w3_morph                   ; F3: become another type, fresh context
    lda tmpL3
    ldy #W3_NTYPES-1
:   cmp w3_typetab,y
    beq @found
    dey
    bpl :-
    stz o_type,x                 ; unknown target: despawn
    rts
@found:
    tya
    sta w3_ti,x
    jmp w3_init_keepdir
.endproc
.proc w3_child                   ; tmpL3 = the GB type to spawn
                                 ; (3-3's boulders were gated off while the boss
                                 ; DRIFTED -- its walk made the arena flicker. With
                                 ; the F0 flip-bit fix the boss stands still and the
                                 ; boulders cost nothing visible: measured over 1971
                                 ; arena frames, boss intact 95%, boulders 100%.
                                 ; GB-faithful again: every cycle throws one.)
    lda tmpL3                    ; 3-3: ONE boulder at a time (user decision) --
    cmp #$33                     ; the boss waits for the last one to leave before
    bne @spawn                   ; throwing again. (Only Hiyoihoi's child is $33,
    ldx #9                       ;  and it morphs to $47 the moment it spawns.)
@scan:
    lda o_type,x
    cmp #OBJ_W3
    bne @next
    lda w3_ti,x
    cmp #21                      ; a boulder ($47) is still out
    beq @none
@next:
    dex
    bpl @scan
@spawn:
.ifdef SKY43                     ; the GB flies its 4 projectiles OUTSIDE the 10-slot
    ldy #9                       ; table ($c218..$c248, State_0D); the port's missiles
    ldx #0                       ; are object slots. After Tatanga the $60's fireworks
:   lda o_type,y                 ; (F1 $5C, 4 slots a cycle) filled the pool and no
    bne :+                       ; missile could spawn -- the $60 (24 hits = the level
    inx                          ; clear) became unkillable. Keep 3 slots free for the
:   dey                          ; missiles: a child that would leave fewer is skipped
    bpl :--                      ; (fewer simultaneous fireworks; docs/45).
    cpx #4
    bcc @none
    ldx oi
.endif
    jsr w3_spawn_at              ; engine: a slot at the parent's exact position
    bcs @none
    jsr w3_morph                 ; kit: the type lookup + a fresh VM context
@none:
    ldx oi                       ; the VM loop runs on the PARENT's slot
    rts
.endproc
.proc w3_face                    ; tmpL3 = argument
    lda tmpL3
    and #$C0
    beq @flip
    lda tmpL3
    and #$40                     ; bit6: face Mario horizontally
    beq @tv
    lda o_xl,x                   ; the object's screen x
    sec
    sbc cam_x
    cmp spr_x
    lda o_vy,x
    ora #$01                     ; object right of Mario -> ... set below
    bcs :+
    and #$FE
:   eor #$01                     ; C set = obj >= mario -> move LEFT (bit0 = 0)
    sta o_vy,x
@tv:
    lda tmpL3
    and #$80                     ; bit7: face Mario vertically
    beq @flip
    lda o_y,x
    cmp spr_y
    lda o_vy,x
    ora #$02
    bcs :+
    and #$FD
:   eor #$02
    sta o_vy,x
@flip:                           ; bits3-2 XOR-flip the direction bits, exactly as
    lda tmpL3                    ; the GB does it ($2754: `and $0C / rra / rra /
    and #$0C                     ; xor ffc5`): bit2 -> bit0 = X, bit3 -> bit1 = Y.
    lsr                          ; (They were SWAPPED here to stop a stomp corpse
    lsr                          ; flying upward -- the real cause was elsewhere;
                                 ; swapped, HIYOIHOI never flipped its X direction,
                                 ; so it walked at Mario every cycle and eventually
                                 ; off its platform into the pit -- user: "the boss
                                 ; committed suicide by falling into the void")
    beq @forcey
    eor o_vy,x
    sta o_vy,x
@forcey:
    lda tmpL3
    and #$20                     ; bit5: FORCE the Y direction from bit1
    beq @forcex
    lda o_vy,x
    ora #$02
    sta tmpH2
    lda tmpL3
    and #$02
    ora #$FD
    and tmpH2
    sta o_vy,x
@forcex:
    lda tmpL3
    and #$10                     ; bit4: FORCE the X direction from bit0
    beq @rts
    lda o_vy,x
    ora #$01
    sta tmpH2
    lda tmpL3
    and #$01
    ora #$FE
    and tmpH2
    sta o_vy,x
@rts:
    rts
.endproc
.segment "W2C"

; --- 3-3's SPHERE: the x-3 rescue ending, armed exactly like 1-3's (docs/25).
; 3-3's arena is geometrically identical to 1-3's -- the sphere is $E1 at world
; col 297 with the rope $EC at col 298 rows 6-9 -- so the existing ending
; machine runs unchanged; only the arming and the creature flavour are new.
; This runs from the map reader (the kit's only per-frame hook).
.segment "W2FAR"
.proc w3_goal                    ; 3-3's SPHERE. The engine's own goal_check can
    lda cur_level                ; never fire here (its trigger sits past the rope,
    cmp #8                       ; which is solid until the ending opens it), so the
    bne @rts                     ; kit arms the clear itself -- the same gate 1-3
    lda goal_phase               ; uses, plus the x-3 rescue flavour.
    bne @rts
    lda cam_x+1
    cmp cam_max+1
    bne @rts
    lda cam_x
    cmp cam_max
    bne @rts
    lda jump_state
    bne @rts
    lda spr_x
    cmp #126
    bcc @rts
    lda #3                       ; ending13 = 3: the World-3 creature
    sta ending13
    lda #<298                    ; 3-3's rope column (1-3's geometry)
    sta e_cap
    lda #1
    sta goal_phase
    lda #240
    sta goal_tmr
    stz goal_top
    stz mario_frame
    lda #3
    sta mus_rate
    jsr mus_stop
    lda #MUS_CLEAR3
    jmp mus_start
@rts:
    rts
.endproc
.segment "W2C"

; --- contact: the GB's own rules. $3186 column +0 is the STOMP result: $00
; means "not stompable" and the shared l3_hurt already models that exactly
; (side contact hurts; landing on it does NOTHING and Mario keeps falling --
; the GB's stone-head zone). A non-zero column morphs the slot into that type,
; which is just another VM script (the kill/puff chains are types too).
.segment "W2FAR"
.proc w3_touch                   ; the shared helpers CLOBBER X: reload it from oi
    jsr w3_stand                 ; standable top? (GB phys1 bit7) -- landing on
    txa                          ; one beats every contact rule, exactly as it
    ina                          ; does on the GB ($33/$35/$47 hurt at the SIDES
    bcc :+                       ; but carry Mario on top). RIDE BOOKKEEPING:
    jmp @setride                 ; (trampoline: SKY43's no-stomp code pushed
:                                ;  @setride out of bcs range)
    cmp ride                     ; without it, jump_player's tile probe found AIR
    bne :+                       ; under his feet every frame (the ledge is an
    stz ride                     ; OBJECT), flipped him airborne, and w3_stand
:   ldx oi                       ; snapped him back -- his pose strobed jump/
                                 ; stand and the sprite flickered (user-reported).
                                 ; ride = slot+1 while held; cleared only if it
                                 ; was OURS (another slot may hold him now).
    lda o_y,x                    ; VERTICAL cull -- o_y is a BYTE. A stomped
    cmp #168                     ; corpse falls past the bottom, wraps through
    bcc :+                       ; 255 and RAINS DOWN THE SCREEN AGAIN, forever
    cmp #232                     ; (user-reported twice: 3-1's first enemy and a
    bcs :+                       ; stomped missile). 2-3 has had this guard since
    stz o_type,x                 ; the anomaly sweep found it (kit_sh1's MAR23
    rts                          ; block); W3 never got it.
:                                ; The 232 window is NOT slack: port o_y = GB y
                                 ; - 24, so an object 24px above the GB's screen
                                 ; top is already o_y 232 -- and 3-1's high-ledge
                                 ; Batadon (spawn col 49, GB ground y 48) hops 30px,
                                 ; peaking at GB 18 = port -6 = 250. GB-measured:
                                 ; it peaks and COMES BACK DOWN, so 232..255 is a
                                 ; legal negative y, not an escape. 168 is the
                                 ; GB's own floor: its $3D corpse despawns at
                                 ; GB y 192 = port 168, measured on the same run.
    jsr l3_cull                  ; after every call (the kit-wide convention)
    bcs @rts
    jsr l3_box
    ldx oi
    bcc @rts
.ifdef SKY43
    jsr sky_item                 ; 4-3's block items ($28..$34) are VM objects in the
    bcs @rts                     ; pool: the GB keeps them out of the enemy rules
    ldy w3_ti,x                  ; (slot 9 -> $097C) and collects by type; C=1 = item
    jmp @side                    ; VEHICLE LEVEL (law B1): the plane NEVER stomps --
.endif                           ; any enemy contact goes to the side (hurt) column,
    ldy w3_ti,x                  ; exactly like 2-3's sub. The GB has no stomp path in
    lda w3_stomp,y               ; the vehicle levels; running it here let the plane
    beq @side                    ; "stomp" a flyer and bounce (user-reported).
    sta tmpL2                    ; is NOT automatically "hurts"
    lda tmpH3                    ; stomp/side split at dy <= -2: the GB's $08C7
    sbc #5                       ; constant through the +2 anchor shift (C=1 from
    cmp tmpH2                    ; l3_box's touch). l3_above's top-anchored +4 was
    bcs @stomp                   ; right for 16-tall types but sat INSIDE the
                                 ; 8-tall missile's touch window: falling contact
                                 ; landed on the SIDE branch on half the phases
                                 ; and a stomp became a hurt (user-reported).
                                 ; stomp iff val = dy+h-3 <= h-5  <=>  dy <= -2.
@side:                           ; GB $3186 column +2: $FF hurts, $00 does NOTHING,
    ldx oi                       ; anything else morphs. Treating every
    ldy w3_ti,x                  ; non-stompable as hurtful killed Mario on the
    lda w3_side,y                ; cloud corpse ($27), the falling corpse ($0D),
    beq @rts                     ; the moai pillar ($49), $3E and the stone head
    cmp #$FF                     ; ($36) -- all $00 on the GB. Bouncing on a corpse
    beq @hurt                    ; you had just stomped was fatal (user-reported).
    sta tmpL3
    jsr w3_morph
    rts
@stomp:
    ldy w3_ti,x                  ; score class = phys byte2 >> 6, taken from the
    lda w3_phys2,y               ; STOMPED type -- w3_morph below retypes the slot,
    clc                          ; and reading it afterwards gave the CORPSE's
    rol                          ; class ($0D = 0), so every stomp paid 100 instead
    rol                          ; of the Batadon's 800 or a missile's 400
    rol                          ; (user-reported). The 3 ROLs also need a clear
    and #3                       ; carry.
    tay
    lda @val,y
    pha
    lda tmpL2                    ; -> the GB's stomp morph, run by the VM
    sta tmpL3
    jsr w3_morph                 ; the corpse's OWN script decides how it looks
    ldx oi                       ; and moves -- do NOT force a param here. GB
                                 ; ($3186/$349E): $3C stomps into $3D whose script
                                 ; opens `F8 26`, while $4B (the missile) stomps
                                 ; into $0D whose script has NO F8 at all, so the
                                 ; MISSILE's own param carries and the corpse is a
                                 ; falling missile. Forcing $27 painted the
                                 ; Batadon's squash on everything -- the user saw a
                                 ; stomped missile turn into a winged moai head.
                                 ; The fall is the script's too: $0D opens `F0 64`
                                 ; = rise ~7px, then flips to falling (GB-measured
                                 ; y 109 -> 102 -> 176, ~65 frames, then gone).
    lda #1                       ; Mario's fixed stomp bounce
    sta jump_state
    lda #14
    sta arc_idx
    stz fall_v
    stz ride
    pla
    jmp award_stomp
@val: .byte $01, $04, $08, $10
@hurt:
    jmp l3_hurt
@setride:
    sta ride                     ; (falls into the rts)
@rts:
    rts
.endproc
.segment "W2C"


; --- draw: walk the GB metasprite display list ----------------------------
; control byte: bit3 y-8, bit2 y+8, bit1 x-8, bit0 x+8, bit4 -> x-flip;
; tile bytes have bit7 set. Tiles $A0-$DC resolve through the level header's
; overlay base (the W3 sheet in bank 6), everything else through chardata --
; draw_quad already does exactly that, so GB tile ids ship verbatim.
w3_cold:                         ; the MAGNUM page holding THIS world's cold data
.if .defined(SKY43)
    .byte 12                     ; 4-3 = pages (11 resident, 12 cold): pack_w4 PAIRS.
.elseif .defined(W4KIT)          ; (10 here read 4-1's columns into 4-3 -- every sky
    .byte 10                     ; World 4 = pages (9 resident, 10 cold) -- tile came
.else                            ; back solid and the scroll crushed the plane)
    .byte 6                      ; (maps, scripts, display lists, tile slice, the
.endif                           ; bank-resident walk). Each world's kit image
                                 ; carries its own: W3 = 6, W4 = 10 (docs/45).
.export w3_cold
.proc w3_bank                    ; A = MAGNUM page (the W3LINK dance)
    stz W3LINKV
    sta W3LINK
    lda #$0F
    sta W3LINKV
    rts
.endproc

.if CX_BUILD
; cs_composed: A != 0 iff slot oi is COMPOSED (entry nt 1..4, overlay-only
; bit6 clear). Z=1 otherwise. Clobbers tmpL2/tmpH2/tmpL3, X, Y.
.proc cs_composed
    jsr cs_entry
    lda (tmpL2)
    bit #$40                     ; overlay-only (plain path)?
    bne @no
    and #$0F                     ; nt: 0 = empty
    rts
@no:
    lda #0
    rts
.endproc

; cs_entry: tmpL2 -> slot oi's stash entry (slots 0-6 at CS_A, 7-9 at CS_B)
.proc cs_entry
    lda oi
    cmp #7
    bcc :+
    sbc #7                       ; (C=1)
    ldx #<CS_B
    ldy #>CS_B
    bra @m
:   ldx #<CS_A
    ldy #>CS_A
@m: stx tmpL2
    sty tmpH2
    asl                          ; *20 = *16 + *4
    asl
    sta tmpL3
    asl
    asl
    clc
    adc tmpL3
    clc
    adc tmpL2
    sta tmpL2
    bcc :+
    inc tmpH2
:   rts
.endproc
.endif

.proc w3_draw                    ; WINDOW half: bank juggling + the composed
    lda w3_cold                  ; dispatch (docs/42 v2). Walk/stash are COLD-BANK
    jsr w3_bank                  ; resident (W3X); the composer is page-8
.if CX_BUILD
    lda CX_EN                    ; resident (w3aux).
    beq @plain
    jsr w6_frame                 ; once per frame: shift fold + mark the dead
    jsr w6_cx                    ; stash this object; C=1 -> composed
    php
    lda CX_DYING                 ; entries to clean up (dead/invisible/
    beq @nosweep                 ; fallen-back)? compose their bg under page 8
    lda #8
    jsr w3_bank
    jsr aux_sweep
    stz CX_DYING
    lda #6
    jsr w3_bank
@nosweep:
    plp
    bcc @plain
    lda CXA_SKIP
    bne @done                    ; unchanged: its image is already right
    lda #8
    jsr w3_bank
    jsr aux_group
    bra @done
.endif
@plain:
    stz CXS_MODE
    jsr w6_draw
@done:
    stz do_yflip                 ; never leak the flips into engine draws
    stz do_flip
    lda cur_bank
    jmp w3_bank                  ; tail: back to THIS LEVEL's bank (was hardcoded 1,
                                 ; which pinned every W3 level to bank 1)
.endproc
.segment "W3X"
; w6_col: BANK 6 IS MAPPED -- fill the column cache slot at tmpL2 for feet_col.
; (w3_read's miss path lived in the window; the window is full.)
.proc w6_col
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
    lda (map_ptr)
    tax
    ldy #1
    lda (map_ptr),y
    sta map_ptr+1
    stx map_ptr
    ldy #15                      ; destination = tmpL2/tmpH2 (w3_read's slot
:   lda (map_ptr),y              ; pointer). NOT tmpL3: callers of the map probe
    sta (tmpL2),y                ; keep live values there (see w2code.s w3_read)
    dey
    bpl :-
    rts
.endproc

.proc w6_draw                    ; BANK-6 half: param search + the list walk
    ldx oi
    lda o_st,x                   ; param -> display-list index
    ldy #W3_NPARAM-1
:   cmp w3_paramtab,y
    beq @found
    dey
    bpl :-
    rts
@found:
    lda w3_dlo,y                 ; the RIGHT list; the LEFT one follows it
    sta tmpL
    lda w3_dhi,y
    sta tmpH
    stz tmpL2                    ; dy accumulator
    stz tmpH2                    ; dcol accumulator (bytes)
    stz do_flip
    stz do_yflip
    lda #255
    sta CXS_MNDC
    sta CXS_MNDY
    stz CXS_MXDC
    stz CXS_MXDY
    ldy #0
    ldx oi                       ; facing left? skip past the RIGHT list's $FF
    lda o_vy,x
    and #$01
    bne @walk
:   lda (tmpL),y
    iny
    cmp #$FF
    bne :-
@walk:
    lda (tmpL),y
    cmp #$FF
    bne :+
    jmp @done
:   bmi @tile
    sta tmpH3                    ; a CONTROL byte: cumulative offsets + flip
    and #$08
    beq :+
    lda tmpL2
    sec
    sbc #8
    sta tmpL2
:   lda tmpH3
    and #$04
    beq :+
    lda tmpL2
    clc
    adc #8
    sta tmpL2
:   lda tmpH3
    and #$02
    beq :+
    lda tmpH2
    sec
    sbc #2
    sta tmpH2
:   lda tmpH3
    and #$01
    beq :+
    lda tmpH2
    clc
    adc #2
    sta tmpH2
:   lda tmpH3
    and #$10
    beq :+
    lda #1
    sta do_flip
    bra :++
:   stz do_flip
:   lda tmpH3                    ; bit5 = Y-FLIP (the Ganchan's $47 tumble frame:
    and #$20                     ; same 4 tiles rotated 180 degrees -- ignoring
    beq :+                       ; it drew the halves facing the wrong way,
    lda #1                       ; user-reported twice)
    sta do_yflip
    bra @next
:   stz do_yflip
@next:
    iny
    bra @walk
@tile:
    sta tmpH3
    lda CXS_MODE
    bne @stash
    ldx oi
    lda o_y,x                    ; the port stores objects at VISUAL-8 (the engine
    clc                          ; erases at o_y+8) -- draw on that same anchor or
    adc #8                       ; the sprite smears 8px above its erase rect
    clc
    adc tmpL2
    sta dy
    lda spr_col
    clc
    adc tmpH2
    sta dcol
    phy
    ldx tmpH3
    jsr draw_quad
    ply
    iny
    jmp @walk
@stash:                          ; STASH mode (docs/42 v2): record the tile
    lda tmpH3                    ; BEHIND-capable tiles ($87-$88, $92-$95, $EE)
    cmp #$EE                     ; keep the old path AND get no overlay entry:
    beq @stash_over              ; their pixels hide behind the pipe (w3_behind)
    cmp #$87
    bcc :+
    cmp #$89
    bcc @stash_over
:   cmp #$92
    bcc :+
    cmp #$96
    bcc @stash_over
:   ldx CXS_N
    cpx #4
    bcs @stash_over
    lda tmpH3
    sta CXS_ID,x
    lda tmpH2                    ; dcol offset (bytes), biased +64
    clc
    adc #64
    sta CXS_DC,x
    cmp CXS_MNDC
    bcs :+
    sta CXS_MNDC
:   lda CXS_DC,x
    cmp CXS_MXDC
    bcc :+
    sta CXS_MXDC
:   lda tmpL2                    ; dy offset (px), biased +64
    clc
    adc #64
    sta CXS_DY,x
    cmp CXS_MNDY
    bcs :+
    sta CXS_MNDY
:   lda CXS_DY,x
    cmp CXS_MXDY
    bcc :+
    sta CXS_MXDY
:   lda do_yflip
    asl
    ora do_flip
    sta CXS_FL,x
    inc CXS_N
    iny
    jmp @walk
@stash_over:
    lda #5                       ; too many tiles: w6_cx bails to plain
    sta CXS_N
    iny
    jmp @walk
@done:
    rts
.endproc

.segment "W3X2"
; ---------------------------------------------------------------------------
; w6_frame (docs/42 v2): once per display frame -- fold every stash entry by
; the DMA shift (fb_col0 delta -> ring bytes) and mark entries whose owner is
; dead or invisible as DYING (the composer erases them: bg + the others).
.proc w6_frame
    lda frame_count
    cmp CX_STAMP
    bne :+
    rts
:   sta CX_STAMP
    lda fb_col0
    sec
    sbc CX_FB
    sta CXS_T2                   ; tile cols scrolled (0 normally, 2 per shift)
    lda fb_col0
    sta CX_FB
    ldx #9
@e: jsr cs_entryx                ; tmpL2 -> entry X
    lda (tmpL2)
    beq @n
    and #$0F                     ; sanity: nt 1..4 and cols/rows 1..3 (garbage
    cmp #5                       ; would send the composer over 255x255 cells)
    bcs @bad
    ldy #3
    lda (tmpL2),y
    beq @bad
    cmp #4
    bcs @bad
    iny
    lda (tmpL2),y
    beq @bad
    cmp #4
    bcc :+
@bad:
    lda #0
    sta (tmpL2)
    bra @n
:   lda CXS_T2
    beq @alive
    asl                          ; -> ring bytes
    sta CXS_T3
    ldy #1
    lda (tmpL2),y
    sec
    sbc CXS_T3
    sta (tmpL2),y                ; a box scrolled off fails the <48 guard
@alive:
    lda o_type,x
    cmp #OBJ_W3
    bne @die
    lda o_nfl,x
    and #2                       ; visible this frame?
    bne @n
@die:
    lda (tmpL2)
    ora #$80
    sta (tmpL2)
    lda #1
    sta CX_DYING
    phx                          ; the cleanup compose needs this box's map
    ldy #3                       ; columns cache-hot (bank 6 is mapped here);
    lda (tmpL2),y                ; a miss would paint sky over the background
    beq @pop
    tax
    ldy #1
    lda (tmpL2),y
    jsr w6_touch                 ; (A = dcol0, X = cols)
@pop:
    plx
@n: dex
    bpl @e
    rts
.endproc

; cs_entryx: tmpL2 -> entry X (X preserved)
.proc cs_entryx
    phx
    stx CXS_T3
    txa
    cmp #7
    bcc :+
    sbc #7
    ldx #<CS_B
    ldy #>CS_B
    bra @m
:   ldx #<CS_A
    ldy #>CS_A
@m: stx tmpL2
    sty tmpH2
    asl
    asl
    sta tmpL3
    asl
    asl
    clc
    adc tmpL3
    clc
    adc tmpL2
    sta tmpL2
    bcc :+
    inc tmpH2
:   plx
    rts
.endproc

.segment "W3X2"
; w6_cx: stash-walk the current object; decide composed vs plain.
; C=1: the entry holds the NEW state, CXA_* the new+old boxes, the map
;      columns are cache-hot -> aux_group composes.
; C=0: plain draw (any previous entry of ours was marked dying).
.proc w6_cx
    lda #1
    sta CXS_MODE
    stz CXS_N
    stz CXS_BOXOK
    jsr w6_draw                  ; the walk in STASH mode (fills CXS_*)
    ldx oi
    jsr cs_entryx
    lda CXS_N
    beq @pj
    cmp #5
    bcs @pj                  ; >4 tiles: plain
    ; --- old box (for the union) ---
    lda (tmpL2)
    and #$7F
    beq @noold
    ldy #1
    lda (tmpL2),y
    sta CXA_ODCOL0
    iny
    lda (tmpL2),y
    sta CXA_ODY0
    iny
    lda (tmpL2),y
    sta CXA_OCOLS
    iny
    lda (tmpL2),y
    sta CXA_OROWS
    bra @box
@noold:
    stz CXA_OCOLS
    bra @box
@pj:
    jmp w6_cx_tail
@box:
    ; --- y box ---
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta CXS_BASE
    clc
    adc CXS_MNDY
    sec
    sbc #64
    cmp #16
    bcc @pj
    and #$F8
    sta CXA_DY0
    lda CXS_BASE
    clc
    adc CXS_MXDY
    sec
    sbc #56
    cmp #161
    bcs @pj
    sec
    sbc CXA_DY0
    clc
    adc #7
    lsr
    lsr
    lsr
    sta CXA_ROWS
    cmp #4
    bcs @pj
    ; --- x box ---
    lda spr_col
    sta CXS_SPRC
    clc
    adc CXS_MNDC
    sec
    sbc #64
    bmi @pj
    and #$FE
    sta CXA_DCOL0
    lda CXS_SPRC
    clc
    adc CXS_MXDC
    sec
    sbc #64
    asl
    asl
    clc
    adc spr_subx
    clc
    adc #8
    sta CXS_T0
    lda CXA_DCOL0
    asl
    asl
    sta CXS_T1
    lda CXS_T0
    sec
    sbc CXS_T1
    clc
    adc #7
    lsr
    lsr
    lsr
    sta CXA_COLS
    cmp #4
    bcs @pj2
    asl                          ; right margin: the stream/blank strip
    clc
    adc CXA_DCOL0
    cmp #41
    bcs @pj2
    inc CXS_BOXOK                ; the box is valid from here on
    bra @pn0
@pj2:
    jmp w6_cx_tail
@pn0:
    ; (plain-path W3 neighbours are stashed as OVERLAY-ONLY entries -- bit6 --
    ;  so a compose paints them instead of bailing; docs/42 v2)
    ; --- unchanged since the last compose? then skip it (docs/42 v2 cost):
    ;     a still object recomposing 9-12 cells every frame froze the crowd
    ;     zone (logic 451 -> 16). Recompose anyway if a plain-path image or
    ;     Mario's OLD image (both erased through restore_bg) touched our box.
    stz CXA_SKIP
    bra @eo0
@fillJ:
    jmp @fill
@eo0:
    lda (tmpL2)
    and #$7F
    cmp CXS_N
    bne @fillJ
    ldy #1
    lda (tmpL2),y
    cmp CXA_DCOL0
    bne @fillJ
    iny
    lda (tmpL2),y
    cmp CXA_DY0
    bne @fillJ
    ldx #0                       ; tiles: ids + offsets
@cmp:
    cpx CXS_N
    beq @same
    txa
    clc
    adc #5
    tay
    lda (tmpL2),y
    cmp CXS_ID,x
    bne @fillJ
    lda CXS_SPRC
    clc
    adc CXS_DC,x
    sec
    sbc #64
    asl
    asl
    clc
    adc spr_subx
    sta CXS_T0
    lda CXA_DCOL0
    asl
    asl
    sta CXS_T2
    lda CXS_T0
    sec
    sbc CXS_T2
    sta CXS_T0
    txa
    clc
    adc #9
    tay
    lda (tmpL2),y
    cmp CXS_T0
    bne @fillK
    lda CXS_BASE
    clc
    adc CXS_DY,x
    sec
    sbc #64
    sec
    sbc CXA_DY0
    sta CXS_T0
    txa
    clc
    adc #13
    tay
    lda (tmpL2),y
    cmp CXS_T0
    bne @fill
    inx
    bra @cmp
    bra @same
@fillK:
    jmp @fill
@same:
    ; foreign old images near our box? (plain W3/engine sprites, Mario)
    ldx oi
    ldy #9
@fo:
    cpy oi
    beq @fon
    lda o_type,y
    beq @fon
    lda o_pdr,y                  ; drawn by the OLD path (composed hold 0)
    beq @fon
    lda o_pvy,y                  ; (leaked o_pdr on a composed one: parked $F0)
    cmp #$F0
    beq @fon
    lda o_pvx,y
    sec
    sbc o_nvx,x
    bcs :+
    eor #$FF
    ina
:   cmp #40
    bcs @fon
    lda o_pvy,y
    sec
    sbc o_ndy,x
    bcs :+
    eor #$FF
    ina
:   cmp #40
    bcc @fillK
@fon:
    dey
    bpl @fo
    lda prev_vx                  ; Mario's old image (erased this frame)
    sec
    sbc o_nvx,x
    bcs :+
    eor #$FF
    ina
:   cmp #40
    bcs @mfar
    lda prev_y
    sec
    sbc o_ndy,x
    bcs :+
    eor #$FF
    ina
:   cmp #48
    bcc @fillK
@mfar:
    lda #1
    sta CXA_SKIP                 ; identical + untouched: nothing to do
    lda oi
    sta CXA_SLOT
    sec
    rts
@fill:
    jsr w6_fill
    lda oi
    sta CXA_SLOT
    ; --- pre-touch the map columns of new+old boxes (bank 6 is mapped) ---
    lda CXA_DCOL0
    ldx CXA_COLS
    jsr w6_touch
    lda CXA_OCOLS
    beq :+
    tax
    lda CXA_ODCOL0
    jsr w6_touch
:   sec
    rts
.endproc

; w6_fill: write the entry (tmpL2) from CXS_* + CXA_* (box + tiles + flags)
.proc w6_fill
    lda CXS_N
    sta (tmpL2)
    ldy #1
    lda CXA_DCOL0
    sta (tmpL2),y
    iny
    lda CXA_DY0
    sta (tmpL2),y
    iny
    lda CXA_COLS
    sta (tmpL2),y
    iny
    lda CXA_ROWS
    sta (tmpL2),y
    lda CXA_DCOL0
    asl
    asl
    sta CXS_T1                   ; box left px
    stz CXS_T3                   ; packed flags
    ldx #0
@ft:
    cpx CXS_N
    beq @fdone
    lda CXS_ID,x
    ldy #5
    jsr @sty_x
    lda CXS_SPRC                 ; tx = (spr_col+dc)*4 + subx - left
    clc
    adc CXS_DC,x
    sec
    sbc #64
    asl
    asl
    clc
    adc spr_subx
    sec
    sbc CXS_T1
    ldy #9
    jsr @sty_x
    lda CXS_BASE                 ; ty = base + dy - 64 - dy0
    clc
    adc CXS_DY,x
    sec
    sbc #64
    sec
    sbc CXA_DY0
    ldy #13
    jsr @sty_x
    lda CXS_FL,x                 ; pack 2 bits at position x*2
    and #3
    phx
:   cpx #0
    beq :+
    asl
    asl
    dex
    bra :-
:   plx
    ora CXS_T3
    sta CXS_T3
    inx
    bra @ft
@sty_x:                          ; store A at entry[Y + X]
    sta CXS_T0
    tya
    sta CXS_T2
    txa
    clc
    adc CXS_T2
    tay
    lda CXS_T0
    sta (tmpL2),y
    rts
@fdone:
    lda CXS_T3
    ldy #17
    sta (tmpL2),y
    rts
.endproc

.proc w6_cx_tail                 ; (the bail paths of w6_cx, split for range)
@plainJ:
    lda (tmpL2)                  ; we had a COMPOSED image: clean it up first
    beq @pfill
    and #$40
    bne @pfill                   ; (was overlay-only already)
    lda (tmpL2)
    ora #$80
    sta (tmpL2)
    lda #1
    sta CX_DYING
    clc                          ; this frame: plain draw after the sweep; the
    rts                          ; overlay-only entry is filled next frame
@pfill:
    lda CXS_BOXOK                ; PLAIN this frame: record the tiles as an
    beq @pnone                   ; OVERLAY-ONLY entry (bit6) so composed
    lda CXS_N                    ; neighbours paint us instead of bailing --
    beq @pnone                   ; ONLY when the box was computed (a bail before
    cmp #5                       ; it leaves stale CXA_* -> a garbage box ->
    bcs @pnone                   ; the composer over 255x255 cells = the user's
    jsr w6_fill                  ; FREEZE) and never for BEHIND-tile objects
    lda (tmpL2)                  ; (the cannon painted over its pipe, user-caught)
    ora #$40
    sta (tmpL2)
    clc
    rts
@pnone:
    lda #0
    sta (tmpL2)
    clc
    rts
.endproc

.segment "W3X2"
; w6_touch: make the column cache hot for X cells starting at ring byte A
; (world col = fb_col0 + dcol/2). Duplicates w3_read's miss path WITHOUT the
; bank dance -- bank 6 is mapped here.
.proc w6_touch
    lsr
    clc
    adc fb_col0
    sta feet_col
    lda fb_col0+1
    adc #0
    sta feet_col+1
@col:
    phx
    lda feet_col
    and #W3CSLOTS-1
    asl
    tax
    lda W3CTAG,x
    cmp feet_col
    bne @miss
    lda W3CTAG+1,x
    cmp feet_col+1
    beq @hit
@miss:
    lda feet_col
    sta W3CTAG,x
    lda feet_col+1
    sta W3CTAG+1,x
    txa
    asl
    asl
    asl
    sta tmpL3
    lda #>W3CDATA
    sta tmpH3
    lda feet_col                 ; map_ptr = map_base + col*2
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
    lda (map_ptr)
    tax
    ldy #1
    lda (map_ptr),y
    sta map_ptr+1
    stx map_ptr
    ldy #15                      ; destination = tmpL2/tmpH2 (w3_read's slot
:   lda (map_ptr),y              ; pointer). NOT tmpL3: callers of the map probe
    sta (tmpL2),y                ; keep live values there (see w2code.s w3_read)
    dey
    bpl :-
@hit:
    plx
    inc feet_col
    bne :+
    inc feet_col+1
:   dex
    bne @col
    rts
.endproc
.segment "W2C"
