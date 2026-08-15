; telem_stub.s -- generic NMI-prefix exporter injected by patch_telem.py.
;
; Runs at NMI entry, then jmps to the game's original NMI handler. Fully
; transparent: saves/restores A,X,Y and the two ZP pointer bytes it borrows,
; so it needs NO reserved WRAM except the top-of-WRAM mailbox $1F80-$1FFF
; (which the patcher verifies the game leaves alone). Each frame it exports a
; 32-byte VRAM slice (whole 8 KB VRAM covered in 256 frames ~4 s) + joypad,
; via visible WRAM writes, using the docs/29 mailbox protocol.
;
; ORIG_NMI is defined by a patcher-generated include.
.include "orig_nmi.inc"

.segment "STUB"
stub:
    pha
    txa
    pha
    tya
    pha
    lda $10                      ; borrow ZP $10/$11 as the VRAM pointer
    pha
    lda $11
    pha

    inc $1F82                    ; SEQ
    lda #$A5
    sta $1F81                    ; MAGIC
    lda $2020
    sta $1F84                    ; JOYPAD (the one readable register)

    inc $1F83                    ; slice id 0..255 (persists in the mailbox)
    lda $1F83
    lsr a                        ; hi = $40 + (slice>>3)
    lsr a
    lsr a
    clc
    adc #$40
    sta $11
    lda $1F83
    and #$07                     ; lo = (slice&7)<<5   (slice*32, +$4000 base)
    asl a
    asl a
    asl a
    asl a
    asl a
    sta $10

    ldy #0                       ; copy 32 VRAM bytes -> payload $1F85+
@cp:
    lda ($10),y
    sta $1F85,y
    iny
    cpy #32
    bne @cp

    ; checksum = plain mod-256 sum of the 32 payload bytes + SEQ + JOYPAD
    ldy #0
    lda #0
@ck:
    clc
    adc $1F85,y
    iny
    cpy #32
    bne @ck
    clc
    adc $1F82                    ; + SEQ
    clc
    adc $1F84                    ; + JOYPAD
    sta $1FFE                    ; CKSUM

    lda $1F83
    sta $1FFF                    ; COMMIT (= slice id)

    pla
    sta $11
    pla
    sta $10
    pla
    tay
    pla
    tax
    pla
    jmp ORIG_NMI
