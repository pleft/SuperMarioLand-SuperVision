; hwtest14: does the REAL LCD scan wrap at $1FE0 (170 lines * 48, Potator's
; ring, proven for emulation by the SSSnake workaround) -- or at $2000, or
; not at all? Also: XSCROLL 1px smoothness and the YSCROLL*48 scan math.
; Ring canvas (VRAM lines 0..169):
;   lines   0- 15  gray  $55   (the "top marker")
;   lines  16-149  8px stripes
;   lines 150-169  solid black (the "ring tail")
;   bytes $1FE0-$1FFF (the 8160..8191 overhang) = $E4 4-shade noise:
;     IF THIS SHADE EVER APPEARS ON SCREEN the wrap is $2000, not $1FE0.
; Buttons: UP/DOWN = YSCROLL +/-1, RIGHT/LEFT = XSCROLL +/-1, START = both 0.
; Expected with $1FE0 wrap: YSCROLL=20 -> black tail enters from the bottom
; at YS=~... increasing YS walks the ring; past the tail the GRAY BAND and
; stripes REAPPEAR seamlessly (wrap!), never any 4-shade noise.
.segment "ZEROPAGE"
ptr:  .res 2
prev: .res 1
cur:  .res 1
xs:   .res 1
ys:   .res 1
lin:  .res 1

.segment "CODE"

canvas:
    stz ptr
    lda #$40
    sta ptr+1
    stz lin                      ; line counter 0..169
@line:
    lda lin
    cmp #16
    bcs :+
    lda #$55                     ; 0..15 gray
    bra @fill
:   cmp #150
    bcs :+
    lda #$FF                     ; 16..149 stripes (byte pattern set per col)
    bra @striped
:   lda #$FF                     ; 150..169 black
@fill:
    ldy #0
@f: sta (ptr),y
    iny
    cpy #48
    bne @f
    bra @next
@striped:
    ldy #0
@s: tya
    lsr
    and #1
    beq :+
    lda #$FF
    bra :++
:   lda #$00
:   sta (ptr),y
    iny
    cpy #48
    bne @s
@next:
    lda ptr
    clc
    adc #48
    sta ptr
    bcc :+
    inc ptr+1
:   inc lin
    lda lin
    cmp #170
    bne @line
    ldy #0                       ; the $1FE0..$1FFF overhang: 4-shade noise
    lda #$E4
:   sta $5FE0,y
    iny
    cpy #32
    bne :-
    rts

reset:
    ldx #$FF
    txs
    cld
    sei
    lda #$A0
    sta $2000
    lda #$A0
    sta $2001
    stz $2002
    stz $2003
    lda #$DF
    sta $2026
    lda #$0F
    sta $2022
    lda #$00
    sta $2010
    sta $2011
    sta $2012
    sta $2013
    sta $2014
    sta $2015
    sta $2016
    sta $2017
    sta $201C
    sta $201B
    sta $2028
    sta $2029
    sta $202A
    jsr canvas
    stz xs
    stz ys
    stz prev
main:
    lda $2020
    eor #$FF
    sta cur
    eor #$FF
    ora prev
    eor #$FF
    tax
    lda cur
    sta prev
    txa
    and #$08                     ; UP: YS+1
    beq :+
    inc ys
:   txa
    and #$04                     ; DOWN: YS-1
    beq :+
    dec ys
:   txa
    and #$01                     ; RIGHT: XS+1
    beq :+
    inc xs
:   txa
    and #$02                     ; LEFT: XS-1
    beq :+
    dec xs
:   txa
    and #$80                     ; START: reset
    beq :+
    stz xs
    stz ys
:   lda xs
    sta $2002
    lda ys
    sta $2003
    ldy #0
@d: dey
    bne @d
    jmp main

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
