; hwtest15: CART BUS VISIBILITY PROBE (phase 1 of the VRAM-snoop experiment)
;
; Question: can the SuperPico (RP2040) see the console's VRAM WRITES through
; the cart edge?  The cart edge has no #WR wired to the Pico (schematic: #WR
; is pin 35, unconnected; GPIO28 is #RD) -- but D0-D7 are wired STRAIGHT to
; the Pico and A0-A16 pass through always-enabled 74LVC245s, so the bus is
; continuously visible.  #RD is only asserted for cart-region reads (it must
; be, or the cart would fight the internal SRAM on every RAM read), so in a
; loop made ONLY of cart fetches + writes, every #RD-HIGH cycle IS a write
; cycle.  The snoop firmware (main_snoop.c) samples on #RD-high and counts
; these marker (address,data) pairs:
;   $4111 <- $F5   $4333 <- $E7   $4555 <- $D9   $4777 <- $CB   (VRAM)
;   $0066 <- $99                                                (ZP control)
; Low-14 address bits are deliberately distinctive ($4000's low 14 = 0).
; Screen: solid light gray + 4 dark specks = booted and looping.
;
; Build: ca65 --cpu 65c02 hwtest15.s -o hwtest15.o
;        ld65 -C hwtest64.cfg hwtest15.o -o hwtest15.sv

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

loop:                            ; 32 cycles, 5 write cycles per pass (~125k/s
    lda #$F5                     ; per marker at 4 MHz) -- no RAM reads, so
    sta $4111                    ; the only non-fetch cycles are the writes
    lda #$E7
    sta $4333
    lda #$D9
    sta $4555
    lda #$CB
    sta $4777
    lda #$99
    sta $66
    jmp loop

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
