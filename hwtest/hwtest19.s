; hwtest19: ASIC REGISTER READBACK PROBE (devkit phase 3 groundwork).
;
; Question: which ASIC registers can the CPU read back on real hardware?
; (Decides whether a generic ROM patch can export scroll state directly.)
; Method: each NMI, write known values into probe registers, read them back,
; and EXPORT the results through the hwtest18 telemetry mailbox (WRAM writes
; = bus-visible; pairs with the SUPERPICO_TELEM PIO firmware + telemview
; --regs). Probe values avoid $20 (the open-bus ghost = last fetched
; operand high byte) and $00, so readable / open-bus / zero are separable.
;
; Payload map ($1F90+):
;   +0 $2002 readback after writing $11 (XSCROLL; restored to 0)
;   +1 $2003 readback after writing $07 (YSCROLL; restored to 0)
;   +2 $2000 readback (boot wrote $A0)      +3 $2001 (boot wrote $A0)
;   +4 $2026 readback (boot wrote $DF)      +5 $2022 (boot wrote $0F)
;   +6 $2020 JOYPAD live (press buttons -- should change!)
;   +7 $2024   +8 $2025   +9 $2027 (informational)
;   +10 $2008 readback after writing $5A    +11 $2009 after $A5 (DMA src)
;
; Build: ca65 --cpu 65c02 hwtest19.s -o hwtest19.o
;        ld65 -C hwtest64.cfg hwtest19.o -o hwtest19.sv

.segment "ZEROPAGE"
ptr:  .res 2
seq:  .res 1
bx:   .res 1
dx:   .res 1
pidx: .res 1
ck:   .res 1

.segment "CODE"

reset:
    ldx #$FF
    txs
    cld
    sei
    stz seq
    stz bx
    lda #1
    sta dx
    stz pidx
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

main:
    bra main

.macro PROBE reg, dst           ; read reg, export to dst, add to cksum
    lda reg
    sta dst
    jsr addck
.endmacro

nmi:
    pha
    phx

    inc seq
    lda #1                       ; bounce x (liveness dot, row 80)
    cmp dx
    beq :+
    dec bx
    bne @xdone
    lda #1
    sta dx
    bra @xdone
:   inc bx
    lda bx
    cmp #159
    bne @xdone
    lda #$FF
    sta dx
@xdone:

    stz ck                       ; --- header ($1F80 = trap byte, unused) ---
    lda #$A5
    sta $1F81
    jsr addck
    lda seq
    sta $1F82
    jsr addck
    lda seq
    sta $1F83
    jsr addck
    stz $1F84
    stz $1F85
    lda bx
    sta $1F86
    jsr addck
    lda #0
    sta $1F87
    jsr addck
    lda seq
    eor #$FF
    sta $1F88
    jsr addck

    lda #$11                     ; --- the probes ---
    sta $2002
    PROBE $2002, $1F90
    stz $2002
    lda #$07
    sta $2003
    PROBE $2003, $1F91
    stz $2003
    PROBE $2000, $1F92
    PROBE $2001, $1F93
    PROBE $2026, $1F94
    PROBE $2022, $1F95
    PROBE $2020, $1F96
    PROBE $2024, $1F97
    PROBE $2025, $1F98
    PROBE $2027, $1F99
    lda #$5A
    sta $2008
    PROBE $2008, $1F9A
    lda #$A5
    sta $2009
    PROBE $2009, $1F9B

    lda #$55                     ; liveness dot
    ldx pidx
    sta $4F00,x
    lda bx
    lsr
    lsr
    tax
    lda #$FF
    sta $4F00,x
    stx pidx

    lda ck
    sta $1FFE
    lda seq
    sta $1FFF                    ; COMMIT

    plx
    pla
    rti

irq:
    rti

addck:                           ; ck += A (plain mod-256 sum)
    clc
    adc ck
    sta ck
    rts

.segment "VECTORS"
    .addr nmi, reset, irq
