; W3AUX -- the save-under composer (docs/42). Lives at $A620 in PAGE 8:
; make_512k lays that page out as [bank-1 prefix copy][THIS BLOB][$FF...].
; Reached ONLY via the plain-$2021 dance (the W3LINK mechanism); NEVER via
; SYS_CTRL bit5 (every SYS_CTRL write restarts the LCD scan -- docs/42).
;
; Everything here touches RAM or FIXED only: the shift tables (shtab
; $0200/$0600), MASKTAB ($0600 page 0), set_dst, zp scratch, the contexts in
; the video-RAM tail. It never reads the map or any banked data -- that is
; the point of save-under: the context holds the pristine background bytes
; under the sprite, saved from VRAM (correct by induction), so a move is
; "write back the vacated cells, save+compose the new ones", all single
; stores. The sprite is never absent from VRAM => no flicker, ever, even
; when the frame overruns and the beam catches the render mid-way.

.include "w2abi.inc"

MASKTAB     = $0600              ; transparency mask of a 2bpp byte (shtab_hi p0)
shtab_lo    = $0200              ; boot-built shift tables (page = subx)
VSTRIDE     = $30

; --- the context: the kit window's TAIL ($1500+$6xx code, cap asserted by
; pack_banks at $1C5F) -- RAM, persists across frames, and the level-load
; window copy plus kit init reset it for free. NOT the VRAM tail: the fb is
; a RING of $1FE0 bytes ($4000-$5FDF) and $5E00 sits inside it (docs/42).
CTX0        = $1C60              ; one context, 152 bytes ($1C60-$1CF7)
AUX_TILES   = $1FA0              ; 4 x 16B FINAL tile pixels ($1FA0-$1FDF;
                                 ; $1F80 = W3CTAG, $1FE0+ spare)
CX_OWN      = $1FE0              ; composing slot + 1 (0 = free)
; ctx: +0 active($80)  +1 dcol0  +2 dy0  +3 cols  +4 rows
;      +5/+6 ring_b snapshot (the DMA shift moves the whole ring: the stash
;      re-bases dcol0 by the ring delta so cell identity survives)
;      +8 saved[9*16]

; --- scratch: stack page (live stack floor observed at $01ED) --------------
SCRATCH     = $0136              ; 9 x 16 = 144B: the NEW saved-bg assembly
AXV_DCOL0   = $01C6              ; NEW box: ring byte col of cell (0,0) (even)
AXV_DY0     = $01C7              ; NEW box: pixel row of cell (0,0) (mult 8)
AXV_COLS    = $01C8              ; 1..3
AXV_ROWS    = $01C9              ; 1..3
AXV_NT      = $01CA              ; 1..4 sprite tiles
AXV_TX      = $01CB              ; 4B tile x (px, relative to the box origin)
AXV_TY      = $01CF              ; 4B tile y
AXV_CI      = $01D3              ; cell walkers
AXV_RJ      = $01D4
AXV_TN      = $01D5
AXV_BCASE   = $01D6              ; x byte-offset case 0..3
AXV_DYT     = $01D7              ; tile dy vs current cell (signed)
AXV_B0      = $01D8              ; current tile row bytes
AXV_B1      = $01D9
AXV_S0      = $01DA              ; shifted row bytes
AXV_S1      = $01DB
AXV_S2      = $01DC
AXV_R       = $01DD              ; source row
AXV_BRB     = $01DE              ; dest row *2 in the cell buffer
AXV_OCI     = $01DF              ; cell delta: old index = new index + delta
AXV_ORJ     = $01E0
AXV_ACT     = $01E1              ; ctx active snapshot
AXV_S       = $01E2              ; mix scratch
AXV_MIX     = $01E3              ; mix target index

.segment "AUX"

; aux_ping: infrastructure proof (harness/battery).
.proc aux_ping
    lda #$77
    sta $0135
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_dst: dst_ptr = the VRAM cell (AXV_CI/RJ) of the NEW box.
; C=1: the cell is past the 48-byte ring row -- never displayed, skip whole.
.proc ax_dst
    lda AXV_CI
    asl
    clc
    adc AXV_DCOL0
    cmp #48
    bcs @skip
    sta dcol
    lda AXV_RJ
    asl
    asl
    asl
    clc
    adc AXV_DY0
    sta dy
    jsr set_dst
    clc
    rts
@skip:
    sec
    rts
.endproc

; ax_odst: the same for an OLD-box cell (box read from the ctx at tmpL).
.proc ax_odst
    ldy #1
    lda AXV_CI
    asl
    clc
    adc (tmpL),y
    cmp #48
    bcs @skip
    sta dcol
    ldy #2
    lda AXV_RJ
    asl
    asl
    asl
    clc
    adc (tmpL),y
    sta dy
    jsr set_dst
    clc
    rts
@skip:
    sec
    rts
.endproc

; ax_sptr: tmpL2 -> &SCRATCH[(AXV_RJ*3 + AXV_CI) * 16]
.proc ax_sptr
    lda AXV_RJ
    asl
    adc AXV_RJ                   ; rj*3 (rj<=2: asl leaves C=0)
    clc
    adc AXV_CI
    asl
    asl
    asl
    asl
    clc
    adc #<SCRATCH
    sta tmpL2
    lda #>SCRATCH
    adc #0
    sta tmpH2
    rts
.endproc

; ax_kptr: tmpL3 -> &ctx.saved[(X=rj)*3 + (A=ci)]  (ctx base in tmpL)
.proc ax_kptr
    sta AXV_S                    ; ci
    txa
    asl
    adc AXV_S                    ; rj*2 + ci (rj<=2: C=0 after asl)
    sta AXV_S
    txa
    clc
    adc AXV_S                    ; rj*3 + ci
    asl
    asl
    asl
    asl                          ; *16 (<= 128)
    clc
    adc #8
    clc
    adc tmpL
    sta tmpL3
    lda tmpH
    adc #0
    sta tmpH3
    rts
.endproc

; ax_rd16: the VRAM cell at dst_ptr -> 16 bytes at (tmpL2). Clobbers tmpL3.
.proc ax_rd16
    lda dst_ptr
    sta tmpL3
    lda dst_ptr+1
    sta tmpH3
    ldx #8
@r: lda (tmpL3)
    sta (tmpL2)
    ldy #1
    lda (tmpL3),y
    sta (tmpL2),y
    lda tmpL3
    clc
    adc #VSTRIDE
    sta tmpL3
    bcc :+
    inc tmpH3
:   lda tmpL2
    clc
    adc #2
    sta tmpL2
    bcc :+
    inc tmpH2
:   dex
    bne @r
    rts
.endproc

; ax_wr16: 16 bytes at (tmpL3) -> the VRAM cell at dst_ptr. Clobbers tmpL2.
.proc ax_wr16
    lda dst_ptr
    sta tmpL2
    lda dst_ptr+1
    sta tmpH2
    ldx #8
@r: lda (tmpL3)
    sta (tmpL2)
    ldy #1
    lda (tmpL3),y
    sta (tmpL2),y
    lda tmpL3
    clc
    adc #2
    sta tmpL3
    bcc :+
    inc tmpH3
:   lda tmpL2
    clc
    adc #VSTRIDE
    sta tmpL2
    bcc :+
    inc tmpH2
:   dex
    bne @r
    rts
.endproc

; ---------------------------------------------------------------------------
; ax_mix: masked-merge A into flipbuf[AXV_MIX]. A=0 = wholly transparent.
.proc ax_mix
    beq @out
    sta AXV_S
    tay
    lda MASKTAB,y
    eor #$FF
    ldx AXV_MIX
    and flipbuf,x
    ora AXV_S
    sta flipbuf,x
@out:
    rts
.endproc

; ax_over: overlay sprite tile AXV_TN onto flipbuf for cell (AXV_CI, AXV_RJ).
; dx/dy = tile px - cell px; overlap iff -8 < d < 8. subx = dx & 3 selects a
; shtab page; the byte-offset case = (dx+8)>>2:
;   0 (B=-2): s2 -> buf+0        2 (B= 0): s0 -> buf+0, s1 -> buf+1
;   1 (B=-1): s1 -> buf+0, s2+1  3 (B=+1): s0 -> buf+1
.proc ax_over
    ldx AXV_TN
    lda AXV_CI
    asl
    asl
    asl
    sta AXV_S                    ; ci*8
    lda AXV_TX,x
    sec
    sbc AXV_S                    ; dx
    tay
    clc
    adc #8
    cmp #16
    bcc :+                       ; no x overlap
    jmp @out
:   lsr
    lsr
    sta AXV_BCASE
    tya
    and #3
    clc
    adc #>shtab_lo
    sta p_shlo+1
    stz p_shlo
    tya
    and #3
    clc
    adc #>shtab_lo + 4           ; the hi tables sit 4 pages above
    sta p_shhi+1
    stz p_shhi
    lda AXV_RJ
    asl
    asl
    asl
    sta AXV_S                    ; rj*8
    lda AXV_TY,x
    sec
    sbc AXV_S
    sta AXV_DYT
    clc
    adc #8
    cmp #16
    bcc :+                       ; no y overlap
    jmp @out
:   txa                          ; src = AUX_TILES + tn*16
    asl
    asl
    asl
    asl
    clc
    adc #<AUX_TILES
    sta tmpL3
    lda #>AUX_TILES
    adc #0
    sta tmpH3
    stz AXV_R
@row:
    lda AXV_R
    clc
    adc AXV_DYT                  ; br = r + dy
    cmp #8
    bcc @in                      ; clipped (negatives wrap >= $F8)
    jmp @next
@in:
    asl
    sta AXV_BRB
    lda AXV_R
    asl
    tay
    lda (tmpL3),y
    sta AXV_B0
    iny
    lda (tmpL3),y
    sta AXV_B1
    ldy AXV_B0                   ; s0 = shlo[b0]
    lda (p_shlo),y
    sta AXV_S0
    lda (p_shhi),y               ; s1 = shhi[b0] | shlo[b1]
    sta AXV_S1
    ldy AXV_B1
    lda (p_shlo),y
    ora AXV_S1
    sta AXV_S1
    lda (p_shhi),y               ; s2 = shhi[b1]
    sta AXV_S2
    lda AXV_BCASE
    beq @c0
    cmp #1
    beq @c1
    cmp #2
    beq @c2
    lda AXV_BRB                  ; case 3: s0 -> buf+1
    ina
    sta AXV_MIX
    lda AXV_S0
    jsr ax_mix
    bra @next
@c0:
    lda AXV_BRB                  ; case 0: s2 -> buf+0
    sta AXV_MIX
    lda AXV_S2
    jsr ax_mix
    bra @next
@c1:
    lda AXV_BRB                  ; case 1: s1 -> buf+0, s2 -> buf+1
    sta AXV_MIX
    lda AXV_S1
    jsr ax_mix
    lda AXV_BRB
    ina
    sta AXV_MIX
    lda AXV_S2
    jsr ax_mix
    bra @next
@c2:
    lda AXV_BRB                  ; case 2: s0 -> buf+0, s1 -> buf+1
    sta AXV_MIX
    lda AXV_S0
    jsr ax_mix
    lda AXV_BRB
    ina
    sta AXV_MIX
    lda AXV_S1
    jsr ax_mix
@next:
    inc AXV_R
    lda AXV_R
    cmp #8
    beq @out
    jmp @row
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; aux_compose: draw the object's NEW state, flicker-free.
;   1. assemble the new box's pristine bg into SCRATCH: from the old ctx
;      where the boxes overlap, from VRAM elsewhere (pure bg there).
;   2. per new cell: buf = bg, overlay tiles, single-write to VRAM.
;   3. write back every old cell the new box no longer covers.
;   4. commit: SCRATCH -> ctx.saved, new box, active.
; In: tmpL/tmpH = ctx base; the AXV block + AUX_TILES loaded by phase A.
.proc aux_compose
    lda (tmpL)
    sta AXV_ACT
    bpl @deltas0                 ; inactive: deltas irrelevant
    ldy #1                       ; OCI = (new_dcol0 - old_dcol0) / 2 (signed,
    lda AXV_DCOL0                ; even) -- old index = new index + delta
    sec
    sbc (tmpL),y
    cmp #$80
    ror
    sta AXV_OCI
    ldy #2                       ; ORJ = (new_dy0 - old_dy0) / 8 (signed, x8)
    lda AXV_DY0
    sec
    sbc (tmpL),y
    cmp #$80
    ror
    cmp #$80
    ror
    cmp #$80
    ror
    sta AXV_ORJ
    bra @step1
@deltas0:
    stz AXV_OCI
    stz AXV_ORJ
@step1:
    stz AXV_RJ
@s1r:
    stz AXV_CI
@s1c:
    jsr ax_sptr                  ; tmpL2 -> scratch cell
    lda AXV_ACT
    bpl @fromvram
    lda AXV_CI                   ; old ci = ci + OCI; inside the old box?
    clc
    adc AXV_OCI
    ldy #3
    cmp (tmpL),y                 ; unsigned: negatives wrap high and fail
    bcs @fromvram
    sta AXV_S
    lda AXV_RJ
    clc
    adc AXV_ORJ
    ldy #4
    cmp (tmpL),y
    bcs @fromvram
    tax                          ; rj_old
    lda AXV_S                    ; ci_old
    jsr ax_kptr                  ; tmpL3 -> old saved cell
    ldy #15
:   lda (tmpL3),y
    sta (tmpL2),y
    dey
    bpl :-
    bra @s1n
@fromvram:
    jsr ax_dst
    bcs @zfill                   ; off-ring: content never shown; zero it so
    jsr ax_rd16                  ; a later write-back stays harmless
    bra @s1n
@zfill:
    lda #0
    ldy #15
:   sta (tmpL2),y
    dey
    bpl :-
@s1n:
    inc AXV_CI
    lda AXV_CI
    cmp AXV_COLS
    bne @s1c
    inc AXV_RJ
    lda AXV_RJ
    cmp AXV_ROWS
    bne @s1r
    ; ---- step 2: compose + write every new cell ----
    stz AXV_RJ
@s2r:
    stz AXV_CI
@s2c:
    jsr ax_sptr
    ldy #15                      ; buf = pristine bg
:   lda (tmpL2),y
    sta flipbuf,y
    dey
    bpl :-
    stz AXV_TN
@s2t:
    jsr ax_over
    inc AXV_TN
    lda AXV_TN
    cmp AXV_NT
    bne @s2t
    jsr ax_dst
    bcs @s2n
    lda #<flipbuf
    sta tmpL3
    lda #>flipbuf
    sta tmpH3
    jsr ax_wr16
@s2n:
    inc AXV_CI
    lda AXV_CI
    cmp AXV_COLS
    bne @s2c
    inc AXV_RJ
    lda AXV_RJ
    cmp AXV_ROWS
    bne @s2r
    ; ---- step 3: write back old cells the new box no longer covers ----
    lda AXV_ACT
    bpl @commit
    stz AXV_RJ                   ; AXV_CI/RJ now walk the OLD box
@s3r:
    stz AXV_CI
@s3c:
    lda AXV_CI                   ; new ci = old ci - OCI; inside the new box?
    sec
    sbc AXV_OCI
    cmp AXV_COLS
    bcs @s3w                     ; outside -> write back
    sta AXV_S
    lda AXV_RJ
    sec
    sbc AXV_ORJ
    cmp AXV_ROWS
    bcs @s3w
    bra @s3n                     ; covered by the new image: leave it
@s3w:
    ldx AXV_RJ
    lda AXV_CI
    jsr ax_kptr                  ; tmpL3 -> old saved cell
    jsr ax_odst
    bcs @s3n
    jsr ax_wr16
@s3n:
    inc AXV_CI
    ldy #3
    lda AXV_CI
    cmp (tmpL),y
    bne @s3c
    inc AXV_RJ
    ldy #4
    lda AXV_RJ
    cmp (tmpL),y
    bne @s3r
@commit:
    ; ---- step 4: SCRATCH -> ctx.saved; store the new box; activate ----
    lda tmpL
    clc
    adc #8
    sta tmpL2
    lda tmpH
    adc #0
    sta tmpH2
    ldx #0                       ; 144-byte copy in two Y sweeps
    ldy #0
:   lda SCRATCH,y
    sta (tmpL2),y
    iny
    cpy #144
    bne :-
    ldy #1
    lda AXV_DCOL0
    sta (tmpL),y
    iny
    lda AXV_DY0
    sta (tmpL),y
    iny
    lda AXV_COLS
    sta (tmpL),y
    iny
    lda AXV_ROWS
    sta (tmpL),y
    lda #$80
    sta (tmpL)
    rts
.endproc

; ---------------------------------------------------------------------------
; aux_uncompose: leave composed mode -- write every saved cell back and
; deactivate. Pure writes; the object's image vanishes with its bg restored
; in the same stores (the caller redraws it through the old path if it still
; lives). In: tmpL/tmpH = ctx.
.proc aux_uncompose
    lda (tmpL)
    bmi :+
    rts
:   stz AXV_RJ
@r: stz AXV_CI
@c: ldx AXV_RJ
    lda AXV_CI
    jsr ax_kptr
    jsr ax_odst
    bcs @n
    jsr ax_wr16
@n: inc AXV_CI
    ldy #3
    lda AXV_CI
    cmp (tmpL),y
    bne @c
    inc AXV_RJ
    ldy #4
    lda AXV_RJ
    cmp (tmpL),y
    bne @r
    lda #0
    sta (tmpL)
    rts
.endproc
