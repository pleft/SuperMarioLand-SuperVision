; ---------------------------------------------------------------------------
; W2STUB -- the 2-3 window bootstrap. Bank 5 cannot store the Marine Pop kit
; (the 5.7K map owns the bank), so the REAL window image lives in BANK 6 at
; $B000. This stub is what the level header points at: ovl_bind copies it to
; $1500 and jumps in; it relocates its own loader to $1F80 (the telemetry
; mailbox: retail-unused, load-time-only), pulls the kit from bank 6 over
; $1500-$1CFF, restores bank 5 and restarts $1500 = the kit's true init.
; ---------------------------------------------------------------------------
.setcpu "65C02"
.include "w2abi.inc"             ; tmpL2/tmpH2 (zp copy pointers)
.import __STUB2_LOAD__, __STUB2_RUN__, __STUB2_SIZE__

SYS_CTRL = $2026
FLAGS    = $0B                   ; NMI | TIMER_IRQ | LCD (load_level's mask)

.segment "STUB1"                 ; runs at $1500 (the ovl_bind entry)
    ldx #<__STUB2_SIZE__
:   lda __STUB2_LOAD__-1,x
    sta __STUB2_RUN__-1,x
    dex
    bne :-
    jmp __STUB2_RUN__

.segment "STUB2"                 ; runs at $1F80 (outside the copy target)
    lda #(6<<5)|FLAGS            ; map BANK 6
    sta SYS_CTRL
    stz tmpL2                    ; src = $B000 (the kit image in bank 6)
    lda #$B0
    sta tmpH2
    stz tmpL                     ; dst = $1500
    lda #$15
    sta tmpH
    ldx #8                       ; 8 full pages = the whole $800 window
@pg:
    ldy #0
:   lda (tmpL2),y
    sta (tmpL),y
    iny
    bne :-
    inc tmpH2
    inc tmpH
    dex
    bne @pg
    stz tmpL2                    ; the spawn list rides bank 6 too ($B800):
    lda #$B8                     ; copy it straight into spawn_tab (the bank-5
    sta tmpH2                    ; header points at a $FFFF sentinel)
    ldy #0
:   lda (tmpL2),y
    sta spawn_tab,y
    iny
    cpy #160
    bne :-
    lda #(5<<5)|FLAGS            ; back to BANK 5
    sta SYS_CTRL
    jmp $1500                    ; the kit's real init
