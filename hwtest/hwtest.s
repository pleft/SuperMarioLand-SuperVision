; Minimal Supervision hardware smoke test: fill the framebuffer with stripes.
; Same 128K image layout as the port (FIXED = last 16K, vectors at $FFFA),
; but the boot does NOTHING clever: no interrupts, no bank switching.
.include "../src/supervision.inc"

.segment "ZEROPAGE"
ptr: .res 2

.segment "CODE"
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #0                       ; SYS_CTRL: no NMI, no IRQ, bank 0
    sta SYS_CTRL
    lda #$A0                     ; LCD 160 px wide
    sta LCD_XSIZE
    lda #160                     ; 160 lines
    sta LCD_YSIZE
    stz XSCROLL
    stz YSCROLL
    lda #$0F                     ; $2022: written $0F by EVERY commercial boot
    sta $2022                    ; (Block Buster $C029) -- never emulated as
                                 ; required by Potator; likely LCD drive enable
    stz ptr                      ; fill $4000-$5FFF with a stripe pattern
    lda #$40
    sta ptr+1
    ldy #0
    lda #$1B                     ; 2bpp: pixels 3,2,1,0 = a 4-shade stripe
@fill:
    sta (ptr),y
    iny
    bne @fill
    inc ptr+1
    ldx ptr+1
    cpx #$60
    bne @fill
@forever:
    jmp @forever

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
