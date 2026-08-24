; W3AUX v2 -- the GROUP composer (docs/42). Lives at $BB00 in PAGE 8, which
; make_512k lays out as the FULL bank-1 image with the W3 sprite slice mirrored
; at $B740 and this blob over the (never-read-during-a-draw) bank-1 tail. So
; under page 8 everything resolves at its normal address: the prefix, the
; bank-1 W3 charset (bgc -> get_tile_src), the sprite slice (quad_base math),
; FIXED (set_dst, map_transform, chardata, revpix), all RAM.
;
; The background of every composed cell is REBUILT FROM THE MAP (ids from the
; W3 column cache, made hot by the kit under bank 6 right before), then every
; stash entry's tiles that touch the cell are overlaid, and the 16 bytes are
; written once. Sprites are never absent from VRAM; overlapping sprites share
; cells correctly because the bg source is sprite-free by construction; no
; per-object context, no RAM squeeze, no staleness (the map is the truth).
;
; Reached ONLY via the plain-$2021 dance; NEVER via SYS_CTRL bit5.

.include "w2abi.inc"

MASKTAB     = $0600              ; transparency mask of a 2bpp byte (shtab_hi p0)
shtab_lo    = $0200              ; boot-built shift tables (page = subx; page 0
                                 ; is the W3 COLUMN CACHE -> identity computed)
W3CDATA     = $0200
W3CTAG      = $1F80
W3TILB      = $A600              ; the slice MIRROR in page 8 (ids $A0+ -> +(id-$A0)*16)
VSTRIDE     = $30

CS_A        = $1C70              ; stash slots 0..6 (20B each)
CS_B        = $1FA0              ; stash slots 7..9
; entry: +0 nt|dying($80) +1 dcol0 +2 dy0 +3 cols +4 rows +5 id[4] +9 tx[4]
;        +13 ty[4] +17 flags (2 bits/tile)

CXA_DCOL0   = $01C6              ; NEW box (the kit filled these)
CXA_DY0     = $01C7
CXA_COLS    = $01C8
CXA_ROWS    = $01C9
CXA_ODCOL0  = $01CA              ; OLD box (OCOLS=0: none)
CXA_ODY0    = $01CB
CXA_OCOLS   = $01CC
CXA_OROWS   = $01CD
CXA_SLOT    = $01CE

; composer scratch -- LOW in the stack page ($0160+): the composer nests
; deeper than anything before it and the stack reaches $01E0 under an NMI
AX_CDC      = $0160              ; current cell: ring byte col (even)
AX_CDY      = $0161              ; current cell: scanline (mult 8)
AX_E        = $0162              ; entry walker
AX_TN       = $0163              ; tile walker
AX_BCASE    = $0164
AX_DYT      = $0165
AX_B0       = $0166
AX_B1       = $0167
AX_S0       = $0168
AX_S1       = $0169
AX_S2       = $016A
AX_R        = $016B
AX_BRB      = $016C
AX_FL       = $016D              ; current tile flags (bit0 xf, bit1 yf)
AX_S        = $016E
AX_MIX      = $016F
AX_SUB0     = $0170
AX_CI       = $0171              ; box walkers
AX_RJ       = $0172
AX_T0       = $0173
AX_T1       = $0174
AX_NT       = $0175
AX_BX0      = $0176              ; box being walked
AX_BY0      = $0177
AX_BC       = $0178
AX_BR       = $0179
AX_LIST     = $017A              ; entries touching the current union box
                                 ; (slot indexes, $FF-terminated, <= 11 bytes)
AX_UX0      = $0185              ; union bbox for the prefilter
AX_UY0      = $0186
AX_UX1      = $0187              ; exclusive ends (bytes / scanlines)
AX_UY1      = $0188

.segment "AUX"

; ---------------------------------------------------------------------------
; ax_entry: tmpL/tmpH -> stash entry X (X preserved)
.proc ax_entry
    phx
    txa
    cmp #7
    bcc :+
    sbc #7
    ldy #<CS_B
    sty tmpL
    ldy #>CS_B
    bra @m
:   ldy #<CS_A
    sty tmpL
    ldy #>CS_A
@m: sty tmpH
    asl
    asl
    sta AX_T0
    asl
    asl
    clc
    adc AX_T0
    clc
    adc tmpL
    sta tmpL
    bcc :+
    inc tmpH
:   plx
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_mix: masked-merge A into flipbuf[AX_MIX]. A=0 = wholly transparent.
.proc ax_mix
    beq @out
    sta AX_S
    tay
    lda MASKTAB,y
    eor #$FF
    ldx AX_MIX
    and flipbuf,x
    ora AX_S
    sta flipbuf,x
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_over: overlay one tile onto flipbuf. In: tmpL3 = tile pixels (16B),
; AX_FL = flips, X = dx (signed, -7..7), AX_DYT = dy (signed, -7..7).
; subx = dx & 3 -> shtab page (page 0 = identity, computed); byte-offset
; case = (dx+8)>>2: 0: s2->buf+0 | 1: s1->+0,s2->+1 | 2: s0->+0,s1->+1 | 3: s0->+1
.proc ax_over
    txa
    and #3
    sta AX_SUB0
    clc
    adc #>shtab_lo
    sta p_shlo+1
    stz p_shlo
    txa
    and #3
    clc
    adc #>shtab_lo + 4
    sta p_shhi+1
    stz p_shhi
    txa
    clc
    adc #8
    lsr
    lsr
    sta AX_BCASE
    stz AX_R
@row:
    lda AX_R
    clc
    adc AX_DYT                   ; br = r + dy
    cmp #8
    bcc @in
    jmp @next
@in:
    asl
    sta AX_BRB
    lda AX_FL
    and #2                       ; y-flip: source row 7-r
    beq :+
    lda AX_R
    eor #$FF
    clc
    adc #8
    bra @sr
:   lda AX_R
@sr:
    asl
    tay
    lda (tmpL3),y
    sta AX_B0
    iny
    lda (tmpL3),y
    sta AX_B1
    lda AX_FL
    and #1                       ; x-flip: swap bytes + reverse pixels
    beq @nxf
    ldy AX_B1
    lda revpix,y
    pha
    ldy AX_B0
    lda revpix,y
    sta AX_B1
    pla
    sta AX_B0
@nxf:
    lda AX_SUB0
    bne @tables
    lda AX_B0
    sta AX_S0
    lda AX_B1
    sta AX_S1
    stz AX_S2
    bra @cases
@tables:
    ldy AX_B0
    lda (p_shlo),y
    sta AX_S0
    lda (p_shhi),y
    sta AX_S1
    ldy AX_B1
    lda (p_shlo),y
    ora AX_S1
    sta AX_S1
    lda (p_shhi),y
    sta AX_S2
@cases:
    lda AX_BCASE
    beq @c0
    cmp #1
    beq @c1
    cmp #2
    beq @c2
    lda AX_BRB                   ; case 3
    ina
    sta AX_MIX
    lda AX_S0
    jsr ax_mix
    bra @next
@c0:
    lda AX_BRB
    sta AX_MIX
    lda AX_S2
    jsr ax_mix
    bra @next
@c1:
    lda AX_BRB
    sta AX_MIX
    lda AX_S1
    jsr ax_mix
    lda AX_BRB
    ina
    sta AX_MIX
    lda AX_S2
    jsr ax_mix
    bra @next
@c2:
    lda AX_BRB
    sta AX_MIX
    lda AX_S0
    jsr ax_mix
    lda AX_BRB
    ina
    sta AX_MIX
    lda AX_S1
    jsr ax_mix
@next:
    inc AX_R
    lda AX_R
    cmp #8
    beq @out
    jmp @row
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_bg: flipbuf = the map background of cell (AX_CDC, AX_CDY).
; C=1: the cell is not a playfield cell (HUD/off) -> skip it whole.
.proc ax_bg
    lda AX_CDY
    lsr
    lsr
    lsr
    sec
    sbc #2                       ; map row = VRAM row - 2
    cmp #18
    bcs @skip
    sta mrow
    cmp #16
    bcc @map
    lda #$61                     ; the dirt band (restore_bg's rule)
    bra @have
@map:
    lda AX_CDC                   ; world col = fb_col0 + dcol/2
    lsr
    clc
    adc fb_col0
    sta feet_col
    lda fb_col0+1
    adc #0
    sta feet_col+1
    lda feet_col                 ; the column cache (kit made it hot)
    and #15
    asl
    tax
    lda W3CTAG,x
    cmp feet_col
    bne @miss
    lda W3CTAG+1,x
    cmp feet_col+1
    bne @miss
    txa
    asl
    asl
    asl
    clc
    adc mrow
    tax
    lda W3CDATA,x
    jsr map_transform            ; the mod/multi-coin rules (FIXED)
    bra @have
@miss:
    lda #$2C                     ; never (pre-touched) -- sky is the safe id
@have:
    cmp #$2C
    beq @sky
    jsr get_tile_src             ; src_ptr = the tile's pixels (bgc / chardata)
    ldy #15
:   lda (src_ptr),y
    sta flipbuf,y
    dey
    bpl :-
    clc
    rts
@sky:
    ldy #15
    lda #0
:   sta flipbuf,y
    dey
    bpl :-
    clc
    rts
@skip:
    sec
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_cell: compose + write cell (AX_CDC, AX_CDY): bg, then every LIVE stash
; entry's tiles that touch it, then one 16-byte write (ring-wrapped rows).
.proc ax_cell
    lda AX_CDC
    cmp #48
    bcc :+
    rts                          ; past the ring row: never displayed
:   jsr ax_bg
    bcc :+
    rts
:   ldx #0
@e:
    stx AX_E
    lda AX_LIST,x
    bmi @wr0J                    ; end of the prefiltered list
    tax
    jsr ax_entry                 ; tmpL -> entry X
    lda (tmpL)
    beq @enJ
    bmi @enJ                     ; dying: excluded (that IS its erase)
    and #$0F                     ; (bit6 = overlay-only plain-path entry)
    sta AX_NT
    ldy #1                       ; box test: dcol in [dcol0, dcol0+cols*2)
    lda AX_CDC
    sec
    sbc (tmpL),y
    bcc @enJ
    sta AX_T0                    ; cell x offset (bytes) within the box
    ldy #3
    lda (tmpL),y
    asl
    cmp AX_T0
    beq @enJ
    bcc @enJ
    ldy #2                       ; dy in [dy0, dy0+rows*8)
    lda AX_CDY
    sec
    sbc (tmpL),y
    bcc @enJ
    sta AX_T1
    ldy #4
    lda (tmpL),y
    asl
    asl
    asl
    cmp AX_T1
    beq @enJ
    bcc @enJ
    lda AX_T0                    ; cell px within the box
    asl
    asl
    sta AX_T0
    stz AX_TN
    bra @t
@enJ:
    jmp @en
@wr0J:
    jmp @wr0
@t:
    ldy AX_TN
    cpy AX_NT
    bne :+
    jmp @en
:   tya
    clc
    adc #9
    tay
    lda (tmpL),y                 ; tx
    sec
    sbc AX_T0                    ; dx = tx - cell px
    tax
    clc
    adc #8
    cmp #16
    bcc :+
    jmp @tn                      ; no x overlap
:   lda AX_TN
    clc
    adc #13
    tay
    lda (tmpL),y                 ; ty
    sec
    sbc AX_T1
    sta AX_DYT
    clc
    adc #8
    cmp #16
    bcc :+
    jmp @tn
:   phx
    lda AX_TN                    ; flags: 2 bits at tn*2
    asl
    tay
    ldy #17
    lda (tmpL),y
    ldy AX_TN
    beq :++
:   lsr
    lsr
    dey
    bne :-
:   and #3
    sta AX_FL
    lda AX_TN                    ; tile pixels: id -> slice mirror / chardata
    clc
    adc #5
    tay
    lda (tmpL),y
    stz tmpH3
    asl
    rol tmpH3
    asl
    rol tmpH3
    asl
    rol tmpH3
    asl
    rol tmpH3
    sta tmpL3
    lda (tmpL),y
    cmp #$A0
    bcc @chr
    lda tmpL3
    clc
    adc #<(W3TILB - $A0*16)
    sta tmpL3
    lda tmpH3
    adc #>(W3TILB - $A0*16)
    sta tmpH3
    bra @src
@chr:
    lda tmpL3
    clc
    adc #<chardata
    sta tmpL3
    lda tmpH3
    adc #>chardata
    sta tmpH3
@src:
    plx
    jsr ax_over
@tn:
    inc AX_TN
    jmp @t
@en:
    ldx AX_E
    inx
    jmp @e
@wr0:
    ; --- write ---
    lda AX_CDC
    sta dcol
    lda AX_CDY
    sta dy
    jsr set_dst
    lda dst_ptr
    sta tmpL2
    lda dst_ptr+1
    sta tmpH2
    ldy #0
    ldx #8
@w: lda flipbuf,y
    sta (tmpL2)
    iny
    lda flipbuf,y
    phy
    ldy #1
    sta (tmpL2),y
    ply
    iny
    lda tmpL2
    clc
    adc #VSTRIDE
    sta tmpL2
    bcc :+
    inc tmpH2
:   lda tmpH2                    ; ring seam ($5FE0): wrap like ring_next_dst
    cmp #$5F
    bcc :+
    bne @wr
    lda tmpL2
    cmp #$E0
    bcc :+
@wr:
    lda tmpL2
    sec
    sbc #$E0
    sta tmpL2
    lda tmpH2
    sbc #$1F
    sta tmpH2
:   dex
    bne @w
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_box: compose every cell of the box (AX_BX0, AX_BY0, AX_BC x AX_BR),
; skipping cells inside the EXCLUSION box (CXA_DCOL0.. when AX_T? -- the
; caller passes exclusion via ax_box_ex) .
.proc ax_box
    stz AX_RJ
@r: stz AX_CI
@c: lda AX_CI
    asl
    clc
    adc AX_BX0
    sta AX_CDC
    lda AX_RJ
    asl
    asl
    asl
    clc
    adc AX_BY0
    sta AX_CDY
    jsr ax_cell
    inc AX_CI
    lda AX_CI
    cmp AX_BC
    bne @c
    inc AX_RJ
    lda AX_RJ
    cmp AX_BR
    bne @r
    rts
.endproc

; ax_box_ex: same, but skip cells inside the NEW box (CXA_DCOL0/DY0/COLS/ROWS)
.proc ax_box_ex
    stz AX_RJ
@r: stz AX_CI
@c: lda AX_CI
    asl
    clc
    adc AX_BX0
    sta AX_CDC
    lda AX_RJ
    asl
    asl
    asl
    clc
    adc AX_BY0
    sta AX_CDY
    ; inside the new box?
    lda AX_CDC
    sec
    sbc CXA_DCOL0
    bcc @go
    sta AX_T0
    lda CXA_COLS
    asl
    cmp AX_T0
    beq @go
    bcc @go
    lda AX_CDY
    sec
    sbc CXA_DY0
    bcc @go
    sta AX_T1
    lda CXA_ROWS
    asl
    asl
    asl
    cmp AX_T1
    beq @go
    bcc @go
    bra @n                       ; covered by the new box: already composed
@go:
    jsr ax_cell
@n:
    inc AX_CI
    lda AX_CI
    cmp AX_BC
    bne @c
    inc AX_RJ
    lda AX_RJ
    cmp AX_BR
    bne @r
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_prefilter: AX_LIST = the live entries whose box intersects the union
; bbox AX_UX0..UX1 (ring bytes) x AX_UY0..UY1 (scanlines). Once per compose:
; the per-cell loop then tests 1-3 entries instead of 10.
.proc ax_prefilter
    ldy #0
    sty AX_T1                    ; list length
    ldx #0
@e: jsr ax_entry
    lda (tmpL)
    beq @n
    bmi @n
    ldy #1                       ; e.x0 < UX1 && e.x1 > UX0
    lda (tmpL),y
    cmp AX_UX1
    bcs @n
    sta AX_T0
    ldy #3
    lda (tmpL),y
    asl
    clc
    adc AX_T0
    cmp AX_UX0
    bcc @n
    beq @n
    ldy #2
    lda (tmpL),y
    cmp AX_UY1
    bcs @n
    sta AX_T0
    ldy #4
    lda (tmpL),y
    asl
    asl
    asl
    clc
    adc AX_T0
    cmp AX_UY0
    bcc @n
    beq @n
    ldy AX_T1
    txa
    sta AX_LIST,y
    inc AX_T1
@n: inx
    cpx #10
    bne @e
    ldy AX_T1
    lda #$FF
    sta AX_LIST,y
    rts
.endproc

; ax_union: AX_U* = bbox of the NEW box (+ the OLD box when present)
.proc ax_union
    lda CXA_DCOL0
    sta AX_UX0
    lda CXA_DY0
    sta AX_UY0
    lda CXA_COLS
    asl
    clc
    adc CXA_DCOL0
    sta AX_UX1
    lda CXA_ROWS
    asl
    asl
    asl
    clc
    adc CXA_DY0
    sta AX_UY1
    lda CXA_OCOLS
    beq @out
    lda CXA_ODCOL0
    cmp AX_UX0
    bcs :+
    sta AX_UX0
:   lda CXA_ODY0
    cmp AX_UY0
    bcs :+
    sta AX_UY0
:   lda CXA_OCOLS
    asl
    clc
    adc CXA_ODCOL0
    cmp AX_UX1
    bcc :+
    sta AX_UX1
:   lda CXA_OROWS
    asl
    asl
    asl
    clc
    adc CXA_ODY0
    cmp AX_UY1
    bcc @out
    sta AX_UY1
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; aux_group: draw the current object -- compose its NEW box, then the cells
; of its OLD box the new one no longer covers (its trail).
.proc aux_group
    jsr ax_union
    jsr ax_prefilter
    lda CXA_DCOL0
    sta AX_BX0
    lda CXA_DY0
    sta AX_BY0
    lda CXA_COLS
    sta AX_BC
    lda CXA_ROWS
    sta AX_BR
    jsr ax_box
    lda CXA_OCOLS
    beq @out
    sta AX_BC
    lda CXA_ODCOL0
    sta AX_BX0
    lda CXA_ODY0
    sta AX_BY0
    lda CXA_OROWS
    sta AX_BR
    jsr ax_box_ex
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; aux_sweep: every DYING entry (bit7): compose its box with itself excluded
; (bg + the live others = its erase), then clear it.
.proc aux_sweep
    ldx #9
@e: stx AX_T1+1                  ; (AX_BX0.. are free here; keep X in $01E8)
    stx AX_NT
    jsr ax_entry
    lda (tmpL)
    bpl @n
    ldy #1
    lda (tmpL),y
    sta AX_BX0
    iny
    lda (tmpL),y
    sta AX_BY0
    iny
    lda (tmpL),y
    sta AX_BC
    iny
    lda (tmpL),y
    sta AX_BR
    lda AX_BC
    beq @clr
    lda AX_BX0                   ; prefilter on this box alone
    sta AX_UX0
    lda AX_BY0
    sta AX_UY0
    lda AX_BC
    asl
    clc
    adc AX_BX0
    sta AX_UX1
    lda AX_BR
    asl
    asl
    asl
    clc
    adc AX_BY0
    sta AX_UY1
    jsr ax_prefilter
    jsr ax_box
@clr:
    ldx AX_NT
    jsr ax_entry
    lda #0
    sta (tmpL)
@n: ldx AX_NT
    dex
    bpl @e
    rts
.endproc
