; hwtest9: hwtest8 + SML's RAM-boot skeleton -- copy code from bank 6 to $1500,
; execute it THERE (fill stripes from RAM), return, continue. If this dies
; while hwtest8 lives, executing from $1500 RAM is the real-hw killer.
.segment "ZEROPAGE"
ptr: .res 2
frame_flag: .res 1

.segment "BOOT6"                 ; bank 6: the blob that will run at $1500
ramcode:
    lda #$A0
    sta $2000
    lda #$A0
    sta $2001
    stz $2002
    stz $2003
    lda #$0F
    sta $2022
    stz ptr                      ; stripe fill, executed FROM RAM
    lda #$40
    sta ptr+1
    ldy #0
    lda #$1B
@f: sta (ptr),y
    iny
    bne @f
    inc ptr+1
    ldx ptr+1
    cpx #$60
    bne @f
    rts
ramcode_end:

.segment "CODE"
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #(6 << 5)                ; bank 6, display off
    sta $2026
    ldy #0                       ; copy the blob to $1500 (one page is plenty)
:   lda $8000,y
    sta $1500,y
    iny
    bne :-
    jsr $1500                    ; run it FROM RAM
    lda #$0B                     ; bank 0 + NMI + timer + LCD
    sta $2026
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
