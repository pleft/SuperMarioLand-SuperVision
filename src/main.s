; Super Mario Land — Watara Supervision port.
; Phase 5: boot + NMI frame loop + input + software renderer (accurate Mario sprite).
; Hardware per docs/20-supervision-hardware.md; port plan per docs/21-port-mapping.md.

.setcpu "65C02"
.include "supervision.inc"
.import chardata             ; OBJ tiles (src/gfxdata.s) — also the $8800 BG tiles $80-$FF
.import bg_chardata          ; BG tiles (level tiles $00-$7F)
.import level0_map           ; World 1-1 tilemap (column-major, 16 tiles/col)
.import jumparc              ; Mario's jump arc table (27 bytes; $7F = apex)
.import speedtab            ; horizontal walk speed table (px/frame)
.import mario_poses          ; 4 poses x 4 tiles (metasprite tiles from ROM $4C37)
.import statusbar_tiles      ; 2x20 status-bar template (ROM $3F9C)

; ---------------------------------------------------------------------------
.segment "ZEROPAGE"
frame_flag:  .res 1          ; set by NMI, consumed by main loop
frame_count: .res 1          ; ++ every NMI (~61 Hz)
pad_held:    .res 1          ; current buttons, GB layout (0A 1B 2Sel 3St 4R 5L 6Up 7Dn)
pad_prev:    .res 1
pad_pressed: .res 1          ; newly pressed this frame
sv_tmp:      .res 1
gb_tmp:      .res 1
fill_val:    .res 1
ptr:         .res 2          ; 16-bit pointer for VRAM fills
; renderer working vars
src_ptr:     .res 2          ; current tile source
dst_ptr:     .res 2          ; current tile dest (VRAM)
cur_src:     .res 2          ; blit_tile internal
cur_dst:     .res 2
row_base:    .res 2          ; VRAM start of current tile-row
trow_cnt:    .res 1
tcol_cnt:    .res 1
scroll_x:    .res 1          ; hardware X scroll (pixels)
scroll_y:    .res 1          ; hardware Y scroll (scanlines)
spr_col:     .res 1          ; player sprite byte-column (0..38; 1 col = 4 px)
spr_y:       .res 1          ; player sprite top scanline (0..144)
prev_col:    .res 1          ; last drawn position (for erase)
prev_y:      .res 1
dcol:        .res 1          ; set_dst input: byte column
dy:          .res 1          ; set_dst input: scanline
tmpL:        .res 1
tmpH:        .res 1
tmp_src:     .res 1
tmp_mask:    .res 1
bg_col:      .res 1          ; background render: level column 0..19
bg_row:      .res 1          ; background render: tile row 0..15
map_ptr:     .res 2          ; pointer into the level tilemap
ri:          .res 1          ; restore_bg col offset 0..2
rj:          .res 1          ; restore_bg row offset 0..2
t_col:       .res 1          ; restore_bg base tile col
t_row:       .res 1          ; restore_bg base tile row
map_row:     .res 1          ; restore_bg level-map row (= VRAM row - 2 playfield offset)
jump_state:  .res 1          ; 0=on ground, 1=ascending, 2=descending
arc_idx:     .res 1          ; index into jumparc
ground_y:    .res 1          ; the scanline Mario stands on
mario_frame: .res 1          ; current pose index (0 stand, 1/2 walk, 3 jump)
prev_frame:  .res 1          ; last drawn pose
pose_tl:     .res 1          ; the 4 tiles of the current pose
pose_tr:     .res 1
pose_bl:     .res 1
pose_br:     .res 1
mario_facing:.res 1          ; 0 = right, 1 = left (flip)
do_flip:     .res 1          ; draw_quad: blit flipped if nonzero
blit_opaque: .res 1          ; sprite_blit_subpx: 1 = opaque (cover all px) for the status bar
blit_row:    .res 1          ; row counter for the flipped blit (X is used for lookup)
spr_x:       .res 1          ; Mario X in PIXELS (spr_col = spr_x >> 2)
h_hold:      .res 1          ; frames a direction has been held (for accel)
h_idx:       .res 1          ; speed-table index (0/2/4 = accel level)
h_toggle:    .res 1          ; sub-pixel toggle (the game's $C20F)
h_step:      .res 1          ; pixels to move this frame
spr_subx:    .res 1          ; sub-pixel X offset within the byte (spr_x & 3)
prev_x:      .res 1          ; last drawn pixel X
s0:          .res 1          ; sub-pixel blit: shifted source bytes (3)
s1:          .res 1
s2:          .res 1
m0:          .res 1          ; sub-pixel blit: shifted masks (3)
m1:          .res 1
m2:          .res 1
; --- scrolling / camera state ---
cam_x:       .res 2          ; world scroll in PIXELS (level pixels scrolled off the left)
fb_col0:     .res 2          ; world column resident at VRAM byte-col 0 (left of framebuffer)
scroll_s:    .res 1          ; current XSCROLL value (0..28, multiple of 4 = byte-aligned)
prev_scroll_s: .res 1        ; last applied scroll_s (redraw status bar only when it changes)
mario_vx:    .res 1          ; Mario VRAM pixel X = spr_x + scroll_s (so he draws pinned)
prev_vx:     .res 1          ; last drawn mario_vx (for restore_bg)
wcol:        .res 2          ; draw_column input: world column to draw
dbcol:       .res 1          ; draw_column input: dest VRAM byte column
strk:        .res 1          ; scroll streaming loop counter
shift_px:    .res 1          ; pixels the framebuffer shifted this frame (0 or 32 per DMA shift)

.segment "BSS"
revpix:      .res 256        ; reverse the 4 2bpp pixels in a byte (built at boot)

.segment "ZEROPAGE"

; ---------------------------------------------------------------------------
.segment "CODE"

.proc reset
    sei
    cld                      ; 65C02: ensure binary mode
    ldx #$FF
    txs

    ; --- clear zero page ---
    lda #0
    tax
:   sta $00,x
    inx
    bne :-

    ; --- clear WRAM $0200-$1FFF ---
    lda #<$0200
    sta ptr
    lda #>$0200
    sta ptr+1
    ldx #$1E                 ; $1E pages = $0200..$1FFF
    lda #0
@clr:
    ldy #0
:   sta (ptr),y
    iny
    bne :-
    inc ptr+1
    dex
    bne @clr

    ; --- select ROM bank 0 + enable display/NMI BEFORE drawing, so chardata at
    ;     $8000 is mapped while we blit (MAME needs this; Potator defaults to bank 0).
    lda #(SYSCTRL_NMI_EN | SYSCTRL_TIMER_IRQ | SYSCTRL_BANK0)  ; NMI tick + timer IRQ (raster split)
    sta SYS_CTRL

    ; --- LCD setup ---
    lda #$A0                 ; X size (160 px) — verify exact encoding in emulator
    sta LCD_XSIZE
    lda #VRAM_LINES          ; 160 scanlines
    sta LCD_YSIZE
    stz XSCROLL
    stz YSCROLL

    jsr build_revpix             ; pixel-reverse lookup for horizontal sprite flip
    jsr clear_vram
    jsr render_background        ; draw the World 1-1 scene
    jsr render_status_bar        ; status bar (drawn once; pinned by the NMI/IRQ raster split)
    lda #40                      ; place Mario standing on the ground (pixel X)
    sta spr_x
    sta mario_vx                 ; VRAM X = spr_x (cam_x = scroll_s = 0 at boot)
    sta prev_vx
    lda #112                     ; stand on the ground: feet at scanline 128 (level row 14 -> VRAM row 16)
    sta spr_y
    sta prev_y
    sta ground_y
    stz mario_frame              ; standing pose (index)
    stz prev_frame
    jsr draw_player
    cli

main_loop:
    lda frame_flag
    beq main_loop
    stz frame_flag
    jsr read_input
    jsr move_player              ; walk (updates spr_x) or scroll the camera (cam_x)
    jsr jump_player              ; A = jump (real arc); updates spr_y while airborne
    jsr animate_player           ; pick the pose
    ; Order matters because Potator now renders scanline-by-scanline interleaved with the
    ; CPU: anything visible must be drawn BEFORE its scanlines render. So shift+erase+draw
    ; Mario first (he's at scanlines ~112-128), and stream the 4 incoming columns LAST --
    ; they land in the off-screen right margin and aren't visible until later frames, so
    ; their ~30k-cycle blit can safely finish after Mario's rows have already scanned out.
    jsr scroll_update            ; advance camera: framebuffer shift (fast) + scroll_s
    lda prev_vx                  ; if the frame shifted, old Mario moved left with it
    sec
    sbc shift_px
    sta prev_vx
    jsr restore_bg               ; erase old Mario at his (shifted) spot
    lda spr_x                    ; mario_vx = spr_x + scroll_s (drawn pinned under the scroll)
    clc
    adc scroll_s
    sta mario_vx
    jsr draw_player              ; Mario drawn early, before his scanlines render
    lda mario_vx
    sta prev_vx
    lda spr_y
    sta prev_y
    lda mario_frame
    sta prev_frame
    lda shift_px                 ; if we shifted this frame, refill the right margin LAST
    beq main_loop
    jsr stream_cols
    bra main_loop
.endproc

; ---------------------------------------------------------------------------
; jump_player: A starts a jump from the ground; while airborne, step the real
; jump-arc table (ascend: spr_y -= arc; descend: spr_y += arc) until landing.
.proc jump_player
    lda jump_state
    bne @airborne
    ; on the ground: start a jump on a fresh A press
    lda pad_pressed
    and #GB_A
    beq @done
    lda #2                       ; the game seeds the arc index at 2
    sta arc_idx
    lda #1                       ; ascending
    sta jump_state
    bra @done
@airborne:
    cmp #1
    bne @descend
    ; ascending
    ldx arc_idx
    lda jumparc,x
    cmp #$7F                     ; apex marker -> switch to descending
    beq @apex
    sta tmpL
    lda spr_y
    sec
    sbc tmpL
    sta spr_y
    inc arc_idx
    bra @done
@apex:
    lda #2
    sta jump_state
    dec arc_idx                  ; back off the marker
    bra @done
@descend:
    ldx arc_idx
    lda jumparc,x
    clc
    adc spr_y
    sta spr_y
    lda spr_y                    ; landed?
    cmp ground_y
    bcc @stepdown
    lda ground_y
    sta spr_y
    stz jump_state
    bra @done
@stepdown:
    dec arc_idx
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; restore_bg: redraw the 3x3 bg tiles covering the 16x16 sprite at (prev_col, prev_y).
; (Restores the background where Mario used to be, so he composites over the level.)
.proc restore_bg
    lda prev_vx
    lsr
    lsr
    lsr
    sta t_col                    ; base VRAM tile col = prev_vx/8
    lda prev_y
    lsr
    lsr
    lsr
    sta t_row                    ; base tile row = prev_y/8
    stz ri
@cloop:
    stz rj
@rloop:
    lda t_row                    ; VRAM tile row = t_row + rj
    clc
    adc rj
    sta dy                       ; stash VRAM tile row (drives the destination scanline)
    sec                          ; map_row = VRAM row - 2 (playfield sits below status bar)
    sbc #2
    cmp #16                      ; keep only map_row 0..15; <0 wraps to >=$FE so bcs catches it
    bcs @skip                    ;   (status-bar rows 0-1 and below-ground rows are not in map)
    sta map_row
    lda t_col                    ; VRAM tile col = t_col + ri
    clc
    adc ri
    sta dcol                     ; stash VRAM tile col (drives dest byte col)
    clc                          ; world col = fb_col0 + VRAM tile col
    adc fb_col0
    sta map_ptr
    lda fb_col0+1
    adc #0
    sta map_ptr+1
    asl map_ptr                  ; map_ptr = world_col*16 + level0_map
    rol map_ptr+1
    asl map_ptr
    rol map_ptr+1
    asl map_ptr
    rol map_ptr+1
    asl map_ptr
    rol map_ptr+1
    lda map_ptr
    clc
    adc #<level0_map
    sta map_ptr
    lda map_ptr+1
    adc #>level0_map
    sta map_ptr+1
    ldy map_row                  ; level-map row
    lda (map_ptr),y              ; tile number
    jsr get_tile_src
    lda dcol                     ; dcol = tile_col*2
    asl
    sta dcol
    lda dy                       ; dy = VRAM tile row * 8 (scanline)
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr blit_tile
@skip:
    inc rj
    lda rj
    cmp #3
    bne @rloop
    inc ri
    lda ri
    cmp #4                       ; 4 cols wide: covers Mario's 16px + sub-pixel spill into a
    bne @cloop                   ;   4th tile (else a 1-2px ghost survives on byte-aligned frames)
    rts
.endproc

; ---------------------------------------------------------------------------
; draw_column: blit one full 18-row level column to VRAM.
;   in: wcol (world column, 16-bit), dbcol (dest VRAM byte column).
; Rows 0-15 come from the level map (offset +2 rows below the status bar); rows
; 16-17 are solid dirt to fill the SV's 2 extra scanlines below the ground.
; Level tile N<$80 -> bg_chardata[N]; N>=$80 -> chardata[N] (the $8800 region).
.proc draw_column
    lda wcol                     ; map_ptr = level0_map + wcol*16
    sta map_ptr
    lda wcol+1
    sta map_ptr+1
    asl map_ptr
    rol map_ptr+1
    asl map_ptr
    rol map_ptr+1
    asl map_ptr
    rol map_ptr+1
    asl map_ptr
    rol map_ptr+1
    lda map_ptr
    clc
    adc #<level0_map
    sta map_ptr
    lda map_ptr+1
    adc #>level0_map
    sta map_ptr+1
    stz bg_row
@row:
    lda bg_row
    cmp #16
    bcs @dirt                    ; rows 16,17 -> solid dirt (extend ground onto SV's 2 extra rows)
    ldy bg_row
    lda (map_ptr),y              ; tile number
    bra @havetile
@dirt:
    lda #$61                     ; solid dirt fill tile
@havetile:
    jsr get_tile_src             ; -> src_ptr
    lda dbcol
    sta dcol
    lda bg_row                   ; dy = (bg_row+2)*8 : playfield sits below the 2-row status bar
    clc
    adc #2
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr blit_tile                ; opaque
    inc bg_row
    lda bg_row
    cmp #18
    bne @row
    rts
.endproc

; ---------------------------------------------------------------------------
; render_background: draw the 24 columns resident in the framebuffer (20 visible +
; 4 in the 8-byte off-screen margin), starting at world column fb_col0.
.proc render_background
    ldx #0                       ; x = framebuffer column index 0..23
@col:
    txa                          ; wcol = fb_col0 + x
    clc
    adc fb_col0
    sta wcol
    lda fb_col0+1
    adc #0
    sta wcol+1
    txa                          ; dbcol = x*2 (a tile is 2 bytes wide)
    asl
    sta dbcol
    phx
    jsr draw_column
    plx
    inx
    cpx #24
    bne @col
    rts
.endproc

; ---------------------------------------------------------------------------
; render_status_bar: blit the 2x20 status-bar tiles into VRAM rows 0-1. The global
; XSCROLL shifts the whole frame, so to keep the bar visually fixed we draw it at VRAM
; pixel X = scroll_s (byte part scroll_s>>2, sub-pixel scroll_s&3) which exactly cancels
; XSCROLL -> the bar lands pinned at screen X 0. Opaque sub-pixel blit (band + text).
; The DMA shift only touches lines 16..159, so these HUD rows are never disturbed.
.proc render_status_bar
    lda #1
    sta blit_opaque
    stz do_flip
    lda scroll_s                 ; sub-pixel X = scroll_s & 3
    and #3
    sta spr_subx
    stz bg_row
@rowloop:
    stz bg_col
@colloop:
    ldx bg_col                   ; data index = bg_row*20 + bg_col
    lda bg_row
    beq @r0
    txa
    clc
    adc #20
    tax
@r0:
    lda statusbar_tiles,x
    jsr get_tile_src
    lda scroll_s                 ; dcol = (scroll_s>>2) + bg_col*2  (byte part of the scroll)
    lsr
    lsr
    sta dcol
    lda bg_col
    asl
    clc
    adc dcol
    sta dcol
    lda bg_row                   ; dy = bg_row*8
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr sprite_blit_subpx
    inc bg_col
    lda bg_col
    cmp #20
    bne @colloop
    inc bg_row
    lda bg_row
    cmp #2
    bne @rowloop
    stz blit_opaque
    rts
.endproc

; get_tile_src: A = level tile number -> src_ptr = tile graphics.
.proc get_tile_src
    tax                          ; save tile
    stz src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1                ; A:src_ptr+1 = tile*16
    sta src_ptr
    txa
    bmi @obj                     ; tile >= $80 -> $8800 region (OBJ block)
    lda src_ptr                  ; BG set
    clc
    adc #<bg_chardata
    sta src_ptr
    lda src_ptr+1
    adc #>bg_chardata
    sta src_ptr+1
    rts
@obj:
    lda src_ptr
    clc
    adc #<chardata
    sta src_ptr
    lda src_ptr+1
    adc #>chardata
    sta src_ptr+1
    rts
.endproc

; ---------------------------------------------------------------------------
; erase_player: clear the 16x16 region at (prev_col, prev_y) to background ($00).
.proc erase_player
    lda prev_col
    sta dcol
    lda prev_y
    sta dy
    jsr set_dst                  ; dst_ptr = top-left of the old sprite
    ldx #16                      ; 16 rows
@row:
    lda #0
    ldy #0
    sta (dst_ptr),y              ; 16 px wide = 4 bytes
    iny
    sta (dst_ptr),y
    iny
    sta (dst_ptr),y
    iny
    sta (dst_ptr),y
    lda dst_ptr                  ; dst += stride
    clc
    adc #VRAM_STRIDE
    sta dst_ptr
    bcc :+
    inc dst_ptr+1
:   dex
    bne @row
    rts
.endproc

; Camera constants. PIN_X = Mario's screen X (left edge) at which the camera starts
; following him; CAM_MAX = max scroll = (level_cols 420 - 20 visible) * 8 px.
PIN_X   = 64
CAM_MAX = (420 - 20) * 8         ; = 3200 ($0C80)

; ---------------------------------------------------------------------------
; move_player: walk via the real speed table. Up to PIN_X Mario moves on screen;
; past it his rightward motion scrolls the camera (cam_x) instead, until the level
; end (CAM_MAX) where he walks to the right screen edge. The level never scrolls back.
.proc move_player                ; accelerating walk via the real speed table (px-precise)
    lda pad_held
    and #GB_RIGHT
    bne @right
    lda pad_held
    and #GB_LEFT
    bne @left
    stz h_hold                   ; not moving: reset accel
    stz h_idx
    rts
@right:
    stz mario_facing
    jsr calc_step                ; h_step = px this frame
    lda spr_x
    clc
    adc h_step
    sta tmpL                     ; tentative new screen X
    cmp #PIN_X+1
    bcc @setx                    ; new <= PIN_X: just move on screen
    ; new > PIN_X: scroll instead, unless the camera is already at the level end
    lda cam_x+1
    cmp #>CAM_MAX
    bcc @scroll
    bne @atmax
    lda cam_x
    cmp #<CAM_MAX
    bcc @scroll
@atmax:                          ; camera maxed -> let Mario reach the right edge
    lda tmpL
    cmp #145                     ; clamp to screen (160 - 16)
    bcc :+
    lda #144
:   sta spr_x
    rts
@scroll:
    lda tmpL                     ; excess = new - PIN_X  -> add to camera
    sec
    sbc #PIN_X
    sta tmpH
    lda #PIN_X
    sta spr_x
    lda cam_x
    clc
    adc tmpH
    sta cam_x
    bcc @clamp
    inc cam_x+1
@clamp:                          ; clamp cam_x to CAM_MAX
    lda cam_x+1
    cmp #>CAM_MAX
    bcc @rdone
    bne @doclamp
    lda cam_x
    cmp #<CAM_MAX
    bcc @rdone
@doclamp:
    lda #<CAM_MAX
    sta cam_x
    lda #>CAM_MAX
    sta cam_x+1
@rdone:
    rts
@setx:
    lda tmpL
    sta spr_x
    rts
@left:
    jsr calc_step
    lda spr_x
    sec
    sbc h_step
    bcs :+                       ; underflow -> clamp 0
    lda #0
:   sta spr_x
    lda #1
    sta mario_facing
    rts
.endproc

; calc_step: ramp the accel, read speedtab[idx+toggle] -> h_step, flip the toggle.
.proc calc_step
    lda h_hold                   ; ramp hold counter (cap 12)
    cmp #12
    bcs @capped
    inc h_hold
@capped:
    ldx #0                       ; idx 0 (slow start, <6 held), then 2 (~1 px/frame walk)
    lda h_hold
    cmp #6
    bcc @gi
    ldx #2
@gi:
    stx h_idx
    txa                          ; speedtab[idx + toggle]
    clc
    adc h_toggle
    tax
    lda speedtab,x
    sta h_step
    lda h_toggle                 ; flip sub-pixel toggle
    eor #$01
    sta h_toggle
    rts
.endproc

; ---------------------------------------------------------------------------
; scroll_update: reconcile the hardware scroll with cam_x. The framebuffer holds
; 24 columns (world cols fb_col0..fb_col0+23). We hardware-scroll across the 8-byte
; (32px) off-screen margin via XSCROLL; when the camera moves a full margin past
; fb_col0 we DMA-shift the framebuffer left 8 bytes (4 cols) and stream 4 fresh
; columns into the right margin. Scroll is byte-aligned (4px steps) so the status
; bar and Mario stay pixel-exact while reusing the byte-aligned blits.
FB_MAX_COL = 420 - 24            ; last fb_col0 that keeps cols fb_col0..+23 in the level
.proc scroll_update
    stz shift_px                 ; track how far the framebuffer shifts this frame
@loop:
    lda fb_col0                  ; tmpH:tmpL = fb_col0 * 8
    sta tmpL
    lda fb_col0+1
    sta tmpH
    asl tmpL
    rol tmpH
    asl tmpL
    rol tmpH
    asl tmpL
    rol tmpH
    lda cam_x                    ; tmpH:tmpL = cam_x - fb_col0*8  (offset within framebuffer)
    sec
    sbc tmpL
    sta tmpL
    lda cam_x+1
    sbc tmpH
    sta tmpH
    lda tmpH                     ; offset >= 256 -> definitely need a shift
    bne @needshift
    lda tmpL
    cmp #32                      ; offset < 32 -> within margin, no shift
    bcc @setscroll
@needshift:
    lda fb_col0+1                ; only shift while the level still has columns to the right
    cmp #>FB_MAX_COL
    bcc @doshift
    bne @clampend
    lda fb_col0
    cmp #<FB_MAX_COL
    bcc @doshift
@clampend:                       ; at the level end: pin scroll to the last margin (<=32)
    lda tmpL
    cmp #33
    bcc @apply
    lda #32
    bra @apply
@doshift:
    jsr fb_shift8                ; shift framebuffer left 8 bytes (4 cols)
    lda fb_col0                  ; fb_col0 += 4
    clc
    adc #4
    sta fb_col0
    bcc :+
    inc fb_col0+1
:   lda shift_px                 ; record the 32px (8-byte) shift: the main loop adjusts
    clc                          ;   prev_vx to match and streams the new columns AFTER
    adc #32                      ;   drawing Mario (see main_loop ordering note)
    sta shift_px
    bra @loop                    ; recompute offset (now reduced by 32)
@setscroll:
    lda tmpL
@apply:
    sta scroll_s                 ; smooth 1px scroll; XSCROLL is applied by the NMI/IRQ raster
@done:                           ;   split (0 for HUD rows, scroll_s for the playfield rows)
    rts
.endproc

; stream_cols: draw the 4 new right-margin columns (fb_col0+20..+23) into the
; off-screen VRAM byte columns 40,42,44,46 after a shift.
.proc stream_cols
    ldx #0
@l:
    txa                          ; wcol = fb_col0 + 20 + x
    clc
    adc #20
    clc
    adc fb_col0
    sta wcol
    lda fb_col0+1
    adc #0
    sta wcol+1
    txa                          ; dbcol = 40 + x*2
    asl
    clc
    adc #40
    sta dbcol
    phx
    jsr draw_column
    plx
    inx
    cpx #4
    bne @l
    rts
.endproc

; fb_shift8: shift the PLAYFIELD (scanlines 16..159) left 8 bytes via the VRAM DMA.
; The DMA does a clean linear copy (upperRam[i]=upperRam[i+8]); restricting it to the
; playfield avoids the only problem: a whole-framebuffer linear shift bleeds each line's
; right edge from the line below, and the blank rows 0..15 (never refilled) accumulate
; that bleed upward. Lines 16..159 ARE refilled every shift by stream_cols, so no creep.
; Two line-aligned chunks (DMA_LEN is x16-bytes, max 255 units): 80 lines + 64 lines.
; The DMA copy is ~free in emulated cycles -> no hitch. Cpu2vram=1 (dst hi bit6 set).
.proc fb_shift8
    lda #$08                     ; chunk 1: $4308 -> $4300 (lines 16..95, 3840 bytes)
    sta DMA_SRC_LO
    lda #$43
    sta DMA_SRC_HI
    stz DMA_DST_LO
    lda #$43
    sta DMA_DST_HI
    lda #240                     ; 240 x 16 = 3840 bytes = 80 lines
    sta DMA_LEN
    lda #$80
    sta DMA_CTRL
    lda #$08                     ; chunk 2: $5208 -> $5200 (lines 96..159, 3072 bytes)
    sta DMA_SRC_LO
    lda #$52
    sta DMA_SRC_HI
    stz DMA_DST_LO
    lda #$52
    sta DMA_DST_HI
    lda #192                     ; 192 x 16 = 3072 bytes = 64 lines
    sta DMA_LEN
    lda #$80
    sta DMA_CTRL
    rts
.endproc

; ---------------------------------------------------------------------------
; draw_player: blit Mario's 16x16 standing metasprite (tiles $20,$21,$30,$31 -
; captured from the GB shadow OAM $C00C) at (spr_col, spr_y), transparent.
.proc draw_player
    lda mario_vx                 ; sub-pixel offset within the byte (VRAM pixel X = spr_x + scroll_s)
    and #3
    sta spr_subx
    lda mario_vx
    lsr
    lsr
    sta spr_col                  ; VRAM byte column
    lda mario_frame              ; load the 4 tiles for the current pose
    asl
    asl                          ; *4
    tax
    lda mario_poses,x
    sta pose_tl
    lda mario_poses+1,x
    sta pose_tr
    lda mario_poses+2,x
    sta pose_bl
    lda mario_poses+3,x
    sta pose_br
    lda mario_facing             ; facing -> do_flip; mirror the metasprite if left
    sta do_flip
    beq @draw
    lda pose_tl                  ; swap TL<->TR, BL<->BR (each tile also flips in draw_quad)
    ldx pose_tr
    sta pose_tr
    stx pose_tl
    lda pose_bl
    ldx pose_br
    sta pose_br
    stx pose_bl
@draw:
    lda spr_col                  ; TL
    sta dcol
    lda spr_y
    sta dy
    ldx pose_tl
    jsr draw_quad
    lda spr_col                  ; TR (col+2: a tile is 8px = 2 bytes)
    ina
    ina
    sta dcol
    lda spr_y
    sta dy
    ldx pose_tr
    jsr draw_quad
    lda spr_col                  ; BL (y+8)
    sta dcol
    lda spr_y
    clc
    adc #8
    sta dy
    ldx pose_bl
    jsr draw_quad
    lda spr_col                  ; BR (col+2, y+8)
    ina
    ina
    sta dcol
    lda spr_y
    clc
    adc #8
    sta dy
    ldx pose_br
    jsr draw_quad
    rts
.endproc

; ---------------------------------------------------------------------------
; animate_player: pick the pose index — jump in the air, 2-frame walk while moving,
; else standing. (Pose tiles come from mario_poses, captured from the real game.)
.proc animate_player
    lda jump_state
    beq @ground
    lda #3                       ; jump
    sta mario_frame
    rts
@ground:
    lda pad_held
    and #(GB_LEFT | GB_RIGHT)
    beq @idle
    lda frame_count              ; walk cycle: alternate ~every 8 frames
    and #$08
    beq @w1
    lda #2                       ; walk B
    sta mario_frame
    rts
@w1:
    lda #1                       ; walk A
    sta mario_frame
    rts
@idle:
    lda #0                       ; stand
    sta mario_frame
    rts
.endproc

; mario_poses (4 poses x 4 tiles) and statusbar_tiles (2x20 template) are now
; ROM-derived BUILD ARTIFACTS extracted by tools/extract_tables.py (rule 5) and
; .incbin'd from src/datatables.s — see there.

; ---------------------------------------------------------------------------
; draw_quad: X = tile index; dcol/dy set. src_ptr = chardata + X*16; blit transparent.
.proc draw_quad
    txa                          ; src_ptr = chardata + X*16
    stz src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    clc
    adc #<chardata
    sta src_ptr
    lda src_ptr+1
    adc #>chardata
    sta src_ptr+1
    jsr set_dst
    stz blit_opaque              ; Mario is transparent (GB colour 0 = see-through)
    jsr sprite_blit_subpx
    rts
.endproc

; set_dst: dst_ptr = $4000 + dy*48 + dcol.
.proc set_dst
    lda dy
    sta dst_ptr
    stz dst_ptr+1
    ldx #4                       ; dst_ptr = dy*16
:   asl dst_ptr
    rol dst_ptr+1
    dex
    bne :-
    lda dst_ptr                  ; save dy*16
    sta tmpL
    lda dst_ptr+1
    sta tmpH
    asl dst_ptr                  ; dy*32
    rol dst_ptr+1
    lda dst_ptr                  ; dy*48 = dy*32 + dy*16
    clc
    adc tmpL
    sta dst_ptr
    lda dst_ptr+1
    adc tmpH
    sta dst_ptr+1
    lda dst_ptr                  ; + dcol
    clc
    adc dcol
    sta dst_ptr
    lda dst_ptr+1
    adc #0
    sta dst_ptr+1
    lda dst_ptr+1                ; + $4000 base
    clc
    adc #$40
    sta dst_ptr+1
    rts
.endproc

; ---------------------------------------------------------------------------
; sprite_blit_tile: like blit_tile but TRANSPARENT (GB colour 0 = see-through).
; Per byte: mask = pixels-that-are-nonzero; dst = (dst & ~mask) | src.
.proc sprite_blit_tile
    lda src_ptr
    sta cur_src
    lda src_ptr+1
    sta cur_src+1
    lda dst_ptr
    sta cur_dst
    lda dst_ptr+1
    sta cur_dst+1
    ldx #8
@row:
    ldy #0
    jsr @merge
    iny
    jsr @merge
    lda cur_src                  ; src += 2
    clc
    adc #2
    sta cur_src
    bcc :+
    inc cur_src+1
:   lda cur_dst                  ; dst += stride
    clc
    adc #VRAM_STRIDE
    sta cur_dst
    bcc :+
    inc cur_dst+1
:   dex
    bne @row
    rts
@merge:
    lda (cur_src),y
    sta tmp_src
    lsr                          ; src >> 1
    ora tmp_src                  ; src | src>>1
    and #$55                     ; f (per-pixel nonzero flag at low bit)
    sta tmp_mask
    asl                          ; f << 1
    ora tmp_mask                 ; mask = f | f<<1
    eor #$FF                     ; ~mask
    and (cur_dst),y              ; dst & ~mask
    ora tmp_src                  ; | src  (transparent px contribute 0)
    sta (cur_dst),y
    rts
.endproc

; ---------------------------------------------------------------------------
; build_revpix: revpix[b] = b with its four 2bpp pixels reversed (px0<->px3, px1<->px2).
.proc build_revpix
    ldx #0
@l:
    txa
    lsr                          ; px3 (bits7:6) -> bits1:0
    lsr
    lsr
    lsr
    lsr
    lsr
    sta tmpL
    txa
    lsr                          ; px2 (5:4) -> 3:2
    lsr
    and #$0C
    ora tmpL
    sta tmpL
    txa
    asl                          ; px1 (3:2) -> 5:4
    asl
    and #$30
    ora tmpL
    sta tmpL
    txa
    asl                          ; px0 (1:0) -> 7:6
    asl
    asl
    asl
    asl
    asl
    and #$C0
    ora tmpL
    sta revpix,x
    inx
    bne @l
    rts
.endproc

; ---------------------------------------------------------------------------
; merge_byte_A: transparent merge of source byte A into (cur_dst),y.
.proc merge_byte_A
    sta tmp_src
    lsr
    ora tmp_src
    and #$55
    sta tmp_mask
    asl
    ora tmp_mask
    eor #$FF
    and (cur_dst),y
    ora tmp_src
    sta (cur_dst),y
    rts
.endproc

; ---------------------------------------------------------------------------
; sprite_blit_tile_flip: transparent blit, HORIZONTALLY FLIPPED. Per row, the two
; bytes swap and each is pixel-reversed: dst[0]=revpix[src[1]], dst[1]=revpix[src[0]].
.proc sprite_blit_tile_flip
    lda src_ptr
    sta cur_src
    lda src_ptr+1
    sta cur_src+1
    lda dst_ptr
    sta cur_dst
    lda dst_ptr+1
    sta cur_dst+1
    lda #8
    sta blit_row
@row:
    ldy #1                       ; src right byte -> flipped -> dst left
    lda (cur_src),y
    tax
    lda revpix,x
    ldy #0
    jsr merge_byte_A
    ldy #0                       ; src left byte -> flipped -> dst right
    lda (cur_src),y
    tax
    lda revpix,x
    ldy #1
    jsr merge_byte_A
    lda cur_src                  ; src += 2
    clc
    adc #2
    sta cur_src
    bcc :+
    inc cur_src+1
:   lda cur_dst                  ; dst += stride
    clc
    adc #VRAM_STRIDE
    sta cur_dst
    bcc :+
    inc cur_dst+1
:   dec blit_row
    beq @out
    jmp @row
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; calc_mask_A: A = byte -> A = transparency mask (the 2bpp pixels that are nonzero).
.proc calc_mask_A
    sta tmp_src
    lsr
    ora tmp_src
    and #$55
    sta tmp_mask
    asl
    ora tmp_mask
    rts
.endproc

; ---------------------------------------------------------------------------
; sprite_blit_subpx: transparent sprite blit at a SUB-PIXEL X (spr_subx = 0..3),
; with optional horizontal flip (do_flip). Each row's 2 source bytes are shifted
; left by spr_subx*2 bits into 3 dst bytes (the sprite can spill into a 3rd byte),
; merged with transparency. Unifies the byte-aligned + flipped paths.
.proc sprite_blit_subpx
    lda src_ptr
    sta cur_src
    lda src_ptr+1
    sta cur_src+1
    lda dst_ptr
    sta cur_dst
    lda dst_ptr+1
    sta cur_dst+1
    lda #8
    sta blit_row
@row:
    lda do_flip
    beq @noflip
    ldy #1                       ; flipped: new-left = revpix[src right]
    lda (cur_src),y
    tax
    lda revpix,x
    sta s0
    ldy #0                       ; new-right = revpix[src left]
    lda (cur_src),y
    tax
    lda revpix,x
    sta s1
    bra @lr
@noflip:
    ldy #0
    lda (cur_src),y
    sta s0
    ldy #1
    lda (cur_src),y
    sta s1
@lr:
    stz s2
    lda blit_opaque
    bne @opaquemask
    lda s0                       ; transparency masks (only nonzero pixels are written)
    jsr calc_mask_A
    sta m0
    lda s1
    jsr calc_mask_A
    sta m1
    bra @m2
@opaquemask:
    lda #$FF                     ; opaque: cover all 8 px (replace, masking preserves neighbours)
    sta m0
    sta m1
@m2:
    stz m2
    lda spr_subx                 ; shift count = subx*2
    asl
    tax
    beq @merge
@sh:
    asl s0
    rol s1
    rol s2
    asl m0
    rol m1
    rol m2
    dex
    bne @sh
@merge:
    ldy #0                       ; dst = (dst & ~mask) | shifted
    lda m0
    eor #$FF
    and (cur_dst),y
    ora s0
    sta (cur_dst),y
    iny
    lda m1
    eor #$FF
    and (cur_dst),y
    ora s1
    sta (cur_dst),y
    iny
    lda m2
    eor #$FF
    and (cur_dst),y
    ora s2
    sta (cur_dst),y
    lda cur_src                  ; src += 2
    clc
    adc #2
    sta cur_src
    bcc :+
    inc cur_src+1
:   lda cur_dst                  ; dst += stride
    clc
    adc #VRAM_STRIDE
    sta cur_dst
    bcc :+
    inc cur_dst+1
:   dec blit_row
    beq @out
    jmp @row
@out:
    rts
.endproc

; ---------------------------------------------------------------------------
; NMI: per-frame tick (~61 Hz). Mirrors the GB VBlank ISR role. Also begins the
; raster split for a fixed HUD: XSCROLL = 0 for the top rows (status bar), and arm
; the timer to fire at scanline 16 where the IRQ switches to the playfield scroll.
HUD_SPLIT_LINE = 16              ; timer reload = split scanline (IPeriod=256 cyc/scanline)
.proc nmi
    pha
    inc frame_count
    lda #1
    sta frame_flag
    stz XSCROLL                  ; status-bar rows (0..15) render unscrolled
    lda #HUD_SPLIT_LINE           ; arm timer -> IRQ at scanline 16 (period = data * $100)
    sta IRQ_TIMER
    pla
    rti
.endproc

; IRQ (timer @ scanline 16): switch to the playfield scroll for the rest of the frame.
.proc irq
    pha
    lda scroll_s
    sta XSCROLL                  ; playfield rows (16..159) scroll smoothly
    lda IRQ_TIMER_RST            ; read clears the timer IRQ
    pla
    rti
.endproc

; ---------------------------------------------------------------------------
; read_input: read $2020 (active-low) and produce GB-layout held + pressed,
; matching the semantics of the GB $FF80/$FF81 the game logic expects.
.proc read_input
    lda CONTROLLER
    eor #$FF                 ; active-high, SV layout: 7St 6Sel 5A 4B 3Up 2Dn 1L 0R
    sta sv_tmp
    stz gb_tmp
    ldx #0
@loop:
    lda sv_tmp
    and sv_masks,x           ; SV mask for GB bit X
    beq @skip
    lda gb_tmp
    ora bit_masks,x          ; set GB bit X
    sta gb_tmp
@skip:
    inx
    cpx #8
    bne @loop

    lda pad_held
    sta pad_prev
    lda gb_tmp
    sta pad_held
    eor pad_prev             ; held ^ prev
    and pad_held             ; & held  -> newly pressed
    sta pad_pressed
    rts
.endproc

; ---------------------------------------------------------------------------
; clear_vram: zero the 6400-byte framebuffer ($4000..$58FF).
.proc clear_vram
    lda #<VRAM
    sta ptr
    lda #>VRAM
    sta ptr+1
    ldx #30                  ; 30 pages = 7680 bytes = full 160-line framebuffer (stride $30)
    lda #0
@page:
    ldy #0
:   sta (ptr),y
    iny
    bne :-
    inc ptr+1
    dex
    bne @page
    rts
.endproc

; ---------------------------------------------------------------------------
; blit_tile: draw one 8x8 SV tile (16 bytes at src_ptr) to VRAM at dst_ptr.
; Byte-aligned (tile x must be a multiple of 4 px). 2 bytes/row, advancing the
; VRAM dest by the line stride ($30). src_ptr/dst_ptr are preserved (uses copies).
.proc blit_tile
    lda src_ptr
    sta cur_src
    lda src_ptr+1
    sta cur_src+1
    lda dst_ptr
    sta cur_dst
    lda dst_ptr+1
    sta cur_dst+1
    ldx #8                       ; 8 rows
@row:
    ldy #0
    lda (cur_src),y              ; left 4 px
    sta (cur_dst),y
    iny
    lda (cur_src),y              ; right 4 px
    sta (cur_dst),y
    lda cur_src                  ; src += 2
    clc
    adc #2
    sta cur_src
    bcc :+
    inc cur_src+1
:   lda cur_dst                  ; dst += stride ($30)
    clc
    adc #VRAM_STRIDE
    sta cur_dst
    bcc :+
    inc cur_dst+1
:   dex
    bne @row
    rts
.endproc

; ---------------------------------------------------------------------------
; draw_tilesheet: blit the first 16x16 = 256 tiles as a grid in the top-left
; (128x128 px). Proves tile data + SV packing + the blit path with real graphics.
.proc draw_tilesheet
    lda #<chardata               ; src = tile 0
    sta src_ptr
    lda #>chardata
    sta src_ptr+1
    lda #<VRAM                   ; row_base = top-left of VRAM
    sta row_base
    lda #>VRAM
    sta row_base+1
    lda #16
    sta trow_cnt
@rowloop:
    lda row_base                 ; dst_ptr = row_base
    sta dst_ptr
    lda row_base+1
    sta dst_ptr+1
    lda #16
    sta tcol_cnt
@colloop:
    jsr blit_tile
    lda src_ptr                  ; src_ptr += 16 (next tile)
    clc
    adc #16
    sta src_ptr
    bcc :+
    inc src_ptr+1
:   lda dst_ptr                  ; dst_ptr += 2 (next column = 8 px)
    clc
    adc #2
    sta dst_ptr
    bcc :+
    inc dst_ptr+1
:   dec tcol_cnt
    bne @colloop
    lda row_base                 ; row_base += 8*stride ($180) -> next tile-row
    clc
    adc #<(8 * VRAM_STRIDE)
    sta row_base
    lda row_base+1
    adc #>(8 * VRAM_STRIDE)
    sta row_base+1
    dec trow_cnt
    bne @rowloop
    rts
.endproc

; ---------------------------------------------------------------------------
.segment "RODATA"
; GB-bit X is set from this SV-input mask:
sv_masks:  .byte PAD_A, PAD_B, PAD_SELECT, PAD_START, PAD_RIGHT, PAD_LEFT, PAD_UP, PAD_DOWN
bit_masks: .byte $01,$02,$04,$08,$10,$20,$40,$80

; ---------------------------------------------------------------------------
.segment "VECTORS"
    .addr nmi                ; $FFFA
    .addr reset              ; $FFFC
    .addr irq                ; $FFFE
