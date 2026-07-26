; hwtest10: ONE-FLASH VERDICT on "VRAM writes from RAM-executing code fail".
; All-ROM boot (hwtest3-style, proven): LCD on, fill ALL stripes from ROM.
; Then copy a tiny painter to $1500 and have IT paint rows 64-95 SOLID DARK
; from RAM. Result reading:
;   stripes everywhere + a dark band  = RAM execution works fine
;   stripes with the band MISSING     = RAM-executed VRAM writes are LOST
;   no stripes at all                 = seating lottery, try again
.segment "ZEROPAGE"
ptr: .res 2

.segment "BOOT6"
rampaint:                        ; position-independent painter: rows 64..95
    lda #$60                     ; $4000 + 64*48 = $4C00
    sta ptr
    lda #$4C
    sta ptr+1
    ldy #0
    lda #$FF                     ; solid shade-3
@p: sta (ptr),y
    iny
    bne @p
    inc ptr+1
    ldx ptr+1
    cpx #$52                     ; through $51FF = row 95's end
    bne @p
    rts
rampaint_end:

.segment "CODE"
reset:
    ldx #$FF
    txs
    cld
    lda #$A0
    sta $2000
    lda #$A0
    sta $2001
    stz $2002
    stz $2003
    lda #$DF                     ; Block Buster's exact SYS_CTRL (bank bits + all)
    sta $2026
    lda #$0F
    sta $2022
    stz ptr                      ; stripes over the WHOLE fb, from ROM (proven)
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
    lda #((6 << 5) | $0F)        ; map bank 6 to copy the painter (keep low bits)
    sta $2026
    ldy #0
:   lda $8000,y
    sta $1500,y
    iny
    bne :-
    jsr $1500                    ; paint the dark band FROM RAM
    lda #$DF
    sta $2026
@forever:
    jmp @forever

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
