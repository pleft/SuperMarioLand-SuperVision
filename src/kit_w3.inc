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
.include "w3data.inc"            ; generated: typetab/scripts/phys/display lists

W3SCRB   = $B000                 ; bank 6 pins (pack_banks writes all three):
W3DLB    = $B520                 ;   scripts / metasprite display lists /
W3TILB   = $B780                 ;   the compact W3 tile slice
W3SYSC   = $2026
W3FLG    = $0B                   ; NMI | TIMER_IRQ | LCD (load_level's mask)

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

.proc w3_init                    ; X = slot: a fresh VM context
    stz w3_pc,x
    stz o_tmr,x                  ; wait 0 -> the first step fetches
    stz o_hp,x                   ; divider 0 -> a tick every frame until F4
    stz o_vx,x
    stz o_vy,x
    stz o_st,x
    rts
.endproc

; --- one frame of VM for slot X -------------------------------------------
.proc w3_step
    lda o_tmr,x                  ; wait == 0 -> run opcodes until one waits
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
    bcs @ystep
    dec o_xh,x
    bra @ystep
@right:
    lda o_xl,x
    clc
    adc tmpH3
    sta o_xl,x
    bcc @ystep
    inc o_xh,x
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
:   bra @loop                    ; F1 child / F9 sfx / FA: not yet
.endproc

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
    lda #(6 << 5) | W3FLG
    sta W3SYSC
    ldy #0
    lda (tmpL),y
    tay
    lda #(1 << 5) | W3FLG        ; back to the W3 resident bank
    sta W3SYSC
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
@flip:
    lda tmpL3
    and #$0C                     ; bits3-2: XOR-flip the direction bits
    beq @forcey
    lsr
    lsr
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
    jmp w3_init
.endproc
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

; --- contact: the GB's own rules. $3186 column +0 is the STOMP result: $00
; means "not stompable" and the shared l3_hurt already models that exactly
; (side contact hurts; landing on it does NOTHING and Mario keeps falling --
; the GB's stone-head zone). A non-zero column morphs the slot into that type,
; which is just another VM script (the kill/puff chains are types too).
.segment "W2FAR"
.proc w3_touch                   ; the shared helpers CLOBBER X: reload it from oi
    jsr l3_cull                  ; after every call (the kit-wide convention)
    bcs @rts
    jsr l3_box
    ldx oi
    bcc @rts
    ldy w3_ti,x
    lda w3_stomp,y
    beq @hurt                    ; not stompable
    sta tmpL2
    jsr l3_above                 ; Mario coming down onto it?
    ldx oi
    bcc @hurt
    lda tmpL2                    ; -> the GB's stomp morph, run by the VM
    sta tmpL3
    jsr w3_morph
    ldx oi
    lda #1                       ; Mario's fixed stomp bounce
    sta jump_state
    lda #14
    sta arc_idx
    stz fall_v
    stz ride
    ldx oi
    ldy w3_ti,x                  ; score class = phys byte2 >> 6 (0:100 1:400 2:800)
    lda w3_phys2,y
    rol
    rol
    rol
    and #3
    tay
    lda @val,y
    jmp award_stomp
@val: .byte $01, $04, $08, $10
@hurt:
    jmp l3_hurt
@rts:
    rts
.endproc
.segment "W2C"

; --- draw: walk the GB metasprite display list ----------------------------
; control byte: bit3 y-8, bit2 y+8, bit1 x-8, bit0 x+8, bit4 -> x-flip;
; tile bytes have bit7 set. Tiles $A0-$DC resolve through the level header's
; overlay base (the W3 sheet in bank 6), everything else through chardata --
; draw_quad already does exactly that, so GB tile ids ship verbatim.
.proc w3_draw
    lda o_st,x                   ; param -> display-list index
    ldy #W3_NPARAM-1
:   cmp w3_paramtab,y
    beq @found
    dey
    bpl :-
    rts
@found:
    lda o_vy,x                   ; bit0 = moving right -> the RIGHT list
    and #$01
    beq @left
    lda w3_dlo,y
    sta tmpL
    lda w3_dhi,y
    bra @have
@left:
    lda w3_dloL,y
    sta tmpL
    lda w3_dhiL,y
@have:
    sta tmpH
    stz tmpL2                    ; dy accumulator
    stz tmpH2                    ; dcol accumulator (bytes)
    stz do_flip
    lda #(6 << 5) | W3FLG        ; the lists AND the tile sheet live in bank 6;
    sta W3SYSC                   ; every routine the walk calls is FIXED/RAM,
    ldy #0                       ; so one map around the whole draw is safe
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
    bra @next
:   stz do_flip
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
    lda #(1 << 5) | W3FLG        ; back to the W3 resident bank
    sta W3SYSC
    stz do_flip
    rts
.endproc
