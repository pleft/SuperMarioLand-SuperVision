; hwtest3: 64K image; byte-faithful mimicry of Block Buster's boot sequence
; (reset @ $C000 of the original), then stripe-fill the framebuffer.
.segment "ZEROPAGE"
ptr: .res 2

.segment "CODE"
reset:
    ldx #$FF                     ; BB order exactly: ldx/txs/cld
    txs
    cld
    lda #$80
    sta $0013
    lda #$A0
    sta $2000                    ; LCD_XSIZE
    lda #$A0
    sta $2001                    ; LCD_YSIZE
    lda #$00
    sta $0016
    sta $2002                    ; XSCROLL
    lda #$00
    sta $0017
    sta $2003                    ; YSCROLL
    lda #$0B
    sta $2026                    ; SYS_CTRL = the PORT's boot value (bisect probe)
    lda #$0F
    sta $2022
    lda #$00                     ; BB's $D8A7: silence every sound register
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
    stz ptr                      ; stripes into the framebuffer
    lda #$40
    sta ptr+1
    ldy #0
    lda #$1B
@fill:
    sta (ptr),y
    iny
    bne @fill
    inc ptr+1
    ldx ptr+1
    cpx #$60
    bne @fill
    cli                          ; BB enables interrupts before its main loop
@forever:
    jmp @forever

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
