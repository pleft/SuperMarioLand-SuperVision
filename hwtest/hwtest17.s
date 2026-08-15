; hwtest17: CART BUS VISIBILITY PROBE v4 -- close the remaining questions.
;
; Established on real HW (hwtest15/16 + BUSDIAG v1-v3):
;   cart fetches: served/seen     WRAM writes: addr+data visible
;   VRAM writes: addr ONLY        VRAM reads: addr ONLY
;   WRAM reads (zp): INVISIBLE (neither addr nor data)
; v4 asks:
;   1. is WRAM-read invisibility universal or zp-mode-only?  lda $0167
;   2. does the write-address broadcast cover ALL space?     sta $3111 (unmapped)
;   3. are ASIC REGISTER reads visible? (the joypad question) lda $2026 (= $DF)
; Markers (low14/data):
;   W $4111<-$F5 (VRAM)   W $4333<-$E7 (VRAM)   W $0066<-$99 (WRAM zp)
;   W $3111<-$5A (unmapped)
;   R $0067=$A7 (WRAM zp) R $0167=$C5 (WRAM abs) R $4222=$B7 (VRAM)
;   R $2026=$DF (ASIC reg readback)
;
; Build: ca65 --cpu 65c02 hwtest17.s -o hwtest17.o
;        ld65 -C hwtest64.cfg hwtest17.o -o hwtest17.sv

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
    lda #$C5
    sta $0167
    lda #$B7
    sta $4222

loop:                            ; 41 cycles, 8 marker cycles per pass
    lda #$F5                     ; (~97k/s per marker at 4 MHz)
    sta $4111
    lda #$E7
    sta $4333
    lda #$99
    sta $66
    lda #$5A
    sta $3111
    lda $67
    lda $0167
    lda $4222
    lda $2026
    jmp loop

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
