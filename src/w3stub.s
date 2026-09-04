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
LINK_DDR = $2021                 ; MAGNUM page (docs/37): banking here does
LINK_DAT = $2022                 ;   not restart the LCD scan; $2022 must read 0
                                 ;   at the $2021 write, $0F = the panel's drive
FLAGS    = $0B                   ; NMI | TIMER_IRQ | LCD (load_level's mask)
.ifdef W4KIT                     ; page 10 (World 4): tighter layout, docs/45
W3WIN    = $8000                 ;   the kit window image (pack_w4 pin; the copy
W3SPT    = $B11E                 ;   uses >W3WIN only: PAGE-ALIGNED) / spawn lists
.else
W3WIN    = $A800                 ; bank 6: the kit window image (pack_banks pin)
W3SPT    = $A7C0                 ; bank 6: 3x .addr spawn lists (pack_banks pin)
.endif

.segment "STUB1"                 ; runs at $1500 (the ovl_bind entry)
    ldx #<__STUB2_SIZE__
:   lda __STUB2_LOAD__-1,x
    sta __STUB2_RUN__-1,x
    dex
    bne :-
    jmp __STUB2_RUN__

.segment "STUB2"                 ; runs at $1F80 (outside the copy target)
    stz LINK_DAT            ; map the world's COLD bank
.if .defined(W4KIT)
    lda #10                      ; World 4 = pages (9 resident, 10 cold)
.else
    lda #6
.endif
    sta LINK_DDR
    lda #$0F
    sta LINK_DAT
    stz tmpL2                    ; src = $A000 (the kit image in bank 6)
    lda #>W3WIN
    sta tmpH2
    stz tmpL                     ; dst = $1500
    lda #$15
    sta tmpH
    ldx #8                       ; 8 full pages = the whole $800 window ($1D00+
                                 ; is HUDSHADOW -- growing into it let the HUD
                                 ; overwrite kit code every frame; measured)
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
    lda cur_level                ; this level's spawn list (cold bank): the
    sec                          ; header's +16 is a resident $FFFF sentinel
.if .defined(W4KIT)
    sbc #9                       ; World 4's cold bank starts at level 9
.else
    sbc #6
.endif
    asl
    tax
    lda W3SPT,x
    sta tmpL2
    sta $1FF1                    ; keep the cold-bank list address for the engine's
    lda W3SPT+1,x                ; spawn WINDOW (main.s spawn_reload): a respawn or
    sta tmpH2                    ; a window shift past entry 51 re-copies from here
    sta $1FF2
    ldy #0
:   lda (tmpL2),y
    sta spawn_tab,y
    iny
    bne :-                       ; 256 bytes covers every W3 list + sentinel
.if .defined(W4KIT)              ; 4-1 has 82 spawn entries = 410 bytes of list;
    inc tmpH2                    ; spawn_tab is 384, so copy the second part too
:   lda (tmpL2),y                ; (y wrapped to 0)
    sta spawn_tab+256,y
    iny
    cpy #128
    bne :-
.endif
    stz LINK_DAT            ; back to THIS world's resident bank
.if .defined(W4KIT)
    lda #9
.else
    lda #1
.endif
    sta LINK_DDR
    lda #$0F
    sta LINK_DAT
    jmp $1500                    ; the kit's real init
