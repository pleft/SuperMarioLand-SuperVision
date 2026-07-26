; hwtest13 (v2): raster split via the SYS_CTRL LCD-restart trick.
; REAL-HW FACTS (GrenderG notes): NMI = 61.04 Hz free-running, LCD field =
; 39360 cyc (246 cyc/line, ~50.8 Hz) -- UNSYNCED. But any SYS_CTRL write
; resets the LCD scan to the top-left. So: NMI rewrites SYS_CTRL (restart),
; sets XSCROLL=0 (HUD), arms the timer (tick = 256 cyc, /256 prescale);
; IRQ toggles: at T1 -> XSCROLL=16 + arm T2=138 (end of visible field);
; then -> XSCROLL=0 + arm T1 again (field 2's HUD rows render unscrolled).
; Canvas: rows 0-15 gray + T1 bar; playfield = 8px stripes with a BLACK
; LEFT-EDGE ANCHOR (bytes 0-1): rows where XSCROLL=16 hide the anchor.
;   -> stable black left edge on the HUD band only, stripes shifted below,
;      shear steady at one stripe below the band = SPLIT WORKS.
; Buttons: UP/DOWN T1 +/- 8, RIGHT/LEFT T1 +/- 1 (bar length = T1 px).
.segment "ZEROPAGE"
ptr:  .res 2
prev: .res 1
cur:  .res 1
tval: .res 1
tog:  .res 1

IRQ_TIMER     = $2023
IRQ_TIMER_RST = $2024
T2 = 138                         ; (160-16) lines * 246/256

.segment "CODE"

canvas:
    stz ptr                      ; HUD rows 0..15 = $55
    lda #$40
    sta ptr+1
    ldx #3
    ldy #0
    lda #$55
@h: sta (ptr),y
    iny
    bne @h
    inc ptr+1
    dex
    bne @h
    ldx #144                     ; playfield rows 16..159
@line:
    ldy #0
@col:
    cpy #2
    bcs @str
    lda #$FF                     ; bytes 0-1: the left-edge anchor (8px black)
    bra @put
@str:
    tya
    lsr
    and #1
    beq :+
    lda #$FF
    bra @put
:   lda #$00
@put:
    sta (ptr),y
    iny
    cpy #48
    bne @col
    lda ptr
    clc
    adc #48
    sta ptr
    bcc :+
    inc ptr+1
:   dex
    bne @line
    rts

drawbar:
    lda #<($4000+4*48)
    sta ptr
    lda #>($4000+4*48)
    sta ptr+1
    ldx #8
@row:
    lda tval
    lsr
    lsr
    cmp #48
    bcc :+
    lda #47
:   sta cur
    ldy #0
@b: cpy cur
    bcs @gray
    lda #$FF
    bra @put
@gray:
    lda #$55
@put:
    sta (ptr),y
    iny
    cpy #48
    bne @b
    lda ptr
    clc
    adc #48
    sta ptr
    bcc :+
    inc ptr+1
:   dex
    bne @row
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
    lda #15                      ; 16 lines * 246/256 = 15.4
    sta tval
    jsr drawbar
    stz prev
    stz tog
    lda #$0B                     ; the game's runtime config (prescale /256)
    sta $2026
    cli
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
    and #$08
    beq :+
    lda tval
    clc
    adc #8
    sta tval
:   txa
    and #$04
    beq :+
    lda tval
    sec
    sbc #8
    sta tval
:   txa
    and #$01
    beq :+
    inc tval
:   txa
    and #$02
    beq :+
    dec tval
:   txa
    beq :+
    jsr drawbar
:   ldy #0
@d: dey
    bne @d
    jmp main

nmi:
    pha
    lda #$0B
    sta $2026                    ; LCD RESTART: scan re-begins top-left NOW
    stz $2002                    ; HUD rows render unscrolled
    lda tval
    sta IRQ_TIMER                ; IRQ at ~line 16
    stz tog                      ; next IRQ = "enter playfield"
    pla
    rti
irq:
    pha
    lda tog
    bne @tohud
    lda #16
    sta $2002                    ; playfield: scrolled
    lda #T2
    sta IRQ_TIMER                ; fire again at the visible field's end
    lda #1
    sta tog
    bra @ack
@tohud:
    stz $2002                    ; field 2 begins: HUD rows unscrolled again
    lda tval
    sta IRQ_TIMER
    stz tog
@ack:
    lda IRQ_TIMER_RST
    pla
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
