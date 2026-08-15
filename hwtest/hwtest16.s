; hwtest16: CART BUS VISIBILITY PROBE v2 (phase 1b of the VRAM-snoop test)
;
; hwtest15's result on real HW: WRAM WRITES fully visible (addr low14 + data,
; a15 reads high), VRAM writes invisible (no addr, no data) -> VRAM sits on
; the ASIC's internal video bus. v2 adds READ markers to map the rest:
;   writes (as before):
;     $4111 <- $F5   $4333 <- $E7   $4555 <- $D9   $4777 <- $CB   (VRAM)
;     $0066 <- $99                                                (WRAM zp)
;   reads (values preset once at boot):
;     lda $0067  -> ($0067, $A7)   does a WRAM READ show on the bus?
;     lda $4222  -> ($0222, $B7)   does a VRAM READ show on the bus?
; Screen: solid light gray + specks = booted and looping.
;
; Build: ca65 --cpu 65c02 hwtest16.s -o hwtest16.o
;        ld65 -C hwtest64.cfg hwtest16.o -o hwtest16.sv

.segment "ZEROPAGE"
ptr: .res 2

.segment "CODE"

reset:
    ldx #$FF
    txs
    cld
    sei
    lda #$A0                     ; the hwtest14 liturgy, HW-verified verbatim
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

    stz ptr                      ; fill VRAM $4000-$5FFF with $55 (light gray)
    lda #$40
    sta ptr+1
    ldy #0
    lda #$55
@f: sta (ptr),y
    iny
    bne @f
    inc ptr+1
    ldx ptr+1
    cpx #$60
    bne @f

    lda #$A7                     ; preset the read markers
    sta $67
    lda #$B7
    sta $4222

loop:                            ; 39 cycles: 5 writes + 2 reads per pass
    lda #$F5                     ; (~102k/s per marker at 4 MHz); everything
    sta $4111                    ; else is a cart fetch, so #RD-high cycles
    lda #$E7                     ; are exactly these 7 marker cycles
    sta $4333
    lda #$D9
    sta $4555
    lda #$CB
    sta $4777
    lda #$99
    sta $66
    lda $67
    lda $4222
    jmp loop

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
