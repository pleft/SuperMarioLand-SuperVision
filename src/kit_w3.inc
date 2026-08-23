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
.include "w3data.inc"
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
W3SCRB   = $B200                 ; bank 6 pins (pack_banks writes all three):
W3DLB    = $B540                 ;   scripts / metasprite display lists /
W3TILB   = $B740                 ;   the compact W3 tile slice
W3SYSC   = $2026
W3LINK   = $2021                 ; MAGNUM page (docs/37): banking here does
W3LINKV  = $2022                 ;   NOT restart the LCD scan. $2022 must read
                                 ;   0 at the $2021 write; $0F is the panel's
                                 ;   drive value, handed straight back.
W3FLG    = $0B                   ; NMI | TIMER_IRQ | LCD (load_level's mask)

; --- the save-under composer (docs/42; MUST match src/w3aux.s) -------------
CX_CTX     = $1C60               ; the context: +0 act +1 dcol0 +2 dy0 +3 cols
                                 ; +4 rows +5 fb_col0 snapshot +8 saved[144]
CX_OWN     = $1FE0               ; composing slot + 1 (0 = free)
CX_EN      = $1FE1               ; nonzero = the composer is enabled (init: 0)
CX_TILES   = $1FA0               ; 4 x 16B final tile pixels
CXA_DCOL0  = $01C6               ; the aux ABI block (w3aux.s AXV_*)
CXA_DY0    = $01C7
CXA_COLS   = $01C8
CXA_ROWS   = $01C9
CXA_NT     = $01CA
CXA_TX     = $01CB
CXA_TY     = $01CF
CXA_REL    = $01E5               ; dispatch: uncompose before the plain draw
; stash scratch (SCRATCH area, consumed before aux_compose reuses it)
CXS_ID     = $0136               ; 4B tile ids
CXS_DC     = $013A               ; 4B dcol offsets (biased +64)
CXS_DY     = $013E               ; 4B dy offsets (biased +64)
CXS_FL     = $0142               ; 4B flip bits (1=x, 2=y)
CXS_N      = $0146
CXS_MNDC   = $0147               ; biased mins/maxes
CXS_MXDC   = $0148
CXS_MNDY   = $0149
CXS_MXDY   = $014A
CXS_T0     = $014B
CXS_T1     = $014C
CXS_XF     = $014D               ; current control flip bits
CXS_BASE   = $014E               ; dy_base = o_y + 8
CXS_SPRC   = $014F               ; spr_col copy
CXS_T2     = $0150
CXS_T3     = $0151
CXS_T4     = $0152

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
    lda CX_OWN                   ; a COMPOSED object holds o_pdr=0 so pass 3a
    beq :+                       ; never erases it mid-frame -- but p4_one sets
    dea                          ; o_pdr=1 after every draw; clear it again in
    cmp oi                       ; the update phase (runs after the render in
    bne :+                       ; the same loop iteration, docs/42)
    ldx oi
    stz o_pdr,x
:   jsr w3_ffc7                  ; the GB's PER-FRAME ffc7 physics (below)
    ldx oi
    lda o_type,x                 ; gravity may have culled the slot
    cmp #OBJ_W3
    beq :+
    rts
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
    beq @ystep
    sta tmpH3
    lda o_vy,x
    and #$01
    bne @right
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
    lda o_xl,x
    clc
    adc tmpH3
    sta o_xl,x
    bcc :+
    inc o_xh,x
:   jsr w3_carry_rt
    ldx oi
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
    lda o_y,x                    ; rising
    sec
    sbc tmpH3
    sta o_y,x
    rts
@fall:
    jsr w3_floor                 ; solid under it? (GB Call_000_2bbb)
    bcc @fmove
    ldy w3_ti,x                  ; blocked: the response is the type's phys
    lda w3_phys0,y               ; byte 0 (ffc7) & $30 -- $00 pass through,
    and #$30                     ; $10 land (stop falling), $30 RESTART the
    beq @fmove                   ; script (Batadon's hop loop)
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
    jsr w3_spawn_at              ; engine: a slot at the parent's exact position
    bcs @none
    jsr w3_morph                 ; kit: the type lookup + a fresh VM context
@none:
    ldx oi                       ; the VM loop runs on the PARENT's slot
    rts
.endproc

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
    lda #1
    sta o_tmr,x
    rts
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
:   bra @loop                    ; F9 sfx / FA: not yet
.endproc
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
    lda #6
    sta W3LINK
    lda #$0F
    sta W3LINKV
    ldy #0
    lda (tmpL),y
    tay
    stz W3LINKV        ; back to the W3 resident bank
    lda #1
    sta W3LINK
    lda #$0F
    sta W3LINKV
    tya
    rts
.endproc

; --- F0: direction control (disasm $2711-$2789) ---------------------------
.segment "W2FAR"
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
@flip:                           ; bits3-2 XOR-flip the direction bits, but bit2
    lda tmpL3                    ; flips Y and bit3 flips X -- not the other way.
    and #$04                     ; GB-measured: $0D (the stomp corpse, F0 $64)
    lsr                          ; FALLS, while $49 (F0 $20, bit2 clear) rises.
    sta tmpH2                    ; With them swapped the corpse flew UPWARD off
    lda tmpL3                    ; the screen and never despawned, so stomped
    and #$08                     ; enemies piled up until the pool was full.
    lsr
    lsr
    lsr
    ora tmpH2
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

.segment "W2FAR"
.segment "W2C"

; --- terrain probes (the port's own tile semantics) -----------------------
.proc w3_floor                   ; C=1 when the tile under the object is SOLID
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
    phx
    jsr read_solid               ; A = 1 solid / 0 open
    plx
    lsr                          ; -> C
    rts
.endproc

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
    bcs @setride                 ; but carry Mario on top). RIDE BOOKKEEPING:
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
    ldy w3_ti,x
    lda w3_stomp,y
    beq @side                    ; not stompable -> the SIDE column decides, and it
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
.proc w3_bank                    ; A = MAGNUM page (the W3LINK dance)
    stz W3LINKV
    sta W3LINK
    lda #$0F
    sta W3LINKV
    rts
.endproc

.proc w3_draw                    ; WINDOW half: bank juggling + the composed
    stz CXA_REL                  ; dispatch (docs/42). The walk and the stash
    lda #6                       ; are BANK-6-RESIDENT (W3X); the composer is
    jsr w3_bank                  ; PAGE-8-RESIDENT (w3aux).
    lda CX_EN                    ; COMPOSE DISABLED BY DEFAULT (docs/42): one
    beq @plain                   ; context protects one rarely-watched object
    jsr w6_elig                  ; while the claim/release churn among
    bcs @comp                    ; overlapping rollers costs ~45 logic frames
                                 ; in the tokotoko zone (user-caught: "no
                                 ; improvement + slowdown"). The machinery
                                 ; stays for the group-compose evolution;
                                 ; set CX_EN nonzero to re-enable.
    lda CXA_REL                  ; we owned a context and lost eligibility:
    beq @plain                   ; write its saved bg back first, then draw
    lda #8                       ; the old way
    jsr w3_bank
    jsr aux_uncompose
    lda #6
    jsr w3_bank
@plain:
    jsr w6_draw
    bra @done
@comp:
    lda #8
    jsr w3_bank
    jsr aux_compose
@done:
    stz do_yflip                 ; never leak the flips into engine draws
    stz do_flip
    lda #1
    jmp w3_bank                  ; tail: back to the resident bank
.endproc

.segment "W3X"
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
    beq @done
    bmi @tile
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
    bra @walk
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; w6_elig (docs/42): decide composed vs plain for the current W3 object and,
; when composed, STASH everything the page-8 composer needs (the AXV box +
; final tile pixels). BANK-6-resident: reads the display tables freely.
; Out: C=1 stashed (tmpL -> the context, CX_OWN claimed);
;      C=0 plain draw (CXA_REL set if an owned active context must be
;      written back first).
.proc w6_elig
    ; ---- ownership screen ----
    lda CX_OWN
    beq @scan                    ; free
    dea
    cmp oi
    beq @scan                    ; ours
    tay                          ; someone else's: alive?
    lda o_type,y
    cmp #OBJ_W3
    bne :+
    jmp @no                      ; a live owner keeps it -> plain draw
:   stz CX_CTX                   ; dead owner: steal, no writeback (its image
    stz CX_OWN                   ; was erased by the leftover pass or is gone
    bra @scan                    ; off-screen -- docs/42)
@scan:
    ; ---- overlap screen: any live slot or Mario near? -> plain ----
    ldx oi
    lda o_nvx,x
    sta CXS_T0
    lda o_ndy,x
    sta CXS_T1
    ldy #9
@ov:
    cpy oi
    beq @ovn
    lda o_type,y
    beq @ovn
    lda o_nvx,y
    sec
    sbc CXS_T0
    bcs :+
    eor #$FF
    ina
:   cmp #40
    bcs @ovn
    lda o_ndy,y
    sec
    sbc CXS_T1
    bcs :+
    eor #$FF
    ina
:   cmp #40
    bcs @ovn
    jmp @no
@ovn:
    dey
    bpl @ov
    lda spr_x                    ; Mario
    clc
    adc scroll_s
    sec
    sbc CXS_T0
    bcs :+
    eor #$FF
    ina
:   cmp #40
    bcs @mok
    lda spr_y
    sec
    sbc CXS_T1
    bcs :+
    eor #$FF
    ina
:   cmp #48
    bcs @mok
    jmp @no
@mok:
    ; ---- param -> display list ----
    ldx oi
    lda o_st,x
    ldy #W3_NPARAM-1
:   cmp w3_paramtab,y
    beq @pf
    dey
    bpl :-
    jmp @no
@pf:
    lda w3_dlo,y
    sta tmpL
    lda w3_dhi,y
    sta tmpH
    ldy #0
    ldx oi                       ; facing left? skip the RIGHT list
    lda o_vy,x
    and #$01
    bne @ps
:   lda (tmpL),y
    iny
    cmp #$FF
    bne :-
@ps:
    ; ---- prescan: accumulate offsets, collect tiles, min/max ----
    stz CXS_N
    stz CXS_XF
    lda #64
    sta CXS_T0                   ; dy accumulator (biased +64)
    sta CXS_T1                   ; dc accumulator (biased +64)
    lda #255
    sta CXS_MNDC
    sta CXS_MNDY
    stz CXS_MXDC
    stz CXS_MXDY
@pw:
    lda (tmpL),y
    cmp #$FF
    bne :+
    jmp @pbox
:   bmi @ptile
    pha                          ; a CONTROL byte
    and #$08
    beq :+
    lda CXS_T0
    sec
    sbc #8
    sta CXS_T0
:   pla
    pha
    and #$04
    beq :+
    lda CXS_T0
    clc
    adc #8
    sta CXS_T0
:   pla
    pha
    and #$02
    beq :+
    dec CXS_T1
    dec CXS_T1
:   pla
    pha
    and #$01
    beq :+
    inc CXS_T1
    inc CXS_T1
:   pla
    and #$30                     ; bit4 x-flip, bit5 y-flip -> bits 0/1
    lsr
    lsr
    lsr
    lsr
    sta CXS_XF
    iny
    bra @pw
@ptile:
    ldx CXS_N
    cpx #4
    beq @noJ                     ; more than one quad -> plain
    cmp #$EE                     ; the BEHIND-capable tiles keep the old path
    beq @noJ                     ; (their skip rule samples live VRAM)
    cmp #$87
    bcc :+
    cmp #$89
    bcc @noJ
:   cmp #$92
    bcc :+
    cmp #$96
    bcc @noJ
:   sta CXS_ID,x
    lda CXS_T1
    sta CXS_DC,x
    cmp CXS_MNDC
    bcs :+
    sta CXS_MNDC
:   lda CXS_T1
    cmp CXS_MXDC
    bcc :+
    sta CXS_MXDC
:   lda CXS_T0
    sta CXS_DY,x
    cmp CXS_MNDY
    bcs :+
    sta CXS_MNDY
:   lda CXS_T0
    cmp CXS_MXDY
    bcc :+
    sta CXS_MXDY
:   lda CXS_XF
    sta CXS_FL,x
    inc CXS_N
    iny
    jmp @pw
@noJ:
    jmp @no
@pbox:
    lda CXS_N
    beq @noJ
    ; ---- the y box ----
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta CXS_BASE                 ; dy_base
    clc
    adc CXS_MNDY
    sec
    sbc #64                      ; top scanline
    cmp #16
    bcc @noJ                     ; would touch the HUD rows
    and #$F8
    sta CXA_DY0
    lda CXS_BASE
    clc
    adc CXS_MXDY
    sec
    sbc #56                      ; bottom = base + maxdy - 64 + 8
    cmp #161
    bcs @noJ
    sec
    sbc CXA_DY0
    clc
    adc #7
    lsr
    lsr
    lsr
    sta CXA_ROWS
    cmp #4
    bcs @noJ
    ; ---- the x box ----
    lda spr_col
    sta CXS_SPRC
    clc
    adc CXS_MNDC
    sec
    sbc #64                      ; dcol_min (must be >= 0)
    bmi @noJ
    and #$FE
    sta CXA_DCOL0
    lda CXS_SPRC
    clc
    adc CXS_MXDC
    sec
    sbc #64
    asl
    asl                          ; *4 = px
    clc
    adc spr_subx
    clc
    adc #8                       ; right edge px
    sta CXS_T0
    lda CXA_DCOL0
    asl
    asl                          ; left edge px
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
    bcc :+
    jmp @no
:   asl                          ; right margin: dcol0 + cols*2 <= 40 keeps
    clc                          ; us clear of the stream/blank strip
    adc CXA_DCOL0
    cmp #41
    bcc :+
    jmp @no
:
    ; ---- claim + the missed-shift re-base ----
    lda CX_CTX
    bpl @claim
    lda fb_col0
    sec
    sbc CX_CTX+5                 ; tile cols scrolled since the last compose
    beq @claim
    cmp #7                       ; 1..6 = missed shift frames: re-base. Anything
    bcc @rebase                  ; else = a RESPAWN/WARP restream -- the saved
    stz CX_CTX                   ; bg is for another world region and an 8-bit
    bra @claim                   ; re-base can alias into valid columns: DROP
@rebase:                         ; the context (no writeback), save fresh.
    asl                          ; -> ring bytes
    sta CXS_T0
    lda CX_CTX+1
    sec
    sbc CXS_T0                   ; stale cells then fail the <48 guard: safe
    sta CX_CTX+1
@claim:
    lda fb_col0
    sta CX_CTX+5
    lda oi
    ina
    sta CX_OWN
    ; ---- AXV fill + the tile pixel copies ----
    lda CXS_N
    sta CXA_NT
    ldx #0
@ft:
    cpx CXS_N
    beq @fdone
    lda CXS_SPRC                 ; TX = (spr_col+dc)*4 + subx - dcol0*4
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
    sta CXS_T1
    lda CXS_T0
    sec
    sbc CXS_T1
    sta CXA_TX,x
    lda CXS_BASE                 ; TY = dy_base + dy - 64 - dy0
    clc
    adc CXS_DY,x
    sec
    sbc #64
    sec
    sbc CXA_DY0
    sta CXA_TY,x
    jsr w6_tile
    inx
    bra @ft
@fdone:
    lda #<CX_CTX
    sta tmpL
    lda #>CX_CTX
    sta tmpH
    sec
    rts
@no:
    lda CX_OWN                   ; bailing while owning an ACTIVE context:
    beq @no2                     ; release it and ask the dispatch to write
    dea                          ; the saved bg back before the plain draw
    cmp oi
    bne @no2
    stz CX_OWN
    lda CX_CTX
    bpl @no2
    lda #1
    sta CXA_REL
    lda #<CX_CTX
    sta tmpL
    lda #>CX_CTX
    sta tmpH
@no2:
    clc
    rts
.endproc

.segment "W3X2"
; w6_tile: X = tile index (preserved). Copy tile CXS_ID[x]'s 16 bytes with
; the flips CXS_FL[x] applied -> CX_TILES + x*16 (the composer wants FINAL
; pixels). Overlay ids $A0-$DC read the per-world sheet via hdr_buf+18.
.proc w6_tile
    phx
    lda CXS_ID,x
    sta CXS_T0
    lda CXS_FL,x
    sta CXS_T1
    txa
    asl
    asl
    asl
    asl
    sta CXS_T2                   ; dst base = x*16
    stz tmpH3                    ; src = id*16 + base
    lda CXS_T0
    asl
    rol tmpH3
    asl
    rol tmpH3
    asl
    rol tmpH3
    asl
    rol tmpH3
    sta tmpL3
    lda CXS_T0
    cmp #$A0
    bcc @char
    cmp #$DD
    bcs @char
    lda tmpL3
    clc
    adc hdr_buf+18
    sta tmpL3
    lda tmpH3
    adc hdr_buf+19
    bra @hi
@char:
    lda tmpL3
    clc
    adc #<chardata
    sta tmpL3
    lda tmpH3
    adc #>chardata
@hi:
    sta tmpH3
    ldx #0                       ; x = source row
@row:
    txa
    asl
    tay
    lda (tmpL3),y                ; b0
    sta CXS_T3
    iny
    lda (tmpL3),y                ; b1
    sta CXS_T4
    lda CXS_T1
    lsr                          ; bit0 = x-flip: swap + reverse pixels
    bcc @nxf
    ldy CXS_T4
    lda revpix,y
    pha
    ldy CXS_T3
    lda revpix,y
    sta CXS_T4
    pla
    sta CXS_T3
@nxf:
    txa                          ; dst row (bit1 = y-flip: 7-r)
    ldy CXS_T1
    cpy #2
    bcc @ny
    eor #$FF
    clc
    adc #8
@ny:
    asl
    clc
    adc CXS_T2
    tay
    lda CXS_T3
    sta CX_TILES,y
    lda CXS_T4
    sta CX_TILES+1,y
    inx
    cpx #8
    bne @row
    plx
    rts
.endproc
.segment "W2C"
