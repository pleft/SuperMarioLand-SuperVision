; ---------------------------------------------------------------------------
; W3STUB -- the World 3 window bootstrap (docs/33). The three W3 levels are
; RESIDENT on bank 1 (headers/pipes/blocks/bg-charset in its tail) with the
; cold data (maps/rooms/spawns/kit image) in BANK 6. This stub is what the
; W3 headers' +20/21 point at: ovl_bind copies it to $1500 and jumps in; it
; relocates its loader to $1F80, pulls the kit image from bank 6 $A000 over
; $1500-$1CFF, copies this level's spawn list (bank 6, via the $9FE0 table)
; into spawn_tab, restores bank 1 and restarts $1500 = the kit's true init.
; ---------------------------------------------------------------------------
.setcpu "65C02"
.include "w2abi.inc"
.import __STUB2_LOAD__, __STUB2_RUN__, __STUB2_SIZE__

SYS_CTRL = $2026
FLAGS    = $0B                   ; NMI | TIMER_IRQ | LCD (load_level's mask)
W3WIN    = $A800                 ; bank 6: the kit window image (pack_banks pin)
W3SPT    = $A7C0                 ; bank 6: 3x .addr spawn lists (pack_banks pin)

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
    stz tmpL2                    ; src = $A000 (the kit image in bank 6)
    lda #>W3WIN
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
    lda cur_level                ; this level's spawn list (bank 6): the
    sec                          ; header's +16 is a bank-1 $FFFF sentinel
    sbc #6
    asl
    tax
    lda W3SPT,x
    sta tmpL2
    lda W3SPT+1,x
    sta tmpH2
    ldy #0
:   lda (tmpL2),y
    sta spawn_tab,y
    iny
    bne :-                       ; 256 bytes covers every W3 list + sentinel
    lda #(1<<5)|FLAGS            ; back to BANK 1 (the W3 resident)
    sta SYS_CTRL
    jmp $1500                    ; the kit's real init
