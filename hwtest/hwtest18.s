; hwtest18: TELEMETRY PIPELINE VALIDATOR (phase 2 of the devkit, docs/29)
;
; Every NMI (61 Hz) writes a full display-list snapshot into the WRAM
; mailbox $1F80-$1FFF (the layout the real game will use), COMMIT last:
;   $1F80 MAGIC $A5      $1F81 SEQ        $1F82 VXP(=SEQ, fake)
;   $1F83 VXPH(0)        $1F84 VYP(0)     $1F85 box x (bounces 0..159)
;   $1F86 box y (bounces 8..151)          $1F87 SEQ^$FF
;   $1F90-$1FBF ramp: SEQ+i (48 bytes -- the viewer's corruption meter)
;   $1FFF COMMIT = SEQ (written LAST -> the Pico ships the snapshot)
; It also draws a black dot at column x on VRAM row 80: the dot on the
; console and the box in tools/telemview.py must move in lockstep.
;
; Build: ca65 --cpu 65c02 hwtest18.s -o hwtest18.o
;        ld65 -C hwtest64.cfg hwtest18.o -o hwtest18.sv

.segment "ZEROPAGE"
ptr:  .res 2
seq:  .res 1
bx:   .res 1
by:   .res 1
dx:   .res 1                     ; $01 or $FF
dy:   .res 1
pidx: .res 1                     ; previous dot byte index in row 80
ck:   .res 1                     ; running payload checksum (mod-256 sum)

.segment "CODE"

reset:
    ldx #$FF
    txs
    cld
    sei
    stz seq                      ; ZP init FIRST -- the NMI is live the
    stz bx                       ; moment $2026=$DF lands below
    lda #8
    sta by
    lda #1
    sta dx
    sta dy
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
    bra main                     ; everything happens in the NMI

nmi:
    pha
    phx
    inc seq

    lda #1                       ; bounce x in 0..159
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
    lda #1                       ; bounce y in 8..151
    cmp dy
    beq :+
    dec by
    lda by
    cmp #8
    bne @ydone
    lda #1
    sta dy
    bra @ydone
:   inc by
    lda by
    cmp #151
    bne @ydone
    lda #$FF
    sta dy
@ydone:

    ; --- the mailbox, CKSUM then COMMIT last. $1F80 is NEVER written: as
    ; the window base (low7=0) it catches bus-transition aliases in the
    ; snooper (HW-measured: ~50% of frames tore there) -- a trap byte,
    ; excluded from the protocol. Header starts at $1F81.
    stz ck
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
    lda by
    sta $1F87
    jsr addck
    lda seq
    eor #$FF
    sta $1F88
    jsr addck
    ldx #0
:   txa
    clc
    adc seq
    sta $1F90,x
    jsr addck
    inx
    cpx #48
    bne :-
    lda ck
    sta $1FFE                    ; CKSUM = mod-256 sum of the summed bytes

    lda #$55                     ; dot: restore previous byte on row 80,
    ldx pidx                     ; paint the new one black
    sta $4F00,x                  ; $4000 + 80*48 = $4F00
    lda bx
    lsr
    lsr
    tax
    lda #$FF
    sta $4F00,x
    stx pidx

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
