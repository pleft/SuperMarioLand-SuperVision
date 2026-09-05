; ===========================================================================
; THE GAME ENDING (after 4-3; docs/46 -- every position, tile and timing is
; from the GB capture). Runs at $1500 (the overlay window) from the E43 blob
; that the L13E boot stub pulls out of page 12 after the tally. The 38 sprite
; tiles (tools/extract_ending.py) sit in the HUD shadow ($1D00) -- the HUD is
; blank for the ending -- and are blitted like any sprite via src_ptr.
; RAM: $1B00-$1B77 a 6-row text buffer (rows 4..9) so sprites can erase over
; the typed text; $1B80+ the actors' state. FIXED is untouched (it is full):
; the fixed jmp l3e_room == jmp $1500 lands on e43_entry once the blob is in.
; ===========================================================================
.include "supervision.inc"
.include "w2abi.inc"
.include "ending_map.inc"
.setcpu "65C02"

TILES   = $1D00                  ; E43T_xx * 16 + TILES = the SV tile bytes
TXTBUF  = $1C40                  ; 6 rows x 20 cells, rows 4..9 (0 = blank); $1C40-$1CB7 (free + the dead composer stash)
TXR0    = 4
st      = $1C00
tt      = $1C01
tth     = $1C02
mx      = $1C03
my      = $1C04
dxv     = $1C05
dyv     = $1C06
hx      = $1C07
hy      = $1C08
px      = $1C09
py      = $1C0A
txi     = $1C0B                  ; typewriter: frames until the next glyph
txr     = $1C0C
txc     = $1C0D
txp     = $1C0E                  ; 2: the text script pointer
bgc43   = $1C10                  ; 2: 4-3's BG charset (bricks); bgc = font otherwise
pose    = $1C12
cx0     = $1C13                  ; 3 clouds
cx1     = $1C14
cx2     = $1C15
bph     = $1C16                  ; brick scroll phase (0/1 = A/B swapped)
crd     = $1C17                  ; credit pair index
ex      = $1C18                  ; erase box: px, py, w(tiles), h(tiles)
ey      = $1C19
ew      = $1C1A
eh      = $1C1B
sl0     = $1C1C                  ; 4 slots of a 16x16 sprite: TL TR BL BR
sl1     = $1C1D
sl2     = $1C1E
sl3     = $1C1F
acc     = $1C20                  ; sub-pixel accumulators
txc0    = $1C21                  ; typewriter: home column
crdt    = $1C22                  ; credit hold timer (2 bytes)
crdth   = $1C23
kiss    = $1C24                  ; 1 = kiss poses in effect
ecnt    = $1C25                  ; erase_box column counter

BRK_A = $69
BRK_B = $6A
BRK_C = $6F
FLOOR_Y = 104                    ; sprite top for Mario/Daisy/plane on the floor
room    = $1C29                  ; 1 = the brick ceiling/floor still stands
cy0     = $1C2A
cy1     = $1C2B
cy2     = $1C2C
pw      = $1C2D                  ; plane: 0 = empty (taxi), 1 = with the riders

.segment "E43"
e43_entry:
    jmp e43_frame                ; $1500: what l3e_seq's "jmp l3e_room" now reaches

.proc e43_frame
    stz vxp                      ; the IRQ writes the playfield scroll from vxp/vyp;
    stz vxph                     ; the NMI from the *_ap latches (only hud_go refreshes
    stz vyp                      ; them, and hud_go must stay 0: the HUD shadow holds
    stz vxph_ap                  ; our sprite tiles) -- zero all of it every frame
    stz vyp_ap
    stz scroll_s
    stz ring_b
    stz ring_b+1
    lda st                       ; push/rts dispatch: the core's jmp (abs,x) is broken
    asl                          ; (adds X to the fetched target -- docs/35 E43)
    tax
    lda @tab+1,x
    pha
    lda @tab,x
    pha
    rts
@tab: .word s_init-1, s_text1-1, s_walk-1, s_heart-1, s_text3-1, s_scroll-1, s_board-1, s_takeoff-1, s_flight-1, s_credits-1
.endproc

; ---------------------------------------------------------------------------
; helpers
; ---------------------------------------------------------------------------
.proc use_font
    lda #<bg_chardata
    sta bgc
    lda #>bg_chardata
    sta bgc+1
    rts
.endproc
.proc use_bricks
    lda bgc43
    sta bgc
    lda bgc43+1
    sta bgc+1
    rts
.endproc
.proc set_cell                   ; X = col, Y = row -> dy/dcol
    tya
    asl
    asl
    asl
    sta dy
    txa
    asl
    sta dcol
    rts
.endproc
.proc cell_clear                 ; X = col, Y = row: 8 rows x 2 bytes of 0
    jsr set_cell
    jsr set_dst
    ldy #0
    ldx #8
@r: lda #0
    sta (dst_ptr),y
    iny
    sta (dst_ptr),y
    dey
    lda dst_ptr
    clc
    adc #48
    sta dst_ptr
    bcc :+
    inc dst_ptr+1
:   dex
    bne @r
    rts
.endproc
.proc cell_tile                  ; A = BG tile (bgc chosen by the caller), X = col, Y = row
    pha
    jsr set_cell
    pla
    jsr get_tile_src
    jsr set_dst
    jmp blit_tile
.endproc
.proc buf_index                  ; X = col, Y = row (4..9) -> X = TXTBUF index
    tya
    sec
    sbc #TXR0
    sta tmpL3
    asl
    asl
    adc tmpL3
    asl
    asl
    sta tmpL3
    txa
    clc
    adc tmpL3
    tax
    rts
.endproc
.proc cell_put                   ; A = font tile (0 = blank), X = col, Y = row; rows 4..9 buffered
    sta tmpH3
    cpy #TXR0
    bcc @draw
    cpy #TXR0+6
    bcs @draw
    phx
    jsr buf_index
    lda tmpH3
    sta TXTBUF,x
    plx
@draw:
    lda tmpH3
    beq @blank
    jsr use_font
    lda tmpH3
    jmp cell_tile
@blank:
    jmp cell_clear
.endproc
.proc cell_redraw                ; X = col, Y = row -> bricks / buffered text / sky
    lda room
    beq @norm
    cpy #2
    beq @brkC
    cpy #16
    beq @brkC
    cpy #3
    beq @brkAB
    cpy #15
    beq @brkAB
@norm:
    cpy #TXR0
    bcc @sky
    cpy #TXR0+6
    bcs @sky
    phx
    jsr buf_index
    lda TXTBUF,x
    plx
    cmp #0                       ; (PLX set Z from the column)
    beq @sky
    pha
    jsr use_font
    pla
    jmp cell_tile
@sky:
    jmp cell_clear
@brkC:
    jsr use_bricks
    lda #BRK_C
    jmp cell_tile
@brkAB:
    jsr use_bricks
    txa
    clc
    adc bph
    and #1
    beq :+
    lda #BRK_B
    jmp cell_tile
:   lda #BRK_A
    jmp cell_tile
.endproc
.proc row_redraw                 ; Y = row: all 20 cells
    ldx #0
@c: phy
    phx
    jsr cell_redraw
    plx
    ply
    inx
    cpx #20
    bne @c
    rts
.endproc
.proc row_clear                  ; Y = row: blank it (and its buffer cells)
    ldx #0
@c: phy
    phx
    lda #0
    jsr cell_put
    plx
    ply
    inx
    cpx #20
    bne @c
    rts
.endproc
.proc erase_box                  ; ex,ey px; ew,eh tiles -> redraw every cell touched
    lda ey
    lsr
    lsr
    lsr
    sta tmpL
    lda ey
    and #7
    beq :+
    inc eh
:   lda ex
    lsr
    lsr
    lsr
    sta tmpH
    lda ex
    and #7
    beq :+
    inc ew
:   ldy tmpL
@row:
    ldx tmpH
    lda ew
    sta ecnt
@col:
    cpx #20
    bcs @nc
    phy
    phx
    jsr cell_redraw
    plx
    ply
@nc:
    inx
    dec ecnt
    bne @col
    iny
    dec eh
    bne @row
    rts
.endproc
.proc erase_at                   ; X = px, Y = py, A = width in tiles (height 2)
    stx ex
    sty ey
    sta ew
    lda #2
    sta eh
    jmp erase_box
.endproc
.proc spr8                       ; A = tile slot, X = px, Y = py (transparent; do_flip/blit_behind as set)
    sty dy
    pha
    txa
    lsr
    lsr
    sta dcol
    txa
    and #3
    sta spr_subx
    pla
    stz src_ptr+1
    asl
    asl
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1                ; slot*16 (up to 608)
    clc
    adc #<TILES
    sta src_ptr
    lda src_ptr+1
    adc #>TILES
    sta src_ptr+1
    jsr set_dst
    stz blit_opaque
    jmp sprite_blit_subpx
.endproc
; draw_id: A = sprite list id, X = px, Y = py. A list is [slot, dx, dy]... $FF.
.proc draw_id
    stx tmpL
    sty tmpH
    asl
    tax
    lda lists,x
    sta tmpL2
    lda lists+1,x
    sta tmpH2
    ldy #0
@e: lda (tmpL2),y
    cmp #$FF
    beq @done
    pha
    iny
    lda (tmpL2),y
    clc
    adc tmpL
    bcs @skip                    ; off the right edge: a piece past x 183 would wrap
    cmp #160                     ; into the next line (the stride is 48 bytes)
    bcs @skip
    tax
    iny
    lda (tmpL2),y
    clc
    adc tmpH
    iny
    phy
    tay
    pla
    sta ecnt                     ; (stash Y past the blit)
    pla
    jsr spr8
    ldy ecnt
    bra @e
@skip:
    pla
    iny
    iny
    bra @e
@done:
    stz do_flip
    stz blit_behind
    rts
.endproc
L_MSTAND = 0
L_MKISS  = 1
L_DSTAND = 2
L_DWALK  = 3
L_DKISS  = 4
L_PEMPTY = 5
L_PFULL  = 6
L_PPROP  = 7
L_CLOUD  = 8
lists: .word l_mstand, l_mkiss, l_dstand, l_dwalk, l_dkiss, l_pempty, l_pfull, l_pprop, l_cloud
l_mstand: .byte E43T_20,0,0, E43T_21,8,0, E43T_30,0,8, E43T_31,8,8, $FF
l_mkiss:  .byte E43T_24,0,0, E43T_25,8,0, E43T_34,0,8, E43T_35,8,8, $FF
l_dstand: .byte E43T_49,0,0, E43T_4E,8,0, E43T_51,0,8, E43T_50,8,8, $FF   ; (x-flipped)
l_dwalk:  .byte E43T_49,0,0, E43T_48,8,0, E43T_4B,0,8, E43T_4A,8,8, $FF   ; (x-flipped)
l_dkiss:  .byte E43T_2E,0,0, E43T_2F,8,0, E43T_3E,0,8, E43T_3F,8,8, $FF
l_pempty: .byte E43T_4F,8,0, E43T_3C,8,8, E43T_2D,16,0, E43T_3D,16,8, $FF          ; GB $2F OAM (col 0 = blank $2C)
l_pfull:  .byte E43T_0E,0,0, E43T_1E,0,8, E43T_4F,9,0, E43T_3C,9,8, E43T_2D,17,0, E43T_3D,17,8, E43T_4C,25,0, E43T_4D,25,8, $FF   ; GB $30 OAM
l_pprop:  .byte E43T_26,0,0, E43T_27,0,8, E43T_4F,9,0, E43T_3C,9,8, E43T_2D,17,0, E43T_3D,17,8, E43T_4C,25,0, E43T_4D,25,8, $FF   ; GB $36 OAM
l_cloud:  .byte E43T_7C,0,8, E43T_7D,8,8, E43T_7E,16,8, E43T_61,8,0, E43T_6F,16,0, E43T_7B,24,0, $FF             ; GB $32 OAM (behind the BG)

.proc draw_mario
    lda kiss
    beq :+
    lda #L_MKISS
    bne :++
:   lda #L_MSTAND
:   ldx mx
    ldy my
    jmp draw_id
.endproc
.proc draw_daisy
    lda kiss
    bne @k
    lda #1
    sta do_flip                  ; standing/walking are x-flipped on the GB
    lda pose
    and #1
    beq :+
    lda #L_DWALK
    bne @go
:   lda #L_DSTAND
    bra @go
@k: lda #L_DKISS
@go:
    ldx dxv
    ldy dyv
    jmp draw_id
.endproc
.proc draw_plane                 ; pw: 0 empty, 1 riders (+ the 4-frame propeller)
    lda pw
    beq :+
    lda tt
    and #4
    beq :++
    lda #L_PPROP
    bne @go
:   lda #L_PEMPTY
    bra @go
:   lda #L_PFULL
@go:
    ldx px
    ldy py
    jmp draw_id
.endproc
.proc erase_plane
    ldx px
    ldy py
    lda #5
    jmp erase_at
.endproc
.proc erase_mario
    ldx mx
    ldy my
    lda #2
    jmp erase_at
.endproc
.proc erase_daisy
    ldx dxv
    ldy dyv
    lda #2
    jmp erase_at
.endproc
.proc draw_room
    ldy #2
    jsr row_redraw
    ldy #3
    jsr row_redraw
    ldy #15
    jsr row_redraw
    ldy #16
    jmp row_redraw
.endproc
.proc modz                       ; A = period -> Z=1 when tt is a multiple of it
    sta tmpL3
    lda tt
@m: sec
    sbc tmpL3
    bcs @m
    adc tmpL3
    rts
.endproc
.proc type_start                 ; A/X = script lo/hi (page 12), Y = row, tmpL = col
    sta txp
    stx txp+1
    sty txr
    lda tmpL
    sta txc
    sta txc0
    lda #1
    sta txi
    rts
.endproc
.proc fetch_txt                  ; A = next script byte (page 12), txp advanced. The
    lda txp                      ; blob runs from RAM so the dance is safe (E36); bank 1
    sta tmpL2                    ; is back before anything else runs.
    lda txp+1
    sta tmpH2
    stz LINK_DATA
    lda #12
    sta LINK_DDR
    lda #$0F
    sta LCD_DRIVE
    lda (tmpL2)
    pha
    stz LINK_DATA
    lda #1
    sta LINK_DDR
    lda #$0F
    sta LCD_DRIVE
    inc txp
    bne :+
    inc txp+1
:   pla
    rts
.endproc
.proc type_glyph                 ; one script byte: glyph / $FE newline / $FD credits name line /
    jsr fetch_txt                ; $FC wrap to the credits / $FF end (C=1, typewriter idle)
    cmp #$FF
    bne :+
    stz txi
    sec
    rts
:   cmp #$FE
    bne :+
    inc txr
    lda txc0
    sta txc
    clc
    rts
:   cmp #$FD
    bne :+
    inc txr
    inc txr
    lda #7
    sta txc
    clc
    rts
:   cmp #$FC
    bne @g
    lda #<credits
    sta txp
    lda #>credits
    sta txp+1
    bra type_glyph
@g: ldx txc
    ldy txr
    jsr cell_put
    inc txc
    clc
    rts
.endproc
.proc type_step                  ; one glyph / 12 f; C=1 once the script has ended
    lda txi
    beq @end
    dec txi
    bne @clc
    lda #12
    sta txi
    jmp type_glyph
@end:
    sec
    rts
@clc:
    clc
    rts
.endproc
.proc next_state
    inc st
    stz tt
    stz tth
    rts
.endproc
.proc tick
    inc tt
    bne :+
    inc tth
:   rts
.endproc
.macro AT_FRAME n, lbl           ; branch to lbl unless tt/tth == n (tick runs once per frame)
    lda tth
    cmp #>n
    bne lbl
    lda tt
    cmp #<n
    bne lbl
.endmacro
.proc clouds_step                ; every other frame: erase, x-1 (wrap), draw (behind the BG)
    lda tt
    and #1
    bne @rts
    ldx #2
@c: phx
    lda cx0,x                    ; erase the old spot (erase_at skips columns >= 20)
    ldy cy0,x
    tax
    lda #4
    jsr erase_at
    plx
    phx
    lda cx0,x
    beq @wrap
    dec cx0,x
    bra @dr
@wrap:
    lda tt
    and #$3F
    clc
    adc #180
    sta cx0,x
@dr:
    lda cx0,x                    ; (draw_id clips the off-screen pieces)
    ldy cy0,x
    tax
    lda #1
    sta blit_behind
    lda #L_CLOUD
    jsr draw_id
@next:
    plx
    dex
    bpl @c
@rts:
    rts
.endproc

.proc corridor_step              ; A = frames per cell: bricks swap phase, row 8 text shifts left
    jsr modz
    bne @rts
    lda bph
    eor #1
    sta bph
    lda room
    beq @text
    ldy #3
    jsr row_redraw
    ldy #15
    jsr row_redraw
@text:
    ldx #0
:   lda TXTBUF+81,x
    sta TXTBUF+80,x
    inx
    cpx #19
    bne :-
    stz TXTBUF+99
    ldy #8
    jmp row_redraw
@rts:
    rts
.endproc

; ---------------------------------------------------------------------------
; states (frame counts from the GB log, docs/46)
; ---------------------------------------------------------------------------
.proc s_init
    lda #1
    sta e_own
    lda bgc
    sta bgc43
    lda bgc+1
    sta bgc43+1
    jsr clear_vram
    ldy #0
    tya
:   sta $5E00,y
    sta $5F00,y
    iny
    bne :-
    ldx #119
:   stz TXTBUF,x
    dex
    bpl :-
    ldx #$1D                     ; kiss, pose, bph, pw, the clouds, crdt... = 0
:   stz pose,x
    dex
    bpl :-
    lda #1
    sta room
    jsr draw_room
    lda #41                      ; GB OAM: Mario (41,104), Daisy (103,104)
    sta mx
    lda #FLOOR_Y
    sta my
    sta dyv
    lda #103
    sta dxv
    jsr draw_mario
    jsr draw_daisy
    lda #5
    sta tmpL
    lda #<txt1
    ldx #>txt1
    ldy #5
    jsr type_start
    jmp next_state
.endproc
.proc s_text1                    ; GB $2A: "OH! DAISY"/"DAISY" typed, then 18 f
    jsr type_step
    bcc @rts
    jsr tick
    lda tt
    cmp #18
    bcc @rts
    lda #2
    sta tmpL
    lda #<txt2
    ldx #>txt2
    ldy #8
    jsr type_start
    jmp next_state
@rts:
    rts
.endproc
.proc s_walk                     ; GB $2B: Daisy 103 -> 50 at 1 px / 4 f while "THANK YOU MARIO." types
    jsr type_step
    jsr tick
    lda tt
    and #3
    bne @rts
    jsr erase_daisy
    dec dxv
    lda tt
    and #8
    beq :+
    lda #1
:   sta pose
    jsr draw_daisy
    lda dxv
    cmp #50
    bne @rts
    stz pose
    jsr draw_daisy
    lda #71                      ; the heart: GB OAM (91,79) -> screen (71,75)
    sta hx
    lda #75
    sta hy
    jmp next_state
@rts:
    rts
.endproc
.proc s_heart                    ; GB $2C: the heart rises 60 px (1 px / 3 f here)
    jsr type_step
    jsr tick
    lda #3
    jsr modz
    bne @rts
    ldx hx
    ldy hy
    lda #1
    jsr erase_at
    dec hy
    lda #E43T_84
    ldx hx
    ldy hy
    jsr spr8
    lda hy
    cmp #15
    bne @rts
    ldx hx                       ; gone at the top; GB $2C then blanks rows 5..8
    ldy hy
    lda #1
    jsr erase_at
    ldy #5
:   phy
    jsr row_clear
    ply
    iny
    cpy #9
    bne :-
    lda #0
    sta tmpL
    lda #<txt3
    ldx #>txt3
    ldy #8
    jsr type_start
    jmp next_state
@rts:
    rts
.endproc
.proc s_text3                    ; GB $2D: "-YOUR QUEST IS OVER-", then the kiss poses
    jsr type_step
    bcc @rts
    jsr erase_mario
    jsr erase_daisy
    lda #1
    sta kiss
    jsr draw_daisy
    jsr draw_mario
    lda #232                     ; the plane waits off the right edge
    sta px
    lda #FLOOR_Y
    sta py
    stz pw
    jmp next_state
@rts:
    rts
.endproc
.proc s_scroll                   ; GB $2E, 472 f: the room slides left; Mario walks to the plane
    jsr tick
    lda #20
    jsr corridor_step
    lda #19
    jsr modz
    bne @plane
    lda mx
    cmp #66
    bcs @plane
    jsr erase_mario
    inc mx
    jsr draw_mario
    jsr draw_daisy
@plane:
    lda #5
    jsr modz
    bne @end
    lda px
    cmp #49
    bcc @end
    jsr erase_plane
    dec px
    dec px
    jsr draw_plane
@end:
    AT_FRAME 472, @rts
    jmp next_state
@rts:
    rts
.endproc
.proc s_board                    ; GB $2F, 64 f: they board (sprites vanish)
    jsr tick
    lda tt
    cmp #1
    bne :+
    jsr erase_mario
    jsr erase_daisy
    jsr draw_plane
:   lda tt
    cmp #64
    bcc @rts
    lda #1
    sta pw
    jsr erase_plane
    jsr draw_plane
    jmp next_state
@rts:
    rts
.endproc
.proc s_takeoff                  ; GB $30: 1 px / 2 f up to y 66
    jsr tick
    lda tt
    and #1
    bne @rts
    jsr erase_plane
    dec py
    jsr draw_plane
    lda py
    cmp #66
    bne @rts
    lda #160
    sta cx0
    lda #26
    sta cy0
    lda #224
    sta cx1
    lda #6
    sta cy1
    lda #192
    sta cx2
    lda #50
    sta cy2
    jmp next_state
@rts:
    rts
.endproc
.proc s_flight                   ; GB $31/$32, ~545 f: the corridor rolls by, clouds pass
    jsr tick
    lda #8
    jsr corridor_step
    lda tt
    and #3
    bne :+
    jsr erase_plane
    jsr draw_plane
:   jsr clouds_step
    AT_FRAME 545, @rts
    stz room                     ; the corridor is gone: the credits roll from here
    ldy #2
    jsr row_clear
    ldy #3
    jsr row_clear
    ldy #15
    jsr row_clear
    ldy #16
    jsr row_clear
    lda #<credits
    sta txp
    lda #>credits
    sta txp+1
    stz crdt
    stz crdth
    jmp next_state
@rts:
    rts
.endproc
.proc s_credits                  ; pairs: role row 15 col 2, name row 17 col 7 (one at a time), 400 f each; loops
    jsr tick
    lda tt
    and #3
    bne :+
    jsr erase_plane
    jsr draw_plane
:   jsr clouds_step
    lda crdt
    ora crdth
    bne @hold
    lda #15
    sta txr
    lda #2
    sta txc
    sta txc0
@all:
    jsr type_glyph               ; the whole pair at once (GB: the tilemap rows are written in one frame)
    bcc @all
    lda #<400
    sta crdt
    lda #>400
    sta crdth
    rts
@hold:
    lda crdt
    bne :+
    dec crdth
:   dec crdt
    lda crdt
    ora crdth
    bne @rts
    ldy #15
    jsr row_clear
    ldy #17
    jsr row_clear
@rts:
    rts
.endproc

; ---------------------------------------------------------------------------
; text, stored in page 12 (E43D at $A300) and read through fetch_txt
; (GB font ids: A-Y $0A-$22, '.' $23, '!' $28, '-' $29, 'Z' $27, space $2C)
; ---------------------------------------------------------------------------
.segment "E43D"
txt1: .byte $18,$11,$28,$2C,$0D,$0A,$12,$1C,$22,$FE,$2C,$2C,$2C,$2C,$0D,$0A,$12,$1C,$22,$FF   ; OH! DAISY / (indent 4) DAISY
txt2: .byte $1D,$11,$0A,$17,$14,$2C,$22,$18,$1E,$2C,$16,$0A,$1B,$12,$18,$23,$FF               ; THANK YOU MARIO.
txt3: .byte $29,$22,$18,$1E,$1B,$2C,$1A,$1E,$0E,$1C,$1D,$2C,$12,$1C,$2C,$18,$1F,$0E,$1B,$29,$FF ; -YOUR QUEST IS OVER-
credits: .byte $19,$1B,$18,$0D,$1E,$0C,$0E,$1B,$FD,$10,$23,$22,$18,$14,$18,$12,$FF,$0D,$12,$1B,$0E,$0C,$1D,$18,$1B,$FD,$1C,$23,$18,$14,$0A,$0D,$0A,$FF,$19,$1B,$18,$10,$1B,$0A,$16,$16,$0E,$1B,$FD,$16,$23,$22,$0A,$16,$0A,$16,$18,$1D,$18,$FF,$19,$1B,$18,$10,$1B,$0A,$16,$16,$0E,$1B,$FD,$1D,$23,$11,$0A,$1B,$0A,$0D,$0A,$FF,$0D,$0E,$1C,$12,$10,$17,$FD,$11,$23,$16,$0A,$1D,$1C,$1E,$18,$14,$0A,$FF,$1C,$18,$1E,$17,$0D,$FD,$11,$23,$1D,$0A,$17,$0A,$14,$0A,$FF,$0A,$16,$12,$0D,$0A,$FD,$16,$23,$22,$0A,$16,$0A,$17,$0A,$14,$0A,$FF,$0D,$0E,$1C,$12,$10,$17,$FD,$16,$0A,$1C,$11,$12,$16,$18,$FF,$1C,$19,$0E,$0C,$12,$0A,$15,$2C,$1D,$11,$0A,$17,$14,$1C,$2C,$1D,$18,$FD,$1D,$0A,$14,$12,$FF,$12,$27,$1E,$1C,$11,$12,$FD,$17,$0A,$10,$0A,$1D,$0A,$FF,$14,$0A,$17,$18,$11,$FD,$17,$12,$1C,$11,$12,$27,$0A,$20,$0A,$FF,$FC   ; 11 role/name pairs (GB $1557): role, $FD, name, $FF ... $FC = wrap
