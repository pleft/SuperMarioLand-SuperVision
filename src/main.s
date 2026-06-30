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
.import mario_big_poses      ; 5 big-Mario poses x 4 tiles (stand,walkA,walkB,jump,duck)
.import statusbar_tiles      ; 2x20 status-bar template (ROM $3F9C)
.import level0_cols          ; World 1-1 width in columns (from the level binary size)
.import room_ptrs            ; table of underground room map pointers
.import pipe_table, pipe_count ; pipe entries: entry_col(16), room, resume_col(16)
.import block_table, block_count ; ?-block contents: col(16), row, value ($28=mushroom)

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
ground_y:    .res 1          ; (legacy fixed-ground scanline; superseded by tile collision)
feet_col:    .res 2          ; world tile column under Mario's centre (for collision)
mrow:        .res 1          ; level row being collision-tested
fall_v:      .res 1          ; fall mode: 0 = jump-arc descent, nonzero = free-fall (+3)
respawn_req: .res 1          ; set when Mario falls into a pit -> restart the level
map_base:    .res 2          ; current tilemap base (surface level0_map, or a pipe room)
room_mode:   .res 1          ; 0 = surface (scrolls), 1 = inside a single-screen pipe room
save_cam_x:  .res 2          ; surface camera saved on pipe entry (restored on exit)
save_spr_x:  .res 1
save_spr_y:  .res 1          ; Mario's height on the pipe (restored on exit)
pipe_phase:  .res 1          ; 0 = none, 1 = sinking into pipe (then enter), 2 = rising out
pipe_anim:   .res 1          ; animation frame counter
pipe_room:   .res 1          ; room to enter after the sink finishes
coins:       .res 1          ; coin count, BCD (00..99); 100 coins -> 1-up ($fffa in SML)
lives:       .res 1          ; spare lives, BCD ($da15 in SML; starts at 2)
score:       .res 3          ; score, BCD, 6 digits (little-endian: score+0 = ones/tens)
timer:       .res 2          ; level timer, BCD, 3 digits (countdown), timer+1 = hundreds
timer_sub:   .res 1          ; sub-second counter for the timer (decrements ~every 24 frames)
hud_dirty:   .res 1          ; nonzero -> HUD values changed, redraw them
mario_big:   .res 1          ; 0 = small Mario, 1 = big ("Super") Mario
mario_duck:  .res 1          ; 1 = big Mario ducking (Down held, grounded)
hud_row:     .res 1          ; put_hud target row (0 or 1)
htmp:        .res 1          ; put_hud scratch (digit being blitted)
rb_vx:       .res 1          ; restore_bg: VRAM pixel X of the region to repaint
rb_y:        .res 1          ; restore_bg: VRAM pixel Y
rb_cols:     .res 1          ; restore_bg: width in tiles
rb_rows:     .res 1          ; restore_bg: height in tiles
oi:          .res 1          ; object loop index
ovx:         .res 1          ; object draw scratch: VRAM pixel X
blk_lim:     .res 1          ; find_block loop limit = block_count*4 (set at boot)
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
tile_mod:    .res 640        ; "modified" bitmap, 1 bit per surface (col,row): used ?-block / broken brick
; --- object slots (mushroom / coin-pop entities). SoA, OBJ_MAX entries. ---
o_type:      .res 4          ; 0 free, 1 mushroom, 2 coin-pop
o_xl:        .res 4          ; world pixel X (16-bit)
o_xh:        .res 4
o_y:         .res 4          ; world pixel Y (same space as spr_y: feet line)
o_vx:        .res 4          ; signed velocity X
o_vy:        .res 4          ; signed velocity Y (gravity)
o_tmr:       .res 4          ; state timer / lifetime
o_pvx:       .res 4          ; last drawn VRAM pixel X (for erase)
o_pvy:       .res 4          ; last drawn VRAM pixel Y
o_pdr:       .res 4          ; was drawn last frame?

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
    lda #<level0_map             ; start on the surface map
    sta map_base
    lda #>level0_map
    sta map_base+1
    jsr render_background        ; draw the World 1-1 scene
    jsr render_status_bar        ; status bar (drawn once; pinned by the NMI/IRQ raster split)
    lda #$02                     ; SML starts with 2 spare lives ($da15 init)
    sta lives
    lda #<block_count            ; find_block limit = block_count*4 (low byte is enough: < 64)
    asl
    asl
    sta blk_lim
    jsr hud_init                 ; clock = 400, zero score/coins
    jsr draw_hud                 ; stamp the live values over the template
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
    lda pipe_phase              ; pipe sink/rise animation running? -> just animate
    beq @normal
    jsr pipe_animate
    jmp main_loop
@normal:
    jsr read_input
    jsr move_player              ; walk (updates spr_x) or scroll the camera (cam_x)
    jsr jump_player              ; A = jump (real arc); updates spr_y while airborne
    jsr update_objects           ; mushroom/coin physics + mushroom pickup
    jsr animate_player           ; pick the pose
    jsr tick_timer               ; count down the level clock
    lda respawn_req              ; fell into a pit -> restart the level (skip normal draw)
    beq @chkpipe
    jsr do_respawn
    bra main_loop
@chkpipe:
    jsr pipe_check              ; pipe entry/exit -> may re-render and skip the normal draw
    bcc @play
    jmp main_loop
@play:
    lda hud_dirty                ; refresh score/coins/time tiles if anything changed
    beq :+
    jsr draw_hud
:   ; (The patched core composes the whole frame before rendering, so draw order isn't
    ; timing-critical; stream the incoming columns last as they're off-screen this frame.)
    jsr scroll_update            ; advance camera: framebuffer shift (fast) + scroll_s
    lda prev_vx                  ; if the frame shifted, old Mario moved left with it
    sec
    sbc shift_px
    sta prev_vx
    sta rb_vx                    ; erase old Mario at his (shifted) spot: 4 cols x 3 rows
    lda prev_y
    sta rb_y
    lda #4
    sta rb_cols
    lda #3
    sta rb_rows
    jsr restore_bg
    jsr erase_objects            ; erase the mushroom/coins at their old (shifted) spots
    jsr draw_objects             ; mushroom/coins under Mario
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
; calc_feet_col: feet_col = (cam_x + spr_x + A) >> 3.  A = pixel offset of the collision
; point across Mario's 16px sprite (8 = centre, 1 = left edge, 14 = right edge).
.proc calc_feet_col
    clc
    adc spr_x
    sta tmpL
    lda #0
    adc #0
    sta tmpH
    lda cam_x
    clc
    adc tmpL
    sta tmpL
    lda cam_x+1
    adc tmpH
    sta tmpH
    lsr tmpH
    ror tmpL
    lsr tmpH
    ror tmpL
    lsr tmpH
    ror tmpL
    lda tmpL
    sta feet_col
    lda tmpH
    sta feet_col+1
    rts
.endproc

; read_map_tile: A = map_base[feet_col][mrow] (the raw tile), or $00 if the row is off-map.
.proc read_map_tile
    lda mrow
    cmp #16
    bcs @off
    lda feet_col                 ; map_ptr = map_base + feet_col*16
    sta map_ptr
    lda feet_col+1
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
    adc map_base
    sta map_ptr
    lda map_ptr+1
    adc map_base+1
    sta map_ptr+1
    ldy mrow
    lda (map_ptr),y
    ; --- apply the used-tile transform (surface only): bumped ?-block -> used block,
    ;     broken brick -> blank. Rooms have no such tiles, so skip them. ---
    ldx room_mode
    bne @raw
    pha
    jsr mod_test                 ; A = mod bit for (feet_col, mrow); clobbers map_ptr/tmpL/X
    bne @mod
    pla
@raw:
    rts
@mod:
    pla                          ; recover the raw tile
    cmp #$82
    beq @broke                   ; brick -> blank
    lda #$7F                     ; ?-block ($80/$81) -> used (solid) block
    rts
@broke:
    lda #$2C
    rts
@off:
    lda #0
    rts
.endproc

; mod_ptr: map_ptr = &tile_mod[feet_col*2 + (mrow>>3)] ; tmpL = bit mask (1<<(mrow&7)).
; The "modified" bitmap is 1 bit per surface (col,row): set = used ?-block / broken brick.
.proc mod_ptr
    lda feet_col
    asl
    sta map_ptr
    lda feet_col+1
    rol
    sta map_ptr+1                 ; map_ptr = feet_col * 2
    lda mrow
    cmp #8
    bcc @nolo                     ; mrow >= 8 -> +1 byte (the bitmap packs 16 rows = 2 bytes)
    inc map_ptr
    bne @nolo
    inc map_ptr+1
@nolo:
    lda map_ptr
    clc
    adc #<tile_mod
    sta map_ptr
    lda map_ptr+1
    adc #>tile_mod
    sta map_ptr+1
    lda mrow
    and #7
    tax
    lda bit_masks,x
    sta tmpL
    rts
.endproc

; clear_tile_mod: zero the 640-byte modified-tile bitmap (level restart).
.proc clear_tile_mod
    lda #<tile_mod
    sta map_ptr
    lda #>tile_mod
    sta map_ptr+1
    ldx #3                       ; 3 pages (768 bytes) covers the 640-byte bitmap
    ldy #0
    lda #0
@pg:
    sta (map_ptr),y
    iny
    bne @pg
    inc map_ptr+1
    dex
    bne @pg
    rts
.endproc

.proc mod_set
    jsr mod_ptr
    ldy #0
    lda (map_ptr),y
    ora tmpL
    sta (map_ptr),y
    rts
.endproc

.proc mod_test                   ; A = bit value (0 = unmodified) for (feet_col, mrow)
    jsr mod_ptr
    ldy #0
    lda (map_ptr),y
    and tmpL
    rts
.endproc

; hit_qblock: head-bonk reaction for a ?-block at (feet_col, mrow). Mark it used + redraw as a
; used block, then dispatch by the block-contents table: $28 (Super Mushroom) -> spawn a
; mushroom entity; everything else (and unlisted blocks) -> launch a coin + award it. The
; tile value ($80 vs $81) does NOT decide the contents — the table does (Call_000_2321).
.proc hit_qblock
    jsr mod_set                  ; flag (feet_col,mrow) used so it can't be re-bumped
    lda feet_col                 ; redraw the cell -> read_map_tile now returns $7F (used)
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one
    jsr find_block               ; C=1,A=value if this block is in the contents table
    bcc @coin
    cmp #$28                     ; $28 = Super Mushroom
    beq @mush
    cmp #$c0                     ; $c0 = multi-coin block -> treat as a coin (TODO: 10-coin)
    beq @coin
                                 ; $2a/$2c (star/superball) -> mushroom for now (TODO: real items)
@mush:
    jsr spawn_mushroom
    rts
@coin:
    jsr spawn_coin               ; coin-pop animation
    jsr award_coin               ; +1 coin, +100 score, 1-up at 100
    rts
.endproc

; find_block: search the contents table for (feet_col, mrow). Returns C=1 + A=value if listed,
; else C=0. (Unlisted ?-blocks hold a single coin.)
.proc find_block
    ldx #0
@loop:
    lda block_table,x
    cmp feet_col
    bne @next
    lda block_table+1,x
    cmp feet_col+1
    bne @next
    lda block_table+2,x
    cmp mrow
    bne @next
    lda block_table+3,x
    sec
    rts
@next:
    inx
    inx
    inx
    inx
    cpx blk_lim
    bne @loop
    clc
    rts
.endproc

; award_coin: +1 coin (BCD), +100 score, and a 1-up on the 100th coin.
.proc award_coin
    lda #$00
    ldx #$01                     ; a coin is worth +100 points (SML Call_000_1bff)
    jsr add_score
    sed
    lda coins
    clc
    adc #1
    sta coins
    cld
    bne @done                    ; rolled 99->00 = 100th coin -> 1-up
    jsr add_life
@done:
    lda #1
    sta hud_dirty
    rts
.endproc

; add_life / lose_life: BCD lives counter, clamped to [0,99]. Lives only grow on a 1-up
; (100 coins, or a heart power-up once the object engine lands) — never on a plain ?-block.
.proc add_life
    sed
    lda lives
    cmp #$99
    bcs @done
    clc
    adc #1
    sta lives
@done:
    cld
    lda #1
    sta hud_dirty
    rts
.endproc

.proc lose_life
    sed
    lda lives
    beq @done                    ; already 0 -> game over (TODO)
    sec
    sbc #1
    sta lives
@done:
    cld
    lda #1
    sta hud_dirty
    rts
.endproc

; break_brick: big Mario head-bonks a brick ($82) -> smash it (mod bit makes read_map_tile
; return $2C = blank/passable) and score.
.proc break_brick
    jsr mod_set
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one               ; redraw as blank
    lda #$50                     ; +50 points
    ldx #$00
    jsr add_score
    rts
.endproc

; add_score: add a BCD amount (A = ones/tens byte, X = hundreds/thousands byte) to the
; 3-byte BCD score, with carry into the high byte. Sets hud_dirty.
.proc add_score
    sed
    clc
    adc score
    sta score
    txa
    adc score+1
    sta score+1
    lda score+2
    adc #0
    sta score+2
    cld
    lda #1
    sta hud_dirty
    rts
.endproc

; read_solid: A = 1 if the tile at (feet_col, mrow) is SOLID (tile >= $60, per the game's
; FloorCheck), else 0. (Off-map rows are non-solid.)
.proc read_solid
    jsr read_map_tile
    cmp #$60                     ; tiles >= $60 are solid floor
    bcc @no
    lda #1
    rts
@no:
    lda #0
    rts
.endproc

; wall_ahead: A = edge pixel offset (14 = right edge, 1 = left edge). Returns A != 0 if a
; solid tile blocks Mario's body at that edge (tests both of his body rows). Clobbers
; feet_col / mrow / tmp.
.proc wall_ahead
    jsr calc_feet_col            ; feet_col = column at (cam_x + spr_x + A) >> 3
    lda spr_y
    lsr
    lsr
    lsr
    sec
    sbc #2                       ; body top row = (spr_y >> 3) - 2
    sta mrow
    jsr read_solid
    bne @yes
    inc mrow                     ; body bottom row
    jsr read_solid
    bne @yes
    lda #0
    rts
@yes:
    lda #1
    rts
.endproc

; ---------------------------------------------------------------------------
; jump_player: vertical physics with TILE collision (replaces the fixed ground_y).
; A starts a jump (jump-arc up); at apex, descend the arc; when the feet meet a solid
; tile, snap to its top and land. Grounded but unsupported -> free-fall (+3/frame).
; Mario's feet rest on the tile at level row spr_y/8 (the +16 sprite height and the
; +16-scanline playfield offset cancel out).
.proc jump_player
    lda #8                        ; collision column = under Mario's centre
    jsr calc_feet_col
    lda jump_state
    cmp #1
    beq @ascend
    cmp #2
    bne :+
    jmp @fall
:   ; ---- grounded ----
    lda pad_pressed
    and #GB_A
    bne @startjump
    lda spr_y                     ; still supported? test the tile under the feet
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid
    beq :+                        ; A==0 -> not supported -> fall
    jmp @done                     ; supported -> stay grounded
:   lda #2                        ; walked off a ledge -> free-fall
    sta jump_state
    lda #1
    sta fall_v
    jmp @done
@startjump:
    lda #2                        ; seed the arc index at 2 (matches the game)
    sta arc_idx
    lda #1
    sta jump_state
    stz fall_v
    jmp @done
@ascend:
    ldx arc_idx
    lda jumparc,x
    cmp #$7F                      ; apex marker -> start descending
    beq @apex
    sta tmpL
    lda spr_y
    sec
    sbc tmpL
    cmp #16                       ; clamp to the play-area top (HUD = scanlines 0..15)
    bcs :+
    lda #16
:   sta tmpH                      ; tentative new spr_y -> head-bonk test first
    lsr
    lsr
    lsr
    sec
    sbc #2                        ; head row = (new spr_y >> 3) - 2 (tile at his head)
    sta mrow
    jsr read_map_tile             ; effective tile above his head (centre column)
    cmp #$60
    bcc @noceil                   ; < $60 -> not solid -> keep rising
    cmp #$80                      ; $80/$81 = ?-block (content decided by the block table)
    beq @qblock
    cmp #$81
    beq @qblock
    cmp #$82                      ; $82 = breakable brick
    beq @brick
    bra @bonk
@qblock:
    jsr hit_qblock                ; spawn coin or mushroom per the content table
    bra @bonk
@brick:
    lda mario_big                 ; small Mario can't break bricks -> just bonk
    beq @bonk
    jsr break_brick               ; big Mario smashes it
@bonk:
    lda #2                        ; bonk: stop rising, start falling
    sta jump_state
    lda #1
    sta fall_v
    jmp @done
@noceil:
    lda tmpH                      ; clear -> apply the upward move
    sta spr_y
    inc arc_idx
    jmp @done
@apex:
    lda #2
    sta jump_state
    dec arc_idx
    stz fall_v                    ; jump descent follows the arc
    jmp @done
@fall:
    lda fall_v
    bne @freefall                 ; free-fall: constant +3/frame
    ldx arc_idx                   ; jump descent: step the arc, then ramp to +4
    lda jumparc,x
    sta tmpL
    lda arc_idx
    beq @applyfall
    dec arc_idx
    bra @applyfall
@freefall:
    lda #3
    sta tmpL
@applyfall:
    lda spr_y
    clc
    adc tmpL
    sta spr_y
    cmp #160                      ; fell off the bottom (into a pit) -> request a respawn
    bcc @checkland                ;   (before spr_y wraps past 255 and reappears at the top)
    lda #1
    sta respawn_req
    rts
@checkland:
    lda spr_y                     ; landed? test the tile the feet are entering
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid
    beq @done                     ; no ground -> keep falling
    lda mrow                      ; land: snap feet to the tile top (spr_y = mrow*8)
    asl
    asl
    asl
    sta spr_y
    stz jump_state
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; do_respawn: Mario fell into a pit -> restart the level from the beginning (no lives
; yet; TODO: death animation + life count). Reset camera/state and redraw the scene.
.proc do_respawn
    stz respawn_req
    jsr lose_life                ; dying costs a spare life (game-over at 0 = TODO)
    stz room_mode                ; always restart on the surface
    lda #<level0_map
    sta map_base
    lda #>level0_map
    sta map_base+1
    stz cam_x
    stz cam_x+1
    stz fb_col0
    stz fb_col0+1
    stz scroll_s
    stz prev_scroll_s
    stz XSCROLL
    stz jump_state
    stz fall_v
    stz arc_idx
    stz h_hold
    stz h_idx
    stz h_toggle
    stz mario_facing
    stz mario_frame
    stz prev_frame
    stz mario_big                 ; death -> back to small Mario
    stz mario_duck
    jsr clear_objects             ; drop any live mushroom/coins
    jsr clear_tile_mod            ; reset bumped/broken blocks for the fresh attempt
    stz shift_px
    lda #40
    sta spr_x
    sta mario_vx
    sta prev_vx
    lda #112
    sta spr_y
    sta prev_y
    jsr render_background         ; redraw the level from column 0
    jsr render_status_bar         ; redraw the HUD
    jsr hud_init                  ; level restart: reset the clock to 400
    jsr draw_hud                  ; restamp score/coins/time over the fresh template
    jsr draw_player              ; place Mario at the start
    rts
.endproc

; ---------------------------------------------------------------------------
; pipe_check: handle pipe transitions. On the surface: Down while grounded over a pipe
; column drops Mario into that underground room. In a room: Up while grounded returns him
; to the surface. Returns carry SET if a transition happened (re-rendered; skip the normal
; per-frame draw this frame).
.proc pipe_check
    lda room_mode
    bne @inroom
    ; --- surface: Down while grounded over a pipe -> enter ---
    lda jump_state
    bne @none
    lda pad_held
    and #GB_DOWN
    beq @none
    jsr find_pipe                ; A = room index, or $FF
    cmp #$FF
    beq @none
    sta pipe_room                ; remember the room, save the surface state for the resume
    lda cam_x
    sta save_cam_x
    lda cam_x+1
    sta save_cam_x+1
    lda spr_x
    sta save_spr_x
    lda spr_y
    sta save_spr_y
    lda #1                       ; begin sinking into the pipe (pipe_animate finishes it)
    sta pipe_phase
    lda #16
    sta pipe_anim
    sec
    rts
@inroom:
    ; --- room: walk Right into the exit pipe ($74 mouth) -> back to the surface ---
    lda jump_state               ; grounded, walking into the pipe
    bne @none
    lda pad_held
    and #GB_RIGHT
    beq @none
    lda #14                      ; tile just ahead of Mario's right edge...
    jsr calc_feet_col
    lda spr_y                    ; ...at his upper body row
    lsr
    lsr
    lsr
    sec
    sbc #2
    sta mrow
    jsr read_map_tile
    cmp #$74                     ; horizontal pipe mouth?
    bne @none
    jsr exit_room
    sec
    rts
@none:
    clc
    rts
.endproc

; find_pipe: A = room index if Mario's centre column is a pipe entry (within the 2-wide
; pipe), else $FF.
.proc find_pipe
    lda #8
    jsr calc_feet_col            ; feet_col = centre column
    ldx #0                       ; byte index into pipe_table (5 bytes/pipe)
    ldy #0
@loop:
    lda pipe_table+1,x           ; entry_col high == feet_col high?
    cmp feet_col+1
    bne @next
    lda feet_col                 ; feet_col - entry_col in {0,1} ?
    sec
    sbc pipe_table,x
    cmp #2
    bcs @next
    lda pipe_table+2,x           ; -> room index
    rts
@next:
    txa
    clc
    adc #5
    tax
    iny
    cpy #<pipe_count
    bne @loop
    lda #$FF
    rts
.endproc

; enter_room: A = room index. Switch to the room map and drop Mario in at the top-left.
; (The surface state was saved when the sink animation began, in pipe_check.)
.proc enter_room
    pha
    lda #1
    sta room_mode
    pla
    asl                          ; map_base = room_ptrs[room*2]
    tax
    lda room_ptrs,x
    sta map_base
    lda room_ptrs+1,x
    sta map_base+1
    stz cam_x
    stz cam_x+1
    stz fb_col0
    stz fb_col0+1
    stz scroll_s
    stz prev_scroll_s
    stz shift_px
    stz XSCROLL
    stz mario_facing
    stz h_hold
    stz h_idx
    lda #16                      ; drop in at the room's entry opening (top-left)
    sta spr_x
    sta mario_vx
    sta prev_vx
    sta spr_y
    sta prev_y
    lda #2                       ; falling in
    sta jump_state
    lda #1
    sta fall_v
    jsr clear_objects             ; mushroom/coins don't follow Mario into a pipe
    jsr render_background         ; renders the room (map_base = room)
    jsr render_status_bar
    jsr draw_hud                  ; restamp the HUD over the fresh template (clock continues)
    jsr draw_player
    rts
.endproc

; exit_room: return to the surface at the saved camera, standing.
.proc exit_room
    stz room_mode
    lda #<level0_map
    sta map_base
    lda #>level0_map
    sta map_base+1
    lda save_cam_x
    sta cam_x
    lda save_cam_x+1
    sta cam_x+1
    lda save_spr_x
    sta spr_x
    lda cam_x                    ; fb_col0 = cam_x >> 3 ; scroll_s = cam_x & 7
    sta fb_col0
    lda cam_x+1
    sta fb_col0+1
    lsr fb_col0+1
    ror fb_col0
    lsr fb_col0+1
    ror fb_col0
    lsr fb_col0+1
    ror fb_col0
    lda cam_x
    and #7
    sta scroll_s
    stz prev_scroll_s
    stz shift_px
    stz jump_state               ; reappear inside the pipe, then rise out (pipe_animate)
    stz fall_v
    lda save_spr_y               ; sit 16px (2 tiles) down in the pipe...
    clc
    adc #16
    sta spr_y
    sta prev_y
    lda #2                       ; ...and rise back up to save_spr_y
    sta pipe_phase
    lda #16
    sta pipe_anim
    lda spr_x                    ; mario_vx = spr_x + scroll_s
    clc
    adc scroll_s
    sta mario_vx
    sta prev_vx
    jsr clear_objects             ; fresh surface, no stale entities
    jsr render_background         ; surface
    jsr render_status_bar
    jsr draw_hud                  ; restamp the HUD over the fresh template (clock continues)
    jsr draw_player
    rts
.endproc

; redraw_pipe_front: redraw the pipe's rim tiles (the 2 rows at/below the pipe top, across
; Mario's footprint) on top of Mario, so his lower half is hidden BEHIND the pipe as he
; slides in/out. pipe top row = save_spr_y>>3; columns = feet_col-1 .. feet_col+2.
; redraw_one: blit the bg tile at (wcol, mrow) at its on-screen position (over Mario).
.proc redraw_one
    lda wcol                     ; tile = map_base[wcol][mrow]
    sta feet_col
    lda wcol+1
    sta feet_col+1
    jsr read_map_tile
    jsr get_tile_src
    lda wcol                     ; dcol = (wcol - fb_col0) * 2
    sec
    sbc fb_col0
    asl
    sta dcol
    lda mrow                     ; dy = (mrow + 2) * 8
    clc
    adc #2
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr blit_tile
    rts
.endproc

.proc redraw_pipe_front
    lda #8
    jsr calc_feet_col            ; feet_col = Mario's centre column
    lda feet_col                 ; wcol = feet_col - 1
    sec
    sbc #1
    sta wcol
    lda feet_col+1
    sbc #0
    sta wcol+1
    lda #4                       ; 4 columns wide (memory counter; blit_tile clobbers X/Y)
    sta tcol_cnt
@col:
    lda save_spr_y               ; pipe top row
    lsr
    lsr
    lsr
    sta mrow
    jsr redraw_one
    inc mrow                     ; pipe top + 1
    jsr redraw_one
    inc wcol
    bne :+
    inc wcol+1
:   dec tcol_cnt
    bne @col
    rts
.endproc

; ---------------------------------------------------------------------------
; pipe_animate: run the sink-in (phase 1) / rise-out (phase 2) pipe animation. Mario moves
; 1px/frame; the rest of the loop is suspended. Phase 1 ends by entering the room; phase 2
; ends back in normal control. Returns with the frame drawn.
.proc pipe_animate
    jsr restore_bg               ; erase Mario at his old spot
    lda pipe_phase
    cmp #2
    beq @rise
    inc spr_y                    ; phase 1: sink down into the pipe
    bra @draw
@rise:
    dec spr_y                    ; phase 2: rise up out of the pipe
@draw:
    lda spr_x
    clc
    adc scroll_s
    sta mario_vx
    jsr draw_player
    jsr redraw_pipe_front        ; clip his lower half behind the pipe rim
    lda mario_vx
    sta prev_vx
    lda spr_y
    sta prev_y
    dec pipe_anim
    bne @ret
    lda pipe_phase               ; animation finished
    cmp #2
    beq @riseend
    lda pipe_room                ; sink done -> drop into the room
    jsr enter_room
@riseend:
    stz pipe_phase               ; back to normal control
@ret:
    rts
.endproc

; ---------------------------------------------------------------------------
; restore_bg: redraw the 3x3 bg tiles covering the 16x16 sprite at (prev_col, prev_y).
; (Restores the background where Mario used to be, so he composites over the level.)
.proc restore_bg
    lda rb_vx
    lsr
    lsr
    lsr
    sta t_col                    ; base VRAM tile col = rb_vx/8
    lda rb_y
    lsr
    lsr
    lsr
    sta t_row                    ; base tile row = rb_y/8
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
    sta feet_col
    lda fb_col0+1
    adc #0
    sta feet_col+1
    lda map_row
    sta mrow
    jsr read_map_tile            ; effective tile (used-block transform applied)
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
    cmp rb_rows
    bne @rloop
    inc ri
    lda ri
    cmp rb_cols
    bne @cloop
    rts
.endproc

; ---------------------------------------------------------------------------
; draw_column: blit one full 18-row level column to VRAM.
;   in: wcol (world column, 16-bit), dbcol (dest VRAM byte column).
; Rows 0-15 come from the level map (offset +2 rows below the status bar); rows
; 16-17 are solid dirt to fill the SV's 2 extra scanlines below the ground.
; Level tile N<$80 -> bg_chardata[N]; N>=$80 -> chardata[N] (the $8800 region).
.proc draw_column
    lda wcol                     ; read via read_map_tile (applies the used-block transform)
    sta feet_col
    lda wcol+1
    sta feet_col+1
    stz bg_row
@row:
    lda bg_row
    cmp #16
    bcs @dirt                    ; rows 16,17 -> solid dirt (extend ground onto SV's 2 extra rows)
    sta mrow
    jsr read_map_tile            ; effective tile number
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
; render_status_bar: blit the 2x20 status-bar tiles into VRAM rows 0-1, byte-aligned at
; offset 0. The NMI/IRQ raster split renders these HUD rows at XSCROLL=0, so the bar is
; pinned at screen X 0 with no per-frame compensation. Drawn once (boot) + on transitions.
.proc render_status_bar
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
    lda bg_col                   ; dcol = bg_col*2 (offset 0)
    asl
    sta dcol
    lda bg_row                   ; dy = bg_row*8
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr blit_tile
    inc bg_col
    lda bg_col
    cmp #20
    bne @colloop
    inc bg_row
    lda bg_row
    cmp #2
    bne @rowloop
    rts
.endproc

; ---------------------------------------------------------------------------
; Dynamic HUD (task #3). The status bar is rendered once (render_status_bar) with blank
; placeholders; these routines poke the live score/coins/time digit tiles into it. The font
; maps digit value -> tile number directly ('0' = tile $00 .. '9' = $09). The raster split
; renders HUD rows 0-1 at XSCROLL=0, so the digits sit pinned regardless of playfield scroll.

TIMER_RATE = 40                  ; frames per clock unit (SML's $da00 sub-counter reload = $28)

; put_hud: blit digit A (0..9) at HUD cell (X = column, hud_row = row). Preserves X.
.proc put_hud
    sta htmp                     ; save digit
    phx
    txa
    asl
    sta dcol                     ; dcol = col*2
    lda hud_row
    asl
    asl
    asl
    sta dy                       ; dy = row*8
    jsr set_dst
    lda htmp
    jsr get_tile_src
    jsr blit_tile
    plx
    rts
.endproc

; put_hud_byte: blit BCD byte A as two digits at columns X (high nibble) and X+1 (low).
.proc put_hud_byte
    pha
    lsr
    lsr
    lsr
    lsr
    jsr put_hud
    inx
    pla
    and #$0f
    jsr put_hud
    rts
.endproc

; draw_hud: refresh score (row1 cols 0-5), coins (row0 cols 6-7), time (row1 cols 17-19).
.proc draw_hud
    stz hud_row                  ; lives -> row 0 cols 6-7 (after the Mario-head icon)
    lda lives
    ldx #6
    jsr put_hud_byte
    lda #1                       ; score, coins, time -> row 1
    sta hud_row
    lda score+2                  ; score -> cols 0-5
    ldx #0
    jsr put_hud_byte
    lda score+1
    ldx #2
    jsr put_hud_byte
    lda score
    ldx #4
    jsr put_hud_byte
    lda coins                    ; coins -> cols 9-10 (after the coin icon)
    ldx #9
    jsr put_hud_byte
    lda timer+1                  ; time: hundreds digit (low nibble of timer+1) -> col 17
    and #$0f
    ldx #17
    jsr put_hud
    lda timer                    ; tens/ones -> cols 18-19
    ldx #18
    jsr put_hud_byte
    stz hud_dirty
    rts
.endproc

; tick_timer: count down the level clock; dirties the HUD when the displayed value changes.
.proc tick_timer
    dec timer_sub
    beq :+
    rts
:   lda #TIMER_RATE
    sta timer_sub
    lda timer                    ; already 000? clamp (time-up death TODO)
    ora timer+1
    bne :+
    rts
:   sed                          ; time -= 1 (BCD: timer+1 = hundreds, timer = tens/ones)
    lda timer
    sec
    sbc #1
    sta timer
    lda timer+1
    sbc #0
    sta timer+1
    cld
    lda #1
    sta hud_dirty
    rts
.endproc

; hud_init: set the clock to 400 and a fresh sub-counter (boot + level restart).
.proc hud_init
    lda #$00
    sta timer
    lda #$04
    sta timer+1
    lda #TIMER_RATE
    sta timer_sub
    lda #1
    sta hud_dirty
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
CAM_MAX = (level0_cols - 20) * 8 ; max scroll: (level width - 20 visible cols) * 8 px

; ---------------------------------------------------------------------------
; move_player: walk via the real speed table. Up to PIN_X Mario moves on screen;
; past it his rightward motion scrolls the camera (cam_x) instead, until the level
; end (CAM_MAX) where he walks to the right screen edge. The level never scrolls back.
.proc move_player                ; accelerating walk via the real speed table (px-precise)
    stz mario_duck               ; big Mario, grounded, holding Down -> duck (no walk)
    lda mario_big
    beq @walk
    lda jump_state
    bne @walk
    lda pad_held
    and #GB_DOWN
    beq @walk
    inc mario_duck
    stz h_hold
    stz h_idx
    rts
@walk:
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
    lda #14                      ; blocked by a wall to the right? (pipe/wall/step-up)
    jsr wall_ahead
    bne @rdone
    lda room_mode                ; inside a pipe room: move on screen only (no scroll)
    beq @rsurface
    lda spr_x
    clc
    adc h_step
    cmp #145
    bcc :+
    lda #144
:   sta spr_x
    rts
@rsurface:
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
    lda #1
    sta mario_facing
    jsr calc_step
    lda #1                       ; blocked by a wall to the left?
    jsr wall_ahead
    bne @ldone
    lda spr_x
    sec
    sbc h_step
    bcs :+                       ; underflow -> clamp 0
    lda #0
:   sta spr_x
@ldone:
    rts
.endproc

; calc_step: ramp the accel, read speedtab[idx+toggle] -> h_step, flip the toggle.
.proc calc_step
    lda h_hold                   ; ramp hold counter (cap 12)
    cmp #12
    bcs @capped
    inc h_hold
@capped:
    ldx #0                       ; idx 0 = slow start (<6 held)
    lda h_hold
    cmp #6
    bcc @gi
    ldx #2                       ; idx 2 = walk (~1 px/frame)
    lda pad_held                 ; hold B while moving -> idx 4 = run (~1.5 px/frame)
    and #GB_B
    beq @gi
    ldx #4
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
FB_MAX_COL = level0_cols - 24    ; last fb_col0 that keeps cols fb_col0..+23 in the level
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
    asl                          ; *4 = byte offset into the pose table
    tax
    lda mario_big                ; small or big ("Super") Mario pose set?
    beq @small
    lda mario_duck               ; big + ducking -> force the duck pose (index 4 -> offset 16)
    beq @big
    ldx #16
@big:
    lda mario_big_poses,x
    sta pose_tl
    lda mario_big_poses+1,x
    sta pose_tr
    lda mario_big_poses+2,x
    sta pose_bl
    lda mario_big_poses+3,x
    sta pose_br
    bra @haveposes
@small:
    lda mario_poses,x
    sta pose_tl
    lda mario_poses+1,x
    sta pose_tr
    lda mario_poses+2,x
    sta pose_bl
    lda mario_poses+3,x
    sta pose_br
@haveposes:
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

; ===========================================================================
; Object engine (mushroom / coin-pop entities). Minimal SoA slots, OBJ_MAX=4.
; A ?-block that holds a Super Mushroom spawns a mushroom that slides out and moves; Mario
; touching it grows him to big. A coin block launches a coin that pops up and falls away.
; (The mushroom sprite uses placeholder OBJ tiles $74-$77 — the exact ROM item tiles weren't
; identifiable statically; the coin is the real BG coin tile $5F.)
; ===========================================================================
OBJ_MUSH   = 1
OBJ_COIN   = 2
MUSH_TILE  = $83                 ; SML Super Mushroom = a single 8x8 OBJ sprite (verified via
                                 ; SameBoy OAM/VRAM dump: the only on-screen item sprite)
COIN_TILE  = $5F

; clear_objects: free all slots (level restart / pipe transition).
.proc clear_objects
    ldx #3
:   stz o_type,x
    stz o_pdr,x
    dex
    bpl :-
    rts
.endproc

; find_free_obj: X = a free slot, C=0; C=1 if all full.
.proc find_free_obj
    ldx #0
@l:
    lda o_type,x
    beq @ok
    inx
    cpx #4
    bne @l
    sec
    rts
@ok:
    clc
    rts
.endproc

; obj_set_x8: o_x[X] = feet_col * 8 (left pixel of the block column).
.proc obj_set_x8
    lda feet_col
    sta o_xl,x
    lda feet_col+1
    sta o_xh,x
    asl o_xl,x
    rol o_xh,x
    asl o_xl,x
    rol o_xh,x
    asl o_xl,x
    rol o_xh,x
    rts
.endproc

; spawn_mushroom: appear on top of the block at (feet_col,mrow), sliding right.
.proc spawn_mushroom
    jsr find_free_obj
    bcs @full
    lda #OBJ_MUSH
    sta o_type,x
    jsr obj_set_x8
    lda mrow                     ; o_y = mrow*8 (feet rest on the block top)
    asl
    asl
    asl
    sta o_y,x
    lda #1                       ; walk right
    sta o_vx,x
    lda #$FB                     ; vy = -5/update: the upward "pop" (~15px rise, matches trace)
    sta o_vy,x
    lda #6                       ; consume delay (updates) so the bonk can't insta-grab it
    sta o_tmr,x
    stz o_pdr,x
@full:
    rts
.endproc

; spawn_coin: a coin pops straight up from the block and falls away (~24 frames).
.proc spawn_coin
    jsr find_free_obj
    bcs @full
    lda #OBJ_COIN
    sta o_type,x
    jsr obj_set_x8
    lda mrow
    asl
    asl
    asl
    sta o_y,x
    stz o_vx,x
    lda #$FA                     ; vy = -6 (launch up)
    sta o_vy,x
    lda #24
    sta o_tmr,x
    stz o_pdr,x
@full:
    rts
.endproc

; update_objects: per-frame physics for every active slot.
.proc update_objects
    stz oi
@loop:
    ldx oi
    lda o_type,x
    beq @next
    cmp #OBJ_COIN
    beq @coin
    jsr upd_mush
    bra @next
@coin:
    jsr upd_coin
@next:
    inc oi
    lda oi
    cmp #4
    bne @loop
    rts
.endproc

; upd_coin (X=slot): y += vy ; vy += gravity ; expire after o_tmr frames.
.proc upd_coin
    clc
    lda o_y,x
    adc o_vy,x                   ; vy is signed 8-bit
    sta o_y,x
    inc o_vy,x                   ; gravity
    dec o_tmr,x
    bne @done
    stz o_type,x                 ; lifetime over -> free
@done:
    rts
.endproc

; upd_mush (X=slot): slide horizontally, fall under gravity onto the floor, and grow Mario
; when he overlaps it. (No wall collision — the mushroom is short-lived; documented.)
.proc upd_mush
    ; The original's object AI runs every OTHER frame (~30Hz): the mushroom moves 1px per
    ; update = 0.5 px/frame (verified via an mGBA trace of the real game). So skip odd frames.
    lda frame_count
    lsr
    bcc :+
    rts                          ; odd frame -> skip (object AI runs every other frame)
:   ; Ballistic from spawn: an initial upward velocity (the "pop") + gentle gravity, walking
    ; right the whole time. o_tmr is now just a consume delay so Mario's bonk can't insta-grab.
    ; --- wall check: tile AHEAD (direction of motion) at body row -> reverse (RE: type $28
    ;     PhysicsParam $ffc7=$24, &$0c=$04 = reverse on a horizontal collision) ---
    lda o_vx,x
    bmi @aleft
    lda o_xl,x                   ; moving right: ahead col = (o_x + 8) >> 3
    clc
    adc #8
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    bra @ahead
@aleft:
    lda o_xl,x                   ; moving left: ahead col = (o_x - 1) >> 3
    sec
    sbc #1
    sta feet_col
    lda o_xh,x
    sbc #0
    sta feet_col+1
@ahead:
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lda o_y,x                    ; body row = (o_y >> 3) - 1
    lsr
    lsr
    lsr
    sec
    sbc #1
    sta mrow
    jsr read_solid
    beq @nowall
    ldx oi                       ; wall ahead -> reverse direction, don't step into it
    lda o_vx,x
    eor #$FF
    ina
    sta o_vx,x
    bra @vert
@nowall:
    ldx oi                       ; --- horizontal: o_x += vx (sign-extended), 1 px/frame ---
    ldy #0                       ; (set Y BEFORE lda so the lda's N flag survives to bpl)
    lda o_vx,x
    bpl :+
    ldy #$FF                     ; vx negative -> high byte = $FF (sign-extend), else $00
:   sty tmpH
    clc
    lda o_xl,x
    adc o_vx,x
    sta o_xl,x
    lda o_xh,x
    adc tmpH
    sta o_xh,x
@vert:
    ; --- gentle ballistic: apply the current (signed) vy, THEN accelerate it toward a +1
    ;     terminal. Apply-first so the spawn -5 gives a full -5 first step (~15px rise). ---
    ldx oi
    clc
    lda o_y,x
    adc o_vy,x                   ; o_y += vy (negative = the upward pop)
    sta o_y,x
    lda o_vy,x
    bmi @grav                    ; still rising -> keep accelerating toward fall
    cmp #1
    bcs @gdone                   ; terminal = +1 px/update (= 0.5 px/frame fall)
@grav:
    inc o_vy,x
@gdone:
    ; --- floor: feet_col=(o_x+4)>>3, mrow=o_y>>3 ; snap if solid ---
    lda o_xl,x
    clc
    adc #4
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lda o_y,x
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid
    beq @air
    ldx oi                       ; landed: snap o_y to the tile top, vy=0
    lda mrow
    asl
    asl
    asl
    sta o_y,x
    stz o_vy,x
@air:
    ldx oi                       ; consume only after the spawn delay (no insta-grab on bonk)
    lda o_tmr,x
    beq @cons
    dec o_tmr,x
    rts
@cons:
    ; --- consume: Mario overlaps the mushroom? ---
    ldx oi
    lda cam_x                    ; Mario world X = cam_x + spr_x
    clc
    adc spr_x
    sta tmpL
    lda cam_x+1
    adc #0
    sta tmpH
    sec                          ; dx = mario_wx - o_x
    lda tmpL
    sbc o_xl,x
    sta tmpL
    lda tmpH
    sbc o_xh,x
    sta tmpH
    bpl @posdx                   ; abs(dx)
    sec
    lda #0
    sbc tmpL
    sta tmpL
    lda #0
    sbc tmpH
    sta tmpH
@posdx:
    lda tmpH
    bne @done                    ; |dx| >= 256 -> far
    lda tmpL
    cmp #14
    bcs @done
    lda spr_y                    ; dy = |spr_y - o_y| < 16 ?
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #16
    bcs @done
    ; --- eat it ---
    lda mario_big
    bne @score
    lda #1
    sta mario_big                ; grow to Super Mario!
@score:
    lda #$00
    ldx #$10                     ; +1000
    jsr add_score
    ldx oi
    stz o_type,x                 ; remove the mushroom
@done:
    rts
.endproc

; erase_objects: repaint the background where each object was drawn last frame (shifted with
; the DMA scroll like Mario). Always 3x3 tiles (covers the 16px sprite + sub-pixel spill).
.proc erase_objects
    stz oi
@loop:
    ldx oi
    lda o_pdr,x
    beq @next
    lda o_pvx,x
    sec
    sbc shift_px
    sta rb_vx
    lda o_pvy,x
    sta rb_y
    lda #3
    sta rb_cols
    sta rb_rows
    jsr restore_bg
@next:
    inc oi
    lda oi
    cmp #4
    bne @loop
    rts
.endproc

; draw_objects: draw every active slot at its on-screen position; record it for next erase.
.proc draw_objects
    stz oi
@loop:
    ldx oi
    lda o_type,x
    beq @off
    sec                          ; VRAM pixel X = o_x - cam_x + scroll_s
    lda o_xl,x
    sbc cam_x
    sta tmpL
    lda o_xh,x
    sbc cam_x+1
    sta tmpH
    lda tmpL
    clc
    adc scroll_s
    sta tmpL
    bcc :+
    inc tmpH
:   lda tmpH
    bne @off                     ; off-screen (negative or > 255)
    lda tmpL
    cmp #168
    bcs @off
    sta ovx
    jsr draw_obj_sprite
    ldx oi
    lda ovx
    sta o_pvx,x
    lda o_y,x
    sta o_pvy,x
    lda #1
    sta o_pdr,x
    bra @next
@off:
    ldx oi
    stz o_pdr,x
@next:
    inc oi
    lda oi
    cmp #4
    bne @loop
    rts
.endproc

; draw_obj_sprite: draw object oi at (ovx, o_y) — mushroom = 1 OBJ tile, coin = 1 BG tile.
.proc draw_obj_sprite
    stz do_flip
    lda ovx
    and #3
    sta spr_subx                 ; sub-pixel within the byte (SV = 4 px/byte)
    lda ovx
    lsr
    lsr                          ; byte column = ovx / 4 (NOT /8 — 4 px per byte)
    sta spr_col
    ldx oi
    lda o_type,x
    cmp #OBJ_COIN
    beq @coin
    ; --- mushroom: one 8x8 OBJ tile, drawn at the feet line (o_y + 8) ---
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8                       ; o_y is the 16px-sprite convention; an 8px item sits +8 lower
    sta dy
    ldx #MUSH_TILE
    jsr draw_quad
    rts
@coin:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    jsr set_dst
    lda #COIN_TILE               ; BG coin tile -> bg_chardata, drawn transparent
    jsr get_tile_src
    stz blit_opaque
    jsr sprite_blit_subpx
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
