; hwtest11: TEXT verdict. White screen; "ROM OK" drawn by ROM code;
; "RAM OK" drawn by the SAME logic copied to $1500 and run FROM RAM.
;   both lines   = RAM execution + VRAM writes fine
;   ROM OK only  = RAM-executed VRAM writes are lost (the suspected law)
;   neither      = seating lottery
; Chars: indexes 0=R 1=O 2=M 3=A 4=K (own 8x8 font, fb-native 2bpp).
.segment "ZEROPAGE"
ptr:  .res 2
fptr: .res 2

.segment "CODE"
font:
.include "font.inc"

; draw char A=index at ptr (fb addr); clobbers fptr/X/Y
drawchar:
    asl
    asl
    asl
    asl                          ; *16
    clc
    adc #<font
    sta fptr
    lda #>font
    adc #0
    sta fptr+1
    ldx #8
@row:
    ldy #0
    lda (fptr),y
    sta (ptr),y
    iny
    lda (fptr),y
    sta (ptr),y
    lda fptr                     ; font += 2
    clc
    adc #2
    sta fptr
    bcc :+
    inc fptr+1
:   lda ptr                      ; fb += 48 (next line)
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
    stz ptr                      ; clear fb to white
    lda #$40
    sta ptr+1
    ldy #0
    lda #$00
@c: sta (ptr),y
    iny
    bne @c
    inc ptr+1
    ldx ptr+1
    cpx #$60
    bne @c
    ; "ROM OK" at row 40: fb $4000 + 40*48 = $4780, chars 3 bytes apart
    ldx #0
@t1:
    lda row1pos,x
    sta ptr
    lda #$47
    sta ptr+1
    lda row1chr,x
    phx
    jsr drawchar
    plx
    inx
    cpx #5
    bne @t1
    ; copy the RAM painter blob (code+font, linked to run at $1500)
    lda #((6 << 5) | $0F)
    sta $2026
    ldy #0
:   lda $8000,y
    sta $1500,y
    iny
    bne :-
    ldy #0
:   lda $8100,y
    sta $1600,y
    iny
    bne :-
    jsr $1500                    ; draws "RAM OK" at row 80, from RAM
    lda #$DF
    sta $2026
@forever:
    jmp @forever

row1pos: .byte $80, $83, $86, $8C, $8F     ; R O M _ O K columns (byte offsets)
row1chr: .byte 0, 1, 2, 1, 4

nmi:
irq:
    rti

.segment "BOOTR"                 ; linked to RUN at $1500 (self-contained)
ramentry:
    ldx #0
@t2:
    lda r2pos,x
    sta ptr
    lda #$4F                     ; row 80: $4000 + 80*48 = $4F00
    sta ptr+1
    lda r2chr,x
    phx
    jsr rdraw
    plx
    inx
    cpx #5
    bne @t2
    rts
rdraw:                           ; same drawchar, RAM-resident, RAM font
    asl
    asl
    asl
    asl
    clc
    adc #<rfont
    sta fptr
    lda #>rfont
    adc #0
    sta fptr+1
    ldx #8
@row:
    ldy #0
    lda (fptr),y
    sta (ptr),y
    iny
    lda (fptr),y
    sta (ptr),y
    lda fptr
    clc
    adc #2
    sta fptr
    bcc :+
    inc fptr+1
:   lda ptr
    clc
    adc #48
    sta ptr
    bcc :+
    inc ptr+1
:   dex
    bne @row
    rts
r2pos: .byte $00, $03, $06, $0C, $0F
r2chr: .byte 0, 3, 2, 1, 4                 ; R A M _ O K
rfont:
.include "font.inc"

.segment "VECTORS"
    .addr nmi, reset, irq
