; hwtest8: the PORT's exact boot shape -- bank-6 one-shot init + real IRQs + stripes
.segment "ZEROPAGE"
ptr: .res 2
frame_flag: .res 1

.segment "BOOT6"                 ; lives in bank 6, runs at $8000+
boot6_init:
    lda #0                       ; ZP clear (like the port)
    tax
:   sta $00,x
    inx
    bne :-
    lda #$A0                     ; LCD regs from bank 6 (the port does this too)
    sta $2000
    lda #$A0
    sta $2001
    stz $2002
    stz $2003
    lda #$0F
    sta $2022
    rts

.segment "CODE"
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #(6 << 5)                ; map bank 6, display/ints off -- SML's exact move
    sta $2026
    jsr boot6_init               ; runs from the $8000 window
    lda #$0B                     ; bank 0 + NMI + timer IRQ + LCD
    sta $2026
    stz ptr
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
    cli
@forever:
    jmp @forever

nmi:
    pha
    inc frame_flag
    stz $2002
    lda #16
    sta $2023
    pla
    rti
irq:
    pha
    lda #0
    sta $2002
    lda $2024
    pla
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
