; test_game: a minimal "foreign game" with a ROOMY fixed bank, to validate
; patch_telem.py + telem_stub.s end to end. Fills VRAM with a checkable ramp
; (byte = (addr & $FF) ^ (addr >> 8)), enables NMI (rti handler), spins.
; After patching, the injected stub prepends every NMI and exports slices.
;
; Build: ca65 --cpu 65c02 test_game.s -o test_game.o
;        ld65 -C hwtest64.cfg test_game.o -o test_game.sv

.segment "ZEROPAGE"
ptr: .res 2

.segment "CODE"
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

    stz ptr                      ; VRAM[addr] = (addr&$FF) ^ (addr>>8)
    lda #$40
    sta ptr+1
@row:
    ldy #0
@col:
    tya
    eor ptr+1
    sta (ptr),y
    iny
    bne @col
    inc ptr+1
    lda ptr+1
    cmp #$60
    bne @row

main:
    bra main

nmi:
    rti
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
