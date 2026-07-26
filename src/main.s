; Super Mario Land — Watara Supervision port.
; Phase 5: boot + NMI frame loop + input + software renderer (accurate Mario sprite).
; Hardware per docs/20-supervision-hardware.md; port plan per docs/21-port-mapping.md.

.setcpu "65C02"
.include "supervision.inc"
.import chardata             ; OBJ tiles (src/gfxdata.s) — also the $8800 BG tiles $80-$FF
.import bg_chardata          ; BG tiles (level tiles $00-$7F)
.import level_hdr            ; bank 0's level header (leveldata.s); banks 1+ put theirs at
.import __TITLE0_LOAD__      ; the TITLE0 range (pack_banks.py) — load_level picks the base
.import jumparc              ; Mario's jump arc table (27 bytes; $7F = apex)
.import speedtab            ; horizontal walk speed table (px/frame)
.import mario_poses          ; 6 poses x 4 tiles (metasprite tiles from ROM $4C37)
.import mario_big_poses      ; 7 big-Mario poses x 4 tiles (stand,walkA,walkB,jump,skid,walkC,duck)
.import __BOOT6_LOAD__       ; the boot blob's bank-6 load address (run at $1500)
.import statusbar_tiles      ; 2x20 status-bar template (ROM $3F9C)

; ---------------------------------------------------------------------------
.segment "ZEROPAGE"
frame_flag:  .res 1          ; set by NMI, consumed by main loop -- MUST stay at
                             ; $00 (frame_count at $01): svharness pokes them by
                             ; hard address as the fake NMI tick
frame_count: .res 1          ; ++ every NMI (~61 Hz)
blk_key:     .res 2          ; find_block compare key (room-namespaced)
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
tmpL2:       .res 1          ; second/third 16-bit scratch (platform overlap math --
tmpH2:       .res 1          ;   runs while tmpL still holds jump_player's fall delta)
tmpL3:       .res 1
tmpH3:       .res 1
oi2:         .res 1          ; secondary object index (platform scans from player code)
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
map_base:    .res 2          ; current tilemap base (the surface map, or a pipe room)
lvl_ptr:     .res 2          ; load_level scratch: header table source pointer
dirty_bud:   .res 1          ; movers accepted for redraw this frame (flicker cap)
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
mario_grow:  .res 1          ; >0 = small->big grow animation running (counts 80->0, game frozen)
mario_superball: .res 1      ; 1 = Superball Mario (got a flower) -> B fires a bouncing superball
mario_starT: .res 1          ; star invincibility ticks (248..0, dec every 4th frame; $c0d3)
star_flash:  .res 1          ; star flash phase: 1 = Mario invisible this 4-frame window
mc_tmr:      .res 1          ; multi-coin window, 255 frames from the FIRST bonk ($c0ce)
mc_coll:     .res 1          ; the active multi-coin block's cell (col lo/hi + row);
mc_colh:     .res 1          ;   mc_colh = $FF -> none active (init'd at reset/respawn —
mc_row:      .res 1          ;   ZP is zero-cleared, and col-hi 0 is a real column)
goal_phase:  .res 1          ; level-clear sequence: 0 none, 1 jingle, 2 hold, 3 tally, 4 end
goal_tmr:    .res 1          ; frames left in the current goal phase
goal_top:    .res 1          ; 1 = Mario exited through the TOP door (bonus game; TODO)
ride:        .res 1          ; 0 = not riding; else (slot+1) of the platform under Mario
bonus_phase: .res 1          ; bonus game: 0 off, 2 play, 3 walk, 5 award
ending13:    .res 1           ; x-3 sphere touched: the rescue ending follows the tally
e_phase:     .res 1           ; ending sub-phase (goal_phase == 5)
e_own:       .res 1           ; 1 = the ending owns the frame (wipe + room scenes)
e_tmr:       .res 1
e_ix:        .res 1           ; sub-counter (rope tiles / wipe col / text index)
e_mx:        .res 1           ; moth screen x (left edge)
e_my:        .res 1           ; moth screen y (top)
e_px:        .res 1           ; last drawn moth box (for the blank erase)
e_py:        .res 1
e_hop:       .res 1           ; hop-arc segment index / rest counter
e_cap:       .res 1           ; scroll: captive-draw e_tmr mark (75 + lattice pad)
b_tick:      .res 1          ; 4-frame tick divider ($da22; harness-calibrated)
b_ladder:    .res 1          ; ladder cycle counter 1..6 ($da27); odd = visible at gap (n-1)/2
b_floor:     .res 1          ; Mario's floor 0..3 (top..bottom)
b_prz:       .res 4          ; the 4 prize tiles top..bottom (rotated ring)
b_awn:       .res 1          ; lives left to award
b_awt:       .res 1          ; award pacing timer
b_row:       .res 1          ; bput cursor: BG row
b_col:       .res 1          ; bput cursor: BG col
b_i:         .res 1          ; loop counter safe across bput (set_dst clobbers X!)
b_gap:       .res 1          ; the locked ladder's gap 0..2 (between floors gap..gap+1)
paused:      .res 1          ; 1 = game paused (Start toggles)
cam_dead:    .res 2          ; camera at the moment of death (checkpoint decision)
spawn_idx:   .res 1          ; next spawn-table entry (x4 = byte offset; table < 64 entries)
mario_shrink: .res 1         ; >0 = big->small shrink animation (mirror of mario_grow)
hurt_inv:    .res 1          ; post-hit mercy frames (no enemy damage while > 0)
prev_vis:    .res 1          ; Mario appearance hash (facing^duck^big) at his last draw
stream_pend: .res 1          ; margin columns still to stream after a shift (amortized 1/frame)
scroll_vis:  .res 1          ; scroll value the line-16 IRQ latches (updated ONLY at frame start)
m_dirty:     .res 1          ; Mario needs erase+redraw this frame
combo_t:     .res 1          ; stomp-combo window ($ff9c): 50 frames
skid_t:      .res 1          ; turn-around brake ($c20d=1 state): 8f input-ignored freeze
move_t:      .res 1          ; momentum counter ($c20c): +1/held frame cap 6, -1/neutral
mdir:        .res 1          ; last motion direction ($c20d): 0 none, 1 right, 2 left
walk_t:      .res 1          ; walk-anim tick ($c20b): pose advances every 4 moving frames
walk_i:      .res 1          ; walk-cycle position 0..2 -> pose 2,5,1 (GB metas 1,2,3)
combo_n:     .res 1          ; chain count ($ff9d): 0..3, doubles the value code
death_anim:  .res 1          ; >0 = the death hop is playing (index+1 into death_curve)
timeup:      .res 1          ; the clock ran out: after the hop, show " TIME UP " (state $3B)
sfx_p:       .res 2          ; SFX stream pointer (0 hi = idle)
sfx_wait:    .res 1          ; frames until the pending row applies
sfx_used:    .res 1          ; channel mask the stream touched (for the end-silence)
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
h_idx:       .res 1          ; persistent speed index ($c20e): 0 slow, 2 walk, 4 run
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
p_shlo:      .res 2          ; sub-pixel blit: shift table pages for spr_subx (page-
p_shhi:      .res 2          ; aligned BSS, boot-built; masks = M(shifted) per row)
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
stream_flag: .res 1          ; stream_one drew a margin column this frame (margin sprites redraw)
water_on:   .res 1           ; 1-3: animate the $5D shore tiles (GB $d014)
w_i:        .res 1           ; l3_water: fb column / map row cursors
w_row:      .res 1
stream_x0:  .res 1           ; fb-x span [x0,x1) rewritten this frame by stream/blank
stream_x1:  .res 1           ; (valid only while stream_flag=1)
; --- music sequencer state (two channel blocks, stride 12, X = 0/12) ---
mus_pos:     .res 2          ; +0  phrase read pointer (hi 0 = channel inactive)
mus_list:    .res 2          ; +2  phrase-list read pointer
mus_wait:    .res 1          ; +4  ticks until the next cell
mus_len:     .res 1          ; +5  current cell length (64Hz ticks; $Ax sets it)
mus_env:     .res 1          ; +6  instrument envelope (GB NRx2: vvvv d ppp)
mus_duty:    .res 1          ; +7  VOLDUTY base: $40 | duty<<4
mus_vol:     .res 1          ; +8  live volume 0-15
mus_ectr:    .res 1          ; +9  envelope period countdown
             .res 2          ; +10 stride pad
mus_ch2:     .res 12         ; channel 2 block (same layout)
mus_ch3:     .res 12         ; GB ch3 (wave line): +10 = borrowed SV reg offset ($FF none)
mus_ch4:     .res 12         ; GB ch4 (drums -> SV noise): +10 = burst cutoff ticks
sq_user:     .res 2          ; who last wrote each SV square: 0 = its owner line, 1 = ch3
pause_snd:   .res 1          ; pause ding-dong countdown (3 pips on ch2; RE $66D6)
mus_on:      .res 1          ; nonzero = a track is playing
mus_acc:     .res 1          ; 61Hz frame -> tick-rate Bresenham accumulator
mus_rate:    .res 1          ; Bresenham add: 3=64Hz, 18=78.8Hz (time 100), 32=93.1Hz (time 50)
mus_lt:      .res 2          ; current track's note-length table (16 bytes)

.segment "BSS"
; --- sub-pixel blit shift tables (built at boot; page-aligned: BSS starts $0200) ---
; shtab_lo/hi[subx][b] = the 16-bit b << (subx*2), split. (Transparency masks are
; computed per row from the SHIFTED bytes — M() commutes with 2-bit-aligned shifts.)
shtab_lo:    .res 1024      ; 4 pages: subx 0..3
shtab_hi:    .res 1024
; --- per-level bindings, set by load_level from the current bank's level_hdr ---
cur_level:   .res 1          ; level id 0.. (GB $ffe4); selects the ROM bank
hdr_buf:     .res 22         ; RAM copy of the current bank's level header
                             ; (+18/19: base for quad tiles $A0-$DC -- chardata for
                             ; W1; the in-bank overlay blob minus $A00 for W2+)
p1c:         .res 1          ; render pass-1 loop counter (rotated scan)
rot1:        .res 1          ; pass-1 scan origin, +1 per frame (fairness)
surf_map:    .res 2          ; surface tilemap base (map_base resets to this)
lvl_cols:    .res 2          ; level width in columns
cam_max:     .res 2          ; max scroll = (lvl_cols - 20) * 8 px
fbmax_col:   .res 2          ; last fb_col0 with cols fb_col0..+23 inside the level
room_tbl:    .res 6          ; up to 3 underground-room map pointers
pipe_cnt:    .res 1          ; pipe entries in pipe_tab
pipe_tab:    .res 15         ; RAM copy: 5 bytes/pipe, up to 3 pipes
block_tab:   .res 40         ; RAM copy: 4 bytes/block, up to 10 ?-block entries
spawn_tab:   .res 384        ; RAM copy: 5 bytes/spawn + $FFFF sentinel
revpix:      .res 256        ; reverse the 4 2bpp pixels in a byte (built at boot)
flipbuf:     .res 16         ; row-reversed tile scratch for the Y-flipped corpse draw
tile_mod:    .res 680        ; "modified" bitmap, 1 bit per (col,row): used ?-block / broken
                             ; brick / taken coin. Cols 0-319 = the surface; the LAST 40
                             ; bytes = the ROOM's 20 cols (offset +640): room keys collided
                             ; with surface cols 0-19 (bonks/coins leaked into room bricks
                             ; -- the U-ring gaps, user-caught). Cleared at room entry: GB
                             ; rooms are FRESH each visit.
; --- object slots (items / coin-pop / brick debris / enemies). SoA, 10 entries like the
;     GB ($D100-$D190): 1-2's goal area runs 2 bees + 4 arrows + platform + 2 stones. ---
OBJ_MAX = 10
o_type:      .res 10          ; 0 free, else OBJ_*
o_xl:        .res 10          ; world pixel X (16-bit)
o_xh:        .res 10
o_y:         .res 10          ; world pixel Y (same space as spr_y: feet line)
o_vx:        .res 10          ; signed velocity X
o_vy:        .res 10          ; signed velocity Y (gravity / phase)
o_tmr:       .res 10          ; state timer / lifetime
o_pvx:       .res 10          ; last drawn VRAM pixel X (for erase)
o_pvy:       .res 10          ; last drawn VRAM pixel Y
o_pdr:       .res 10          ; was drawn last frame?
o_st:        .res 10          ; sub-state (star: vy ramp index; debris: jump-arc index)
o_pw:        .res 10          ; last drawn width in tile cols (2 = one quad, 3 = popup pair)
o_pfr:       .res 10          ; anim token at the last draw (flip/twinkle cadence dirty test)
o_nvx:       .res 10          ; this frame's computed screen x (render_all pass 1)
o_ndy:       .res 10          ; this frame's computed dy
o_nfl:       .res 10          ; bit0 = dirty, bit1 = visible (render_all flags)
o_hp:        .res 10          ; extra hits to survive (fly: 1 -- two balls kill, user/GB)
ovl_vec:     .res 12          ; overlay ABI vectors: spawn,update,token,gift,draw,
                             ; width. 1-3 -> the kit's link addresses (staged to
                             ; l3vec_ram at boot); W2+ -> the blob's own table
l3vec_ram:   .res 12          ; the kit's vector values (copied from BOOT6 data)

.segment "ZEROPAGE"
mus_base:    .res 2          ; current track's data base (per-track: LEVELS or FIXED).
                             ; NOT at the ZP head: harness scripts poke mem[0]/mem[1]
                             ; as frame_flag/frame_count -- that layout is ABI.

; ---------------------------------------------------------------------------
.segment "CODE"

music2_data:                     ; 1-3 ending tracks (boss/rescue/reveal): FIXED-
    .incbin "../build/audio/music2.bin"  ; resident so they play with bank 2 mapped

.if .defined(HWMA) .or .defined(HWMB) .or .defined(HWMC) .or .defined(HWMD)
probe_stripes:                   ; the full proven liturgy + stripes, FIXED-ROM
    lda #$A0                     ; only: reached = everything before it survived
    sta LCD_XSIZE
    lda #$A0
    sta LCD_YSIZE
    stz XSCROLL
    stz YSCROLL
    lda #$DF
    sta SYS_CTRL
    lda #$0F
    sta LCD_DRIVE
    lda #0                       ; hwtest3's order: silence sound right after
    ldx #7                       ; SYS_CTRL (probe A arrives with garbage regs)
:   sta $2010,x
    dex
    bpl :-
    sta $201B
    sta $201C
    sta $2028
    sta $2029
    sta $202A
    stz lvl_ptr
    lda #$40
    sta lvl_ptr+1
    ldy #0
    lda #$1B
@pf:
    sta (lvl_ptr),y
    iny
    bne @pf
    inc lvl_ptr+1
    ldx lvl_ptr+1
    cpx #$60
    bne @pf
@ps: bra @ps
.endif

.proc reset
    sei
    cld                      ; 65C02: ensure binary mode
    ldx #$FF
    txs
.ifdef HWMARKER0
    lda #$A0                     ; probe 0: hwtest3's byte-exact BB liturgy inside
    sta LCD_XSIZE                ; the REAL game image -- no window, no RAM exec.
    lda #$A0                     ; Stripes = the image itself serves fine; the
    sta LCD_YSIZE                ; killer is in the game's own boot path.
    stz XSCROLL
    stz YSCROLL
    lda #$DF
    sta SYS_CTRL
    lda #$0F
    sta LCD_DRIVE
    lda #0
    ldx #7
:   sta $2010,x
    dex
    bpl :-
    sta $201B
    sta $201C
    sta $2028
    sta $2029
    sta $202A
    stz lvl_ptr
    lda #$40
    sta lvl_ptr+1
    ldy #0
    lda #$1B
@m0f:
    sta (lvl_ptr),y
    iny
    bne @m0f
    inc lvl_ptr+1
    ldx lvl_ptr+1
    cpx #$60
    bne @m0f
@m0: bra @m0
.endif
    lda #(6 << 5)            ; map BANK 6 (display/ints off): the one-shot boot
    sta SYS_CTRL             ; bulk is COPIED TO RAM and run there -- real hw
    lda #<__BOOT6_LOAD__     ; proved long boot loops fetching through the cart
    sta lvl_ptr              ; window die on marginal contacts; RAM execution
    lda #>__BOOT6_LOAD__     ; is immune (the copy itself is short exposure)
    sta lvl_ptr+1
    jsr copy_win8            ; 8 pages -> $1500 (the overlay window, free at boot)
.ifdef HWMA
    jmp probe_stripes        ; probe A: window copy done, no RAM execution
.endif
    jsr $1500                ; = boot6_init, running from RAM
.if .defined(HWMB) .or .defined(HWMC) .or .defined(HWMD)
    jmp probe_stripes        ; probes B/C/D: boot6 truncated by the same flag
.endif

    ; --- bank 0 + NMI/IRQ + LCD ON. Commercial boots (Block Buster $DF) set the
    ;     LCD bit AFTER the LCD regs; the REAL panel stays dark without bit3.
    lda #(SYSCTRL_NMI_EN | SYSCTRL_TIMER_IRQ | SYSCTRL_LCD | SYSCTRL_BANK0)
    sta SYS_CTRL
.ifdef HWMARKER1
    stz lvl_ptr                  ; probe: hwtest8's exact proven-visible pattern --
    lda #$40                     ; stripe-fill VRAM from FIXED ROM code, then spin.
    sta lvl_ptr+1                ; Stripes = the whole RAM-boot phase survived.
    ldy #0
    lda #$1B
@m1f:
    sta (lvl_ptr),y
    iny
    bne @m1f
    inc lvl_ptr+1
    ldx lvl_ptr+1
    cpx #$60
    bne @m1f
@m1: bra @m1
.endif

    jsr build_row48              ; dy*48 VRAM-stride tables
    jsr build_shtab              ; sub-pixel blit shift tables
                                 ; (p_shlo/p_shhi stay 0 forever -- the boot6 ZP
                                 ; clear already zeroed them)
.ifdef HWMARKER2
    stz lvl_ptr                  ; probe: stripes = the window-resident builders
    lda #$40                     ; survived; drawn from FIXED ROM, then spin
    sta lvl_ptr+1
    ldy #0
    lda #$1B
@m2f:
    sta (lvl_ptr),y
    iny
    bne @m2f
    inc lvl_ptr+1
    ldx lvl_ptr+1
    cpx #$60
    bne @m2f
@m2: bra @m2
.endif
    jsr clear_vram
    jsr title_screen             ; the SML title; waits for Start (Select = level select)
    jsr clear_vram
    jsr load_level               ; map the bank + bind level pointers/limits to its header
    jsr ovl_bind                 ; window vectors for this level's overlay
    lda surf_map                 ; start on the surface map
    sta map_base
    lda surf_map+1
    sta map_base+1
    jsr render_background        ; draw the World 1-1 scene
    jsr render_status_bar        ; status bar (drawn once; pinned by the NMI/IRQ raster split)
    lda #$02                     ; SML starts with 2 spare lives ($da15 init)
    sta lives
    lda #$FF                     ; no multi-coin block active (ZP cleared to 0 above)
    sta mc_colh
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
    lda #3                       ; 64Hz driver (GB: TMA=0 at level init, $0769)
    sta mus_rate
    jsr lvl_music                ; per-level tune (GB table $07CE)
    cli


.segment "BOOT6"                 ; ONE-SHOT boot bulk: runs with bank 6 mapped,
                                 ; interrupts/display off (called from reset)
.proc boot6_init
    lda #0                       ; --- silence the sound hardware FIRST (BB $D8A7
    ldx #7                       ; liturgy): these regs hold GARBAGE at real power
:   sta $2010,x                  ; -on; every commercial boot zeroes them before
    dex                          ; doing anything else. $2010-$2017, noise, DMA.
    bpl :-
    sta $201B
    sta $201C
    sta $2028
    sta $2029
    sta $202A
.ifdef HWMB
    rts                          ; probe B: RAM exec + sound zeroing only
.endif
    lda #0                       ; --- clear zero page ---
    tax
:   sta $00,x
    inx
    bne :-
    lda #<$0200                  ; --- clear WRAM $0200..$14FF + $1D00..$1FFF
    sta ptr                      ; (SKIPPING $1500-$1CFF: this very code runs
    lda #>$0200                  ; there now) ---
    sta ptr+1
    ldx #$13                     ; $13 pages = $0200..$14FF
    lda #0
@clr:
    ldy #0
:   sta (ptr),y
    iny
    bne :-
    inc ptr+1
    dex
    bne @clr
    lda #$1D                     ; $1D00..$1FFF (3 pages)
    sta ptr+1
    ldx #3
    lda #0
@clr2:
    ldy #0
:   sta (ptr),y
    iny
    bne :-
    inc ptr+1
    dex
    bne @clr2
.ifdef HWMC
    rts                          ; probe C: + ZP/WRAM clears
.endif
    jsr build_revpix             ; pixel-reverse lookup for horizontal sprite flip
    ldx #11                      ; stage the 1-3 kit's overlay-vector values: the
:   lda l3vec_tab,x              ; table costs FIXED nothing here in bank 6
    sta l3vec_ram,x
    dex
    bpl :-
.ifdef HWMD
    rts                          ; probe D: + build_revpix and l3vec staging
.endif
    lda #$A0                     ; --- LCD setup, Block Buster's exact order ---
    sta LCD_XSIZE                ; 160 px wide
    lda #VRAM_LINES
    sta LCD_YSIZE                ; 160 lines
    stz scroll_vis
    stz XSCROLL
    stz YSCROLL
    lda #$0F                     ; the drive/bias value every commercial boot
    sta LCD_DRIVE                ; writes; Potator ignores it, the panel may not
    ; --- BOOT SPLASH: stripes for ~2.5s. REAL-HW LAW (hwtest9, black-not-
    ; blank): SYS_CTRL bit3 gates the VIDEO SUBSYSTEM -- VRAM writes are
    ; LOST while it is clear. The bit must be ON BEFORE the fill. ---
.ifndef NOSPLASH
    lda #((6 << 5) | SYSCTRL_LCD)
    sta SYS_CTRL
    stz ptr
    lda #$40
    sta ptr+1
    ldy #0
    lda #$1B                     ; 4-shade stripe byte
@sp: sta (ptr),y
    iny
    bne @sp
    inc ptr+1
    ldx ptr+1
    cpx #$60
    bne @sp
    ldx #40                      ; ~2.5s busy delay (no interrupts yet):
@d0: ldy #0                      ; 40 * 65536 inner iterations
@d1: dec ptr
    bne @d1
    dey
    bne @d1
    dex
    bne @d0
.endif
    rts
l3vec_tab:  .addr l3_spawn, l3_update, l3_token, l3_gift, l3_draw, l3_width
.endproc
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
.segment "CODE"

.ifdef HWMARKER1
HWMARK = 1
.endif
.ifdef HWMARKER2
HWMARK = 1
.endif
main_loop:
    lda frame_flag
    beq main_loop
    stz frame_flag
    ; ==== FRAME-START RENDER (the beam is in the HUD rows for the first ~4096 cyc, and
    ; above any sprite for much longer: everything drawn here can't be caught mid-blit).
    ; Uses the state the LOGIC phase computed last frame. ====
    jsr sfx_tick                 ; sound streams run every frame, all modes
    jsr mus_tick                 ; the music sequencer too (self-gated while paused)
    lda bonus_phase              ; the bonus game, the ending scenes and pipe
    ora pipe_phase               ; animations own their own drawing
    ora e_own
    beq :+
    lda scroll_s
    sta scroll_vis
    jmp @skiprender
:   jsr scroll_apply             ; shift decision + DMA + fb_col0 + scroll_s, ALL here at
    lda scroll_s                 ; frame start: pixels, coords and the scroll register mutate
    sta scroll_vis               ; together, and the logic phase only ever sees coherent state
    stz stream_flag
    lda shift_px                 ; the linear DMA shift BLEEDS each line's right 8 bytes
    beq :+                       ; from the line below (fb_shift8): BLANK the bled tails
    jsr blank_margin             ; NOW (blank = sky) — they were showing as garbage bands
    lda #4                       ; over dense second-half terrain whenever scroll_s > 0,
    sta stream_pend              ; then queue the 4 fresh columns (1 drawn per frame)
:   lda stream_pend
    beq :+
    jsr stream_one               ; one margin column per frame — BEFORE the sprites, so a
    dec stream_pend              ; streamed column never covers a same-frame sprite draw
    lda #1
    sta stream_flag
:   lda water_on                 ; 1-3: the $5D shore tiles shimmer every 8 frames
    beq :+
    jsr l3_water
:   jsr render_all               ; sprites: overlap-safe erase set -> erases -> draws
    lda hud_dirty
    beq :+
    stz hud_dirty
    jsr draw_hud                 ; after the beam leaves rows 0-15: clean next frame
:
@skiprender:
    lda pipe_phase              ; pipe sink/rise animation running? -> just animate
    beq @normal
    jsr pipe_animate
    jmp main_loop
@normal:
    jsr read_input
    lda pad_pressed              ; Start toggles pause (gameplay only, like the original's
    and #GB_START                ; state<$0e gate; the bonus is not pausable -- and
    beq @nopause                 ; neither is the clear/rescue sequence (GB states
    lda bonus_phase              ; $0e+): pausing mid-ending let the strip restore
    ora goal_phase               ; stamp map tiles over the hand-drawn room scenes
    bne @nopause
    lda paused
    eor #1
    sta paused
    jsr pause_strip              ; show/remove the bottom-right ♥PAUSE♥ strip (RE $079C)
    lda paused
    beq @unpaused
    stz CH1_VOLDUTY              ; entering pause silences the (frozen) music squares;
    stz CH2_VOLDUTY              ; a live SFX rewrites its registers on its next row
    stz CH4_FREQVOL              ; ...and a mid-ring drum (user: noise persisted through
                                 ; pause -- the frozen music can't run its env/cutoff)
    lda #20                      ; arm the ding-dong (GB: $ffde=$30, notes as it passes
    sta pause_snd                ; $28/$20/$18 -- three pips, 8 ticks apart, $66D6)
    bra @nopause
@unpaused:
    stz pause_snd                ; unpause mid-jingle: silence the pip
    lda #$40
    sta CH2_VOLDUTY
@nopause:
    lda paused
    beq :+
    lda pad_pressed              ; DEBUG (user request): Select while PAUSED
    and #GB_SELECT               ; toggles small <-> big Mario for playtesting
    beq @nosizet
    lda mario_big
    eor #1
    sta mario_big
    sta mario_superball          ; big brings the superball; small drops it (GB rule)
@nosizet:
    jsr pause_dingdong
    jmp main_loop
:   lda death_anim               ; the death hop owns the frame (everything else frozen)
    beq :+
    jsr death_frame
    jmp main_loop
:   lda bonus_phase              ; bonus game running? it owns the whole frame
    beq :+
    jsr bonus_frame
    jmp main_loop
:   lda goal_phase               ; level-clear running? jingle -> tally -> next level
    beq :++
    jsr goal_seq
    lda bonus_phase              ; just switched to the bonus screen? nothing else may draw
    beq :+
    jmp main_loop
:   jsr update_objects           ; platforms keep patrolling during the clear (trace-verified)
    jmp @play
:   lda hurt_inv                 ; post-hit mercy ticks down (Mario blinks)
    beq :+
    dec hurt_inv
:   lda combo_t                  ; stomp-combo window ($ff9c) ticks down
    beq :+
    dec combo_t
:   lda mario_shrink             ; big->small shrink running? freeze + flash like the grow
    beq :+
    dec mario_shrink
    bne @shf
    stz mario_big                ; shrink done: small, powers lost, mercy window
    stz mario_superball
    lda #90
    sta hurt_inv
@shf:
    jmp @play
:   lda mario_grow               ; small->big grow running? freeze the action, just flash
    bne @growing
    lda mc_tmr                   ; multi-coin window ticks every frame ($c0ce)
    beq :+
    dec mc_tmr
:   lda mario_starT              ; star: dec every 4th frame, toggling the flash ($c0d3/Call_1f03)
    beq @nostar
    lda frame_count
    and #3
    bne @nostar
    lda mus_on                   ; the star tune is one-shot: when it ends, the star
    beq @starout                 ; ends with it ($1F08: $dfe9==0 -> expire now)
    dec mario_starT
    bne @starflash
@starout:
    stz mario_starT
    stz star_flash               ; expired -> visible for good
    ldx cur_level                ; music back via the level table ($1F1C -> $07A3):
    lda lvl_track_tab,x
    ldx room_mode                ; the underground rooms restore their own tune
    beq @strestore
    lda #MUS_UNDER
@strestore:
    jsr mus_start
    bra @nostar
@starflash:
    lda star_flash
    eor #1
    sta star_flash
@nostar:
    jsr try_fire                 ; B + Superball Mario -> fire a superball
    jsr move_player              ; walk (updates spr_x) or scroll the camera (cam_x)
    jsr jump_player              ; A = jump (real arc); updates spr_y while airborne
    jsr goal_check               ; walked through the goal door? start the clear sequence
    jsr spawn_check              ; enemy spawn list (fires at the camera's right edge)
    jsr coin_collect             ; grab floating coins Mario walked/jumped into
    jsr update_objects           ; mushroom/coin physics + mushroom pickup
    jsr animate_player           ; pick the pose
    jsr tick_timer               ; count down the level clock
    lda respawn_req              ; fell into a pit -> restart the level (skip normal draw)
    beq @chkpipe
    jsr do_respawn
    jmp main_loop
@growing:
    dec mario_grow               ; count down the 80-frame grow (draw_player flashes on bit2)
    bne @play
    inc mario_big                ; grow complete -> big ("Super") Mario from here on
    bra @play
@chkpipe:
    jsr pipe_check              ; pipe entry/exit -> may re-render and skip the normal draw
    bcc @play
    jmp main_loop
@play:
    jmp main_loop                ; scrolling is applied at the next frame start (scroll_apply)
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

; read_map_tile: A = map_base[feet_col][mrow] (the raw tile), or $00 if the row
; is off-map. During the x-3 ending, columns PAST the level's right edge read
; as the rescue-room template (checker bands + blank) -- the transition is the
; engine's own camera scroll streaming those virtual columns in (GB $22/$23).
.proc read_map_tile
    lda mrow
    cmp #16
    bcc :+
    jmp @off
:
    lda feet_col+1               ; past the level's right edge? open space -- the goal door
    cmp lvl_cols+1            ; leads off the map (the walk-through would otherwise read
    bcc :+                       ; garbage past the level data and block Mario)
    bne @off
    lda feet_col
    cmp lvl_cols
    bcs @off
:
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
    ; --- used-tile transform (surface AND rooms): bonked ?-block -> used block, broken brick
    ;     -> blank, collected coin -> blank. Tile-specific, so a coin/brick mark never turns an
    ;     unrelated tile solid (lets the mod bitmap be shared without corruption). ---
    pha
    jsr mod_test                 ; A = mod bit for (feet_col, mrow); clobbers map_ptr/tmpL/X
    bne @mod
    pla
    cmp #$80                     ; unmodified ?-block: if it's the ACTIVE multi-coin block,
    beq @mcchk                   ; it draws (and collides) as a brick ($82) after its 1st bonk
    cmp #$81
    beq @mcchk
    cmp #$5F                     ; a HIDDEN cell hosting the LIVE multi-coin also reads
    bne @ret                     ; as the brick once registered (1-3 col 193)
@mcchk:
    pha
    lda mc_colh
    cmp feet_col+1               ; ($FF sentinel never matches a real col-hi)
    bne @nomc
    lda mc_coll
    cmp feet_col
    bne @nomc
    lda mc_row
    cmp mrow
    bne @nomc
    pla
    lda #$82                     ; the live multi-coin block looks like a brick
    rts
@nomc:
    pla
@ret:
    rts
@mod:
    pla                          ; recover the raw tile
    cmp #$82
    beq @broke                   ; broken brick -> blank
    cmp #$F4
    beq @broke                   ; collected coin -> blank
    cmp #$EC
    beq @broke                   ; opened rope (the x-3 ending) -> blank
    cmp #$5F                     ; bonked hidden block -> used block (now solid)
    beq @used
    cmp #$80                     ; only $80/$81 ?-blocks become the used block; anything else
    bcc @keep                    ; (a mod bit that bled onto a blank/wall/coin-row tile in a
@used:
    lda #$7F                     ; room) is left RAW, so it can never turn into a solid block
@keep:
    rts
@broke:
    lda #$2C
    rts
@off:
    lda ending13                 ; the virtual room right of the map
    beq @off0
    lda mrow
    cmp #2
    bcc @ckA                     ; world rows 0-1: the top checker band
    cmp #13
    bcs :+
    lda #$2C                     ; rows 2-12: open SKY (tile 0 is the '0' glyph!)
    rts
:   lda mrow                     ; rows 13+: the floor band (opposite parity)
    ina
    bra @ck
@ckA:
    lda mrow
@ck:
    clc
    adc feet_col
    and #1
    clc
    adc #$8E
    rts
@off0:
    lda #$2C                     ; blank SKY: this can pre-stream into the fb margin
    rts                          ; near the level end (a room visit rebases the fb
.endproc                         ; lattice) -- tile 0 drew as literal '0' glyphs

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
    lda room_mode                ; room cells key at +640 (their own 40-byte tail)
    beq :+
    lda map_ptr                  ; col < 20 -> col*2+bit < 64: +$80 never carries
    ora #$80
    sta map_ptr
    inc map_ptr+1
    inc map_ptr+1
:   lda map_ptr
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

; hit_qblock: head-bonk reaction for a ?-block at (feet_col, mrow). Dispatch by the block-
; contents table (the tile value $80/$81 does NOT decide the contents — Call_000_2321):
;   $28 power-up (mushroom, or flower if big), $2a 1-up heart, $2c star, $c0 multi-coin,
;   unlisted -> a single coin. One-shot blocks are marked used + redrawn; the multi-coin
;   block stays live (drawn as a brick $82) for a hard 255-frame window from the FIRST bonk,
;   coins per bonk, then converts to used on the first bonk after expiry (RE: Jump_000_1888).
.proc hit_qblock
    jsr find_block               ; multi-coin? register the cell FIRST, so the hop below
    bcc @reg_done                ; already shows the brick ($82) even on the very first bonk
    cmp #$c0
    bne @reg_done
    lda mc_colh
    cmp #$FF
    bne @reg_done                ; already the registered one
    lda feet_col
    sta mc_coll
    lda feet_col+1
    sta mc_colh
    lda mrow
    sta mc_row
    lda #$FF                     ; hard 255-frame window from this first bonk ($c0ce)
    sta mc_tmr
@reg_done:
    jsr read_map_tile            ; pre-bonk display tile ($80/$81; $82 for a multi-coin)
    cmp #$5F                     ; a hidden block materializes: it hops as the block
    bne :+                       ; it becomes, not as its (blank) map tile
    lda #$7F
:   jsr spawn_bounce             ; the block hops as a sprite while the outcome resolves
    jsr bonk_kill_above          ; the hop kills whoever stands on the block
    jsr find_block               ; C=1,A=value if this block is in the contents table
    bcc @coin                    ; UNLISTED visible ?-block = a single coin (the
    cmp #$c0                     ; long-standing, user-verified W1 behavior --
    beq @multicoin               ; hidden $5F cells with no content stay inert via
    cmp #$F0                     ; the ceiling @hidden path, which never gets here)
    beq @gift                    ; $F0 = the RISING LIFT (2-1/2-2 passages): the W2
    pha                          ; overlay's gift handler spawns it -- the same
                                 ; mechanic as 1-3's $07 hidden secret
    jsr mark_used                ; one-shot block -> used ($7F) + redraw
    pla
    cmp #$28                     ; $28 = power-up block
    beq @powerup
    cmp #$2a                     ; $2a = 1-up heart
    beq @heart
    cmp #$2c                     ; $2c = star
    beq @star
    cmp #$07                     ; $07 = the 1-3 hidden-block secret (GB object $13:
    beq @gift                    ; emerges, sits; stomp -> floats off with a thump)
    bra @coinspawn               ; unknown listed value -> coin (defensive)
@powerup:                        ; SML size rule: big Mario gets a Superball Flower, small a Mushroom
    lda mario_big
    bne @flower
    lda #OBJ_MUSH
    jsr spawn_walker
    rts
@flower:
    jmp spawn_flower
@heart:
    lda #OBJ_HEART               ; walks exactly like the mushroom (types $2A/$2B == $28/$29)
    jsr spawn_walker
    rts
@star:
    jmp spawn_star
@gift:
    jmp (ovl_vec+6)
@coin:
    jsr mark_used
@coinspawn:
    jsr spawn_coin               ; coin-pop animation
    jmp award_coin               ; +1 coin, +100 score, 1-up at 100
@multicoin:
    lda mc_tmr                   ; window open (incl. the first bonk) -> another coin
    beq @mc_conv
    jsr redraw_cell              ; cell shows the brick look ($82 via the mc registration)
    bra @coinspawn
@mc_conv:
    jsr mark_used                ; expired: final coin + convert to a used block
    lda #$FF
    sta mc_colh
    bra @coinspawn
.endproc

; mark_used: set the (feet_col,mrow) mod bit and redraw the cell (-> $7F used / blank).
.proc mark_used
    jsr mod_set
.endproc                         ; fall through
.proc redraw_cell
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one
    rts
.endproc

; find_block: search the contents table for (feet_col, mrow). Returns C=1 + A=value if listed,
; else C=0. (Unlisted ?-blocks hold a single coin.)
.proc lvl_ws                     ; cur_level -> X = world digit, A = stage digit
    lda cur_level
    ldx #1
:   cmp #3
    bcc :+
    sbc #3                       ; (carry set by the cmp)
    inx
    bra :-
:   ina
    rts
.endproc

.proc find_block
    lda feet_col                 ; room contents are namespaced: key = 512 +
    sta blk_key                  ; room*32 + local col (extractor writes the same;
    lda feet_col+1               ; surface cols never reach 512 -- 2-1's hidden
    sta blk_key+1                ; room power-ups read as coins before this)
    lda room_mode
    beq @go
    lda pipe_room
    asl
    asl
    asl
    asl
    asl                          ; pipe_room <= 3: the asl chain shifts out zeros,
    adc feet_col                 ; so C is clear here (no clc -- FIXED is at 0 free)
    sta blk_key
    lda #2
    sta blk_key+1
@go:
    ldx #0
@loop:
    lda block_tab,x
    cmp blk_key
    bne @next
    lda block_tab+1,x
    cmp blk_key+1
    bne @next
    lda block_tab+2,x
    cmp mrow
    bne @next
    lda block_tab+3,x
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
    lda #SFX_DFE0_05             ; the coin sound -- VERIFIED: bonking a coin ?-block at
    jsr sfx_play                 ; camera 0 fires seq $6809 = the $dfe0=$05 handler
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

; coin_collect: grab any floating $f4 coin Mario overlaps (his centre column at his two body
; rows). A collected coin is marked in the mod bitmap (read_map_tile then transforms $f4 ->
; blank), blanked on-screen, and awarded. Runs every frame, surface and rooms.
.proc coin_collect
    lda spr_y                    ; body top row (same convention as wall_ahead)
    lsr
    lsr
    lsr
    sec
    sbc #2
    sta mrow
    jsr try_coin
    inc mrow                     ; body bottom row
    jsr try_coin
    rts
.endproc

.proc try_coin                   ; caller sets mrow; tests Mario's centre column at that row
    lda #7
    jsr calc_feet_col            ; feet_col = (cam_x + spr_x + 7) >> 3
    jsr read_map_tile
    cmp #$F4
    bne @no
    jsr mod_test                 ; already collected this cell?
    bne @no
    jsr mod_set                  ; mark it -> read_map_tile now transforms this cell to blank
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one               ; blank the coin cell on screen
    jsr award_coin               ; +1 coin, +100, 1-up at 100
@no:
    rts
.endproc

; add_life / lose_life: BCD lives counter, clamped to [0,99]. Lives only grow on a 1-up
; (100 coins, or a heart power-up once the object engine lands) — never on a plain ?-block.
.proc add_life_snd
    lda #SFX_DFE0_08             ; 1UP trigger ($dfe0=$08, RE $1C33)
    jsr sfx_play
    ; falls through into add_life
.endproc
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
    lda #SFX_DFF8_02             ; the shards smash (user-ID'd: noise effect)
    jsr sfx_play
    jsr mod_set
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one               ; redraw as blank
    jsr spawn_debris4            ; burst into 4 shards (2 arcs x 2 directions)
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
tile:
    cmp #$F4                     ; coins are walk-through (collectible), not floor
    beq no
    cmp #$60                     ; tiles >= $60 are solid floor
    bcc no
    lda #1
    rts
no:
    lda #0
    rts
.endproc
.proc wall_solid                 ; body/wall variant: $F4 coin and the $F5+ one-way
    jsr read_map_tile            ; caps (GB $1A93: the wall check passes them too)
    cmp #$F4                     ; are NEVER walls; everything else as read_solid
    bcc read_solid::tile
    bra read_solid::no
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
    lda mario_big                ; SMALL Mario is a 12px box: an overhang at his head row
    beq @low                     ; doesn't block him (original: he walks under 1-gap ledges)
    jsr wall_solid
    bne @yes
@low:
    inc mrow                     ; body bottom row
    jsr wall_solid
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
    lda ride                      ; riding a platform? supported while still x-over it
    beq @tilesup
    jsr ride_support
    beq @unsup                    ; slipped off the platform's edge -> fall
    jmp @done
@tilesup:
    lda spr_y                     ; still supported? test the tile under the feet
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid                ; centre probe (feet_col set at entry, +8)
    bne @sup
    lda #6                        ; foot probes +6/+8. GB-measured truth (docs/12)
    jsr calc_feet_col             ; is probes ~+2/+3 with a NARROWER wall test --
    jsr read_solid                ; adopting that needs the full body-geometry
    bne @sup                      ; harmonization (128K era). +6/+8 reproduces
    lda #8                        ; every observed GB outcome with OUR wall spans:
    ldy h_idx                     ; GB $17EC (RUN RULE, user-caught): at full run
    cpy #4                        ; (c20e==4, grounded) the GB widens the second
    bne :+                        ; support probe by +4px -- an 8px probe spread
    lda #14                       ; never fits in a 1-block hole, so RUNNING
:   jsr calc_feet_col             ; BRIDGES them while walking falls in
    jsr read_solid                ; (probes: +6/+8 walking, +6/+14 running)
    beq @unsup                    ; hangs deviate (10/8 vs GB 15/3) -- known
@sup:
    jmp @done                     ; supported -> stay grounded
@unsup:
    lda #2                        ; walked off a ledge -> free-fall
    sta jump_state
    lda #1
    sta fall_v
    jmp @done
@startjump:
    lda #SFX_DFE0_01             ; the original's jump sound ($dfe0=$01, live-verified)
    jsr sfx_play
    stz ride                      ; jumping leaves the platform
    lda #2                        ; seed the arc index at 2 (matches the game)
    sta arc_idx
    lda #1
    sta jump_state
    stz fall_v
    jmp @done
@ascend:
    lda pad_held                  ; VARIABLE JUMP (harness-measured vs the original: releasing
    and #GB_A                     ; A leaves only the deceleration tail of the ascent -- each
    bne :+                        ; 2 held frames ~ +4px, saturating at the full 33px)
    lda arc_idx
    cmp #JREL_IDX
    bcs :+
    lda #JREL_IDX
    sta arc_idx
:   ldx arc_idx
    lda jumparc,x
    cmp #$7F                      ; apex marker -> start descending
    bne :+
    jmp @apex
:
    sta tmpL
    lda spr_y
    sec
    sbc tmpL
    bcs :+                        ; NO ceiling at the HUD (original: Mario rises behind it);
    lda #0                        ; clamp only at 0 so spr_y can't wrap
:   sta tmpH                      ; tentative new spr_y -> head-bonk test first
    lsr
    lsr
    lsr
    sec
    sbc #2                        ; head row = (new spr_y >> 3) - 2 (tile at his head)
    sta mrow
    jsr read_map_tile             ; effective tile above his head (centre column)
    cmp #$5F                      ; $5F = INVISIBLE block (see @hidden below)
    beq @hidden
    cmp #$60
    bcc @noceil                   ; < $60 -> not solid -> keep rising
    cmp #$F4
    bcs @noceil                   ; $F4 coin walk-through; $F5+ = ONE-WAY platform
                                  ; caps (GB $1A93 list, remapped by the extractor):
                                  ; jump up through them freely
    cmp #$80                      ; $80/$81 = ?-block (content decided by the block table)
    beq @qblock
    cmp #$81
    beq @qblock
    cmp #$82                      ; $82 = breakable brick
    beq @brick
@thud:
    lda #SFX_DFE0_07              ; plain solid/used block: the THUD -- VERIFIED twice:
    jsr sfx_play                  ; used-block bonks fire seq $68A0 = the $dfe0=$07 handler
    bra @bonk
@qblock:
    jsr hit_qblock                ; spawn coin or mushroom per the content table
    bra @bonk
@brick:
    lda mc_colh                   ; the LIVE multi-coin block reads as $82 -> re-bonk = more
    cmp feet_col+1                ; coins (content check precedes brick-break in the original,
    bne @realbrick                ; so big Mario cannot break it)
    lda mc_coll
    cmp feet_col
    bne @realbrick
    lda mc_row
    cmp mrow
    bne @realbrick
    bra @qblock
@realbrick:
    jsr bonk_kill_above           ; brick hop/break kills whoever stands on it
    lda mario_big                 ; small Mario can't break bricks -> the brick just hops
    bne @smash
    lda #$82
    jsr spawn_bounce
    bra @thud                     ; small Mario bonking a brick: the same thud
@smash:
    jsr break_brick               ; big Mario smashes it
@bonk:
    lda #2                        ; bonk: stop rising, start falling
    sta jump_state
    lda #1
    sta fall_v
    jmp @done
@hidden:
    jsr find_block                ; hidden blocks bonk ONLY when the contents table
    bcs @qblock                   ; lists them (GB $187b: content 0 -> plain ret, the
    bra @noceil                   ; cell is fully inert; 1-2 col 215 is such a marker)
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
    jsr mus_stop                  ; the jingle REPLACES the music ($dfe9 switches)
    lda #SFX_DFE8_02              ; the death jingle plays on pit deaths too
    jsr sfx_play
    lda #1
    sta respawn_req
    rts
@checkland:
    jsr plat_land                 ; crossed a moving platform's top? land + ride it
    bne @done
    lda spr_y                     ; landed? test the tile the feet are entering
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid                ; centre...
    bne @snap
    lda #6                        ; ...then both feet (+6/+8, matching the walk
    jsr calc_feet_col             ; support probe)
    jsr read_solid
    bne @snap
    lda #8
    jsr calc_feet_col
    jsr read_solid
    beq @done                     ; no ground -> keep falling
@snap:
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
    lda #144                     ; trace: 144-frame death pause (music) before anything
    sta tmpL3
:   lda frame_flag
    beq :-
    stz frame_flag
    jsr sfx_tick                 ; the death jingle keeps playing through the pause
    jsr mus_tick                 ; (self-gated: music is stopped here, but stay uniform)
    dec tmpL3
    bne :-
    lda lives                    ; dying with no spare lives -> GAME OVER
    bne :+
    jmp game_over
:   jsr lose_life                ; dying costs a spare life
    stz room_mode                ; always restart on the surface
    stz pipe_tab+1               ; death RE-ARMS used pipes (user-verified on GB);
    stz pipe_tab+6               ; all current pipe cols have hi=0 -- revisit if a
    stz pipe_tab+11              ; W2+ level ever puts a pipe past col 255
    lda cam_x
    sta cam_dead
    lda cam_x+1
    sta cam_dead+1
    lda surf_map
    sta map_base
    lda surf_map+1
    sta map_base+1
    ; --- respawn checkpoint, the ORIGINAL'S algorithm (State_02 @ $06E2): take the death
    ; segment counter, step ONE segment back (unless at the start), then quantize to the
    ; fixed checkpoints at static segs 3/7/11/15/19 (= port camera 0/640/1280/1920/2240).
    lsr cam_dead+1               ; death column = cam/8
    ror cam_dead
    lsr cam_dead+1
    ror cam_dead
    lsr cam_dead+1
    ror cam_dead
    lda cam_dead                 ; right-edge column = col + 20
    clc
    adc #20
    sta cam_dead
    bcc :+
    inc cam_dead+1
:   ldx #3                       ; seg = 3 + (right edge)/20
@div:
    lda cam_dead+1
    bne @sub20
    lda cam_dead
    cmp #20
    bcc @seg
@sub20:
    sec
    lda cam_dead
    sbc #20
    sta cam_dead
    lda cam_dead+1
    sbc #0
    sta cam_dead+1
    inx
    bra @div
@seg:
    cpx #3                       ; not at the very start? one segment back (the generous rule)
    beq :+
    dex
:   stz cam_x
    stz cam_x+1
    cpx #7                       ; quantize (cab = 12 + cam/16, trace-calibrated: checkpoint
    bcc @have                    ; cam = (C-12)*16): <7 -> 0
    ldy #<640
    sty cam_x
    ldy #>640
    sty cam_x+1
    cpx #11                      ; <11 -> 640
    bcc @have
    ldy #<1280
    sty cam_x
    ldy #>1280
    sty cam_x+1
    cpx #15                      ; <15 -> 1280
    bcc @have
    ldy #<1920                   ; else 1920 (seg 15+; later checkpoints past 1-1's range)
    sty cam_x
    ldy #>1920
    sty cam_x+1
@have:
    lda cam_x                    ; fb_col0 = cam/8
    sta fb_col0
    lda cam_x+1
    sta fb_col0+1
    lsr fb_col0+1
    ror fb_col0
    lsr fb_col0+1
    ror fb_col0
    lsr fb_col0+1
    ror fb_col0
    stz spawn_idx                ; fast-forward the spawn list to the checkpoint (else all
@sff:                            ; earlier entries would fire at once on the first frame)
    lda spawn_idx
    asl
    asl
    clc
    adc spawn_idx                ; entry offset = idx*5 (list <= 51 entries)
    tay
    lda spawn_tab+1,y
    cmp #$FF
    beq @sffd
    cmp cam_x+1
    bcc @sfn
    bne @sffd
    lda spawn_tab,y
    cmp cam_x
    bcs @sffd
@sfn:
    inc spawn_idx
    bra @sff
@sffd:
    stz scroll_s
    stz prev_scroll_s
    stz scroll_vis
    stz XSCROLL
    stz jump_state
    stz fall_v
    stz arc_idx
    stz h_idx
    stz h_toggle
    stz skid_t                   ; no brake/momentum state survives a respawn
    stz move_t
    stz mdir
    stz walk_t
    stz walk_i
    stz mario_facing
    stz mario_frame
    stz prev_frame
    stz mario_big                 ; death -> back to small Mario
    stz mario_duck
    stz mario_grow                ; cancel any in-progress grow
    stz mario_superball           ; lose the superball ability
    stz mario_starT               ; cancel invincibility
    stz star_flash
    stz mc_tmr                    ; reset the multi-coin block (level restarts fresh)
    lda #$FF
    sta mc_colh
    stz mario_shrink
    stz hurt_inv
    ; (spawn_idx was already fast-forwarded to the checkpoint above -- do NOT reset it)
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
    lda #3                       ; 64Hz driver (GB: TMA=0 at level init)
    sta mus_rate
    jsr lvl_music                ; per-level tune (GB table $07CE)
    rts
.endproc

; ---------------------------------------------------------------------------
; Level-clear (goal) sequence. Trace-exact vs the original (tools/trace_goal.lua):
; Mario walks fully through the door (screen x = 160) -> 240-frame jingle freeze
; (st=$07) -> 64-frame hold (st=$05 entry, $ffa6=$40) -> TALLY: TIME -1/frame with
; +10 score each, to 000 -> 43-frame hold (st=$06+$08) -> next level, clock 400.
.proc goal_check
    lda goal_phase
    bne @no
    lda cam_x+1                  ; only possible with the camera at its max (the level end)
    cmp cam_max+1
    bne @no
    lda cam_x
    cmp cam_max
    bne @no
    lda jump_state               ; only from the ground (jumping into the arch waits for landing)
    bne @no
    lda spr_x
    cmp #144                     ; TRIGGER: fully in the arch. The dedicated door trace proves
    bcc @no                      ; FULL control (even running) until this point, then an
    lda #1                       ; instant freeze -- no auto-walk, no early lock.
    sta goal_phase
    lda #240
    sta goal_tmr
    stz goal_top
    stz mario_frame              ; he stands in the arch for the whole sequence
    stz mario_duck
    stz ride                     ; (a platform carry must not drag him out of the arch)
    lda #3                       ; 64Hz driver (GB: TMA=0 in the goal path)
    sta mus_rate
    lda spr_y                    ; top exit (door at rows 0-1) vs bottom (rows 13-14)
    cmp #64
    bcs :+
    inc goal_top
:   jsr mus_stop                 ; BOTH doors: the course-clear jingle = TRACK $01
    lda #MUS_GOAL                ; ($1B70; the [$d007] branch that skips it is NOT the
    jsr mus_start                ; door -- $d007 == 0 all through 1-1, harness-verified;
                                 ; user-confirmed: same jingle at both doors)
@no:
    rts                          ; (objects stay LIVE through the sequence -- the original's
.endproc                         ;  platforms keep patrolling during the jingle/tally)

.proc goal_seq
    lda goal_phase
    cmp #1
    beq @jingle
    cmp #2
    beq @hold
    cmp #3
    beq @tally
    cmp #5
    bne :+
    jmp l3e_seq                  ; goal_phase 5 = the x-3 rescue ending machine
:   dec goal_tmr                 ; phase 4: end hold -> next level (or the bonus game)
    bne @done
    lda ending13                 ; sphere clear: the rope/wipe/rescue flow follows
    beq :+
    lda #5
    sta goal_phase
    lda #1                       ; E_BEAT1
    sta e_phase
    lda #71                      ; GB states $1C+$1D
    sta e_tmr
    ldx #9                       ; GB $1C+: the object engine stops for the ending.
@oclr:                           ; update_objects keeps running here (line ~446), so
    stz o_type,x                 ; live leftovers (stones, popups) GHOST-DRAW during
    dex                          ; the 224px scroll -- their offscreen test wraps at
    bpl @oclr                    ; 256px (user-caught: figures + glyph trails)
    rts
:   lda goal_top                 ; top door -> the ladder bonus game first
    beq @next
    jmp enter_bonus
@next:
    jmp next_level
@jingle:
    dec goal_tmr                 ; the "course clear" jingle pause
    bne @done
    lda #2
    sta goal_phase
    lda #64
    sta goal_tmr
@done:
    rts
@hold:
    dec goal_tmr
    bne @done
    lda #3
    sta goal_phase
    lda ending13                 ; GB: at the TALLY start every live enemy (the boss,
    beq @done                    ; in-flight fire) bursts into the $9D/$9E cloud with
    jmp l3e_boom                 ; the bang ($dff8=$01) -- captured OAM, docs/25
@done2:
    rts
@tally:
    lda timer                    ; TIME == 000? tally over
    ora timer+1
    beq @tdone
    sed                          ; TIME -= 1 (BCD; timer+1 = hundreds)
    lda timer
    sec
    sbc #1
    sta timer
    lda timer+1
    sbc #0
    sta timer+1
    cld
    lda timer                    ; the tally tick ($0CB6: dfe0=$0A when the ones bit0
    and #1                       ; is clear -- every other unit)
    bne :+
    lda #SFX_DFE0_0A
    jsr sfx_play
:   lda #$10                     ; +10 points per time unit
    ldx #$00
    jsr add_score
    lda #1
    sta hud_dirty
    rts
@tdone:
    lda #4
    sta goal_phase
    lda #43
    sta goal_tmr
    rts
.endproc

.proc enter_bonus                ; prize ring + L11 overlay pull + bonus screen
    stz goal_phase
    stz e_own
    stz e_phase
    lda frame_count              ; prize ring rotated pseudo-randomly (original: DIV&3+1
    and #3                       ;  into [00 01 02 E5 03 01 02 E5] @ $3E7B)
    tax
    ldy #0
:   lda @ring+1,x
    sta b_prz,y
    inx
    iny
    cpy #4
    bne :-
    jsr bonus_enter_copy         ; map bank 1 + pull the bonus blob into RAM
    jsr bonus_start
    lda #2
    sta bonus_phase
    rts
@ring: .byte $00,$01,$02,$E5,$03,$01,$02,$E5
.endproc

; ===========================================================================
; THE x-3 RESCUE ENDING (docs/25; every timing/tile GB-captured).
; goal_phase 5; e_phase walks the sub-states. Phases 1-4 run over the live
; arena (normal rendering). From the WIPE on, e_own=1: the machine owns the
; frame like the bonus does, and the screen is REPLACED column-by-column with
; the rescue room (checker bands rows 2-3 + 15-17, blank middle).
; ===========================================================================
E_BEAT1   = 1                    ; 71f  (GB $1C 7f + $1D 64f)
E_ROPE    = 2                    ; 4 rope tiles bottom-up, one per 8f, SFX $0B
E_BEAT2   = 3                    ; 47f  (GB $20)
E_WALKOUT = 4                    ; Mario auto-walks right to the edge (GB $21)
E_WIPE    = 5                    ; first room-machine phase (the scroll ends here)
E_WALKIN  = 5                    ; Mario re-enters 8->68 @1px/f; text types with him
E_TEXT1   = 6                    ; "THANK YOU MARIO." 1 char/16f (GB $24)
E_TEXT2   = 7                    ; "OH! DAISY" (GB $24 tail/$25)
E_JINGLE  = 8                    ; MUS_REVEAL + 64f (GB $25, track $12)
E_PUFF    = 9                    ; 3 thumps 16f apart, then the sprite swap
E_FLY     = 10                   ; moth rest/hop arcs rightward until off-screen
E_OUT     = 11                   ; short hold, then the bonus game

CAPT_X    = 80                   ; the captive/moth home (screen px; film-measured)
CAPT_Y    = 104
MARIO_INX = 60                   ; Mario's walk-in stop (GB 61; he must not
                                 ; overlap the captive at 80 or his erase eats her)

.proc l3e_seq
    lda e_phase
    cmp #E_WIPE
    bcc :+
    jmp l3e_room                 ; the room machine owns everything from here
:   cmp #E_ROPE
    bne :+
    jmp @rope
:   cmp #E_WALKOUT
    bne @beat                    ; phases 1/3 = the beats; 4 falls through = the scroll
    ; --- E_SCROLL (id E_WALKOUT): the camera itself rolls 224px right at 1px/f;
    ; the engine streams the room template in (read_map_tile's past-edge branch)
    ; while Mario keeps walking, drifting to his mark. GB $22/$23 exactly. ---
    jsr l3e_walkanim
    lda #8                       ; REAL ground probe (user: respect gravity!):
    jsr calc_feet_col            ; the template floor comes through read_map_tile,
    lda spr_y                    ; so collision works across pedestal, wall and
    clc                          ; room floor alike -- fall 2px/f when the tile
    adc #16                      ; under his feet is not solid
    lsr
    lsr
    lsr
    sec
    sbc #2                       ; screen row -> world row
    sta mrow
    jsr read_solid
    bne @grounded
    inc spr_y
    inc spr_y
@grounded:
    lda frame_count
    and #1
    bne :+
    lda spr_x                    ; drift left to his mark (GB: he ends at 61 with
    cmp #MARIO_INX+1             ; the captive at 79), then walks in place
    bcc :+
    dec spr_x
:   lda e_tmr                    ; cam steps only while e_tmr>=3 (224 steps);
    cmp #3                       ; the two settle frames let scroll_apply run
    bcc @nocam                   ; the final 32px shift before e_own skips it
    inc cam_x
    bne :+
    inc cam_x+1
:   lda e_tmr                    ; the captive: drawn ONCE when her columns have
    cmp e_cap                    ; streamed (cam=2240+227+D-e_tmr -> 2392 at 75+D;
    bne @nocam                   ; deterministic, and cheaper than the old
    jsr l3e_captive_scroll       ; 16-bit compare -- pays for the settle gate)
@nocam:
    dec e_tmr
    bne @rts
    jsr l3e_room_copy            ; pull the room machine over the dead kit
    lda #1
    sta e_own
    lda #E_WALKIN
    sta e_phase
    stz e_ix                     ; text index
    lda #16
    sta e_tmr
    rts
@beat:
    dec e_tmr
    bne @rts
    lda e_phase
    cmp #E_BEAT1
    bne @towalk
    lda #E_ROPE                  ; beat 1 done -> the rope opens
    sta e_phase
    stz e_ix
    lda #1
    sta e_tmr
@rts:
    rts
@towalk:
    lda #E_WALKOUT               ; beat 2 done -> the transition SCROLL (GB $22/$23)
    sta e_phase
    lda #32                      ; LATTICE NORMALIZATION (user-caught: a mid-level
    sec                          ; ROOM VISIT re-renders the fb at the pipe resume
    sbc scroll_s                 ; col, rebasing the 4-col shift lattice; the pinned
    and #31                      ; arena offset is then 8/16/24 instead of 32, and a
    sta e_cap                    ; fixed 224px scroll CANNOT end at s=0). Extend the
    clc                          ; walk by (32-s)&31 px so it always lands s=0.
    adc #226                     ; 224+D cam steps + TWO settle frames: scroll_apply
    sta e_tmr                    ; must PROCESS the final cam before e_own starts
    lda e_cap                    ; skipping it (else the room sits shifted).
    clc                          ; captive trigger moves with the extension:
    adc #75                      ; cam hits 2392 when e_tmr == 75 + D
    sta e_cap
    lda fbmax_col                ; let the fb advance into the virtual room
    clc
    adc #32
    sta fbmax_col
    bcc :+
    inc fbmax_col+1
:   jsr mus_stop
    lda #MUS_RESCUE              ; GB: track $0F starts as the scroll begins
    jmp mus_start
@rope:
    dec e_tmr
    bne @rts
    lda #8                       ; one tile per 8 frames (captured cadence)
    sta e_tmr
    ldx e_ix
    cpx #4
    bcs @ropedone
    jsr l3e_rope_tile
    inc e_ix
    lda #SFX_DFE0_0B             ; the rope-step chime (GB: $dfe0=$0B per tile)
    jmp sfx_play
@ropedone:
    lda #E_BEAT2
    sta e_phase
    lda #47
    sta e_tmr
    rts
.endproc

; --- the rope: world col 298, rows 11,10,9,8 bottom-up; the cell is BLANKED
; on screen and MOD-marked so any later map-driven redraw keeps it blank ---
.proc l3e_rope_tile
    lda #44                      ; deterministic: the rope opens at the PINNED end
    sta dcol                     ; (cam 2240, fb_col0 276) -> (298-276)*2 = 44
    ldx e_ix
    lda @rows,x
    sta mrow                     ; mod_set is (feet_col, mrow)-keyed
    asl
    asl
    asl
    clc
    adc #16                      ; dy = (row+2)*8
    sta dy
    lda #<298
    sta feet_col
    lda #>298
    sta feet_col+1
    jsr mod_set
    jsr set_dst
    jmp blit_blank
@rows: .byte 9, 8, 7, 6         ; WORLD rows (the captured BG rows were +2)
.endproc

.proc l3e_walkanim               ; the 3-pose walk cycle while scripted
    lda frame_count
    lsr
    lsr
    and #3
    tax
    lda @cyc,x
    sta mario_frame
    stz mario_facing             ; 0 = facing right
    rts
@cyc: .byte 1, 2, 5, 2
.endproc

; l3e_captive_scroll: draw the captive ONCE into the fb at her WORLD spot
; (2544 = final screen x 80): after this the DMA shifts carry her image with
; the scrolling world, pixel-exact, with no per-frame redraws.
.proc l3e_captive_scroll
    ldy #0                       ; trigger geometry is deterministic: cam==2392,
                                 ; fb_col0=296 -> her byte col = 636-592 = 44
@q: phy
    lda quad_cols,y
    clc
    adc #44
    sta dcol
    lda quad_rows,y
    clc
    adc #CAPT_Y
    sta dy
    stz spr_subx
    lda #1
    sta do_flip
    ldx @tiles,y
    jsr draw_quad
    ply
    iny
    cpy #4
    bne @q
    stz do_flip
    rts
@tiles: .byte $49, $4E, $51, $50
.endproc
quad_cols: .byte 0, 2, 0, 2      ; shared 2x2 metasprite quadrant offsets
quad_rows: .byte 0, 0, 8, 8

; --- every live L3 enemy bursts into the explosion cloud at the tally start ---
; boom_swap: X = victim slot, tmpH3 = cloud y. Free the victim (the pipeline
; erases the DEAD object's full drawn rect, tall included) and spawn the 44f
; cloud in a FRESH slot at his spot -- morphing in place leaves any body taller
; than the cloud's erase envelope on screen (tally burst + boss kill, both
; user-caught).
.proc victim_xy                  ; tmpL2/H2 = slot X's world x
    lda o_xl,x
    sta tmpL2
    lda o_xh,x
    sta tmpH2
    rts
.endproc

.proc boom_swap
    jsr victim_xy
    stz o_type,x
    phx
    jsr find_free_evict
    bcs @none
    lda #OBJ_BOOM
    sta o_type,x
    lda tmpL2
    sta o_xl,x
    lda tmpH2
    sta o_xh,x
    lda tmpH3
    sta o_y,x
    lda #BOOM_LIFE
    sta o_tmr,x
    stz o_st,x
@none:
    plx
    rts
.endproc

.proc l3e_boom
    ldx #OBJ_MAX-1
@l: lda o_type,x
    cmp #OBJ_SUU
    bcc @next
    cmp #OBJ_GCORP+1
    bcs @next
    cmp #OBJ_BAT
    php                          ; (Z = it's the tall boss)
    lda o_y,x
    plp
    bne :+
    clc                          ; head-anchored 24px boss: center the cloud
    adc #8
:   sta tmpH3
    lda o_xl,x                   ; screen x = o_x - cam: clouds only for slots ON
    sec                          ; SCREEN -- an off-screen-left leftover drew a
    sbc cam_x                    ; half cloud at the edge (user-caught)
    sta tmpL2
    lda o_xh,x
    sbc cam_x+1
    bne @off
    lda tmpL2
    cmp #160
    bcs @off
    jsr boom_swap
    bra @next
@off:
    stz o_type,x                 ; off-screen: just free (pipeline-erased if drawn)
@next:
    dex
    bpl @l
    lda #SFX_DFF8_01             ; the bang (unconditional: silent only in the
    jmp sfx_play                 ; star-killed-boss-then-sphere edge case, where
.endproc                         ; a lone bang is a harmless 1-shot)

; ---------------- the room scenes (e_own frames) ----------------
; These live in the L13E overlay: a bank-1 blob after L11CODE, copied into the
; shared RAM window ($1500) at the wipe -- the L3CODE kit is retired by then.
.segment "L13E"
.proc l3e_room
    lda e_phase
    sec
    sbc #E_WIPE
    asl
    tax
    lda @tab+1,x
    pha
    lda @tab,x
    pha
    rts                          ; rts-dispatch
@tab:
    .word @walkin-1, @text1-1, @text2-1
    .word @jingle-1, @puff-1, l3e_fly-1, @out-1
@out:
    ; --- E_OUT ---
    dec e_tmr
    bne @rts
    stz ending13
    jmp enter_bonus
@rts:
    rts
@walkin:
    jsr l3e_walkanim
    inc spr_x
    lda spr_x
    cmp #MARIO_INX
    bcc :+
    stz mario_frame              ; arrived: stand
:   jsr l3e_mario_draw
    jsr l3e_type1                ; the text types while he walks (GB $24)
    lda spr_x
    cmp #MARIO_INX
    bcc @rts
    lda #E_TEXT1
    sta e_phase
    rts
@text1:
    jsr l3e_type1
    lda e_ix
    cmp #16
    bcc @rts
    lda #E_TEXT2
    sta e_phase
    stz e_ix
    lda #16
    sta e_tmr
    rts
@text2:
    dec e_tmr
    bne @rts
    lda #16
    sta e_tmr
    ldx e_ix
    cpx #9
    bcs @t2done
    lda l3e_txt2,x
    ldy #9                       ; row 9 (dy 72), start col 4 (film-measured)
    jsr l3e_char
    inc e_ix
    rts
@t2done:
    lda #E_JINGLE
    sta e_phase
    lda #64
    sta e_tmr
    jsr mus_stop
    lda #MUS_REVEAL              ; GB $25: track $12
    jmp mus_start
@jingle:
    dec e_tmr
    bne @rts2
    lda #E_PUFF
    sta e_phase
    stz e_ix
@rts2:
    rts
@puff:
    inc e_ix                     ; the TRANSFORM SWIRL (captured $25 tail): a
    lda e_ix                     ; 16x16 four-quadrant spin of tiles $06/$07
    cmp #60                      ; alternating every 8f for ~60f, three thumps
    bcs @pdone                   ; inside it, THEN the moth
    and #7
    bne @rts2
    lda e_ix
    cmp #8
    beq @thump
    cmp #24
    beq @thump
    cmp #40
    bne :+
@thump:
    lda #SFX_DFF8_03
    jsr sfx_play
:   jmp l3e_swirl
@pdone:
    jsr l3e_moth_blank_at_capt   ; clear the last swirl frame
    lda #CAPT_X                  ; ...and the moth takes her place
    sta e_mx
    sta e_px
    lda #CAPT_Y
    sta e_my
    sta e_py
    lda #E_FLY
    sta e_phase
    stz e_hop
    lda #56                      ; first rest (captured)
    sta e_tmr
    jsr l3e_moth_draw
    rts
.endproc

; --- E_FLY: rest 40f, then a 56f parabolic hop (+2px/2f right, y arc), repeat
; until the moth leaves the right edge (captured arc; docs/25) ---
.proc l3e_fly
    lda e_hop
    bne @hopping
    dec e_tmr                    ; resting
    bne @rts
    lda #1
    sta e_hop                    ; start a hop: 7 segments x 8f
    lda #8
    sta e_tmr
    stz e_ix
@rts:
    rts
@hopping:
    ldx e_ix
    lda l3e_arc,x                ; per-frame y delta for this 8f segment
    clc
    adc e_my
    sta e_my
    lda frame_count              ; +1px right every other frame (~25px/hop)
    and #1
    bne :+
    inc e_mx
:   jsr l3e_moth_draw
    dec e_tmr
    bne @rts
    lda #8
    sta e_tmr
    inc e_ix
    lda e_ix
    cmp #7
    bcc @rts
    stz e_hop                    ; landed: rest again (the arc's per-frame deltas
    lda #40                      ; sum to exactly 0 over 7x8 frames -- no snap
    sta e_tmr
    stz e_ix
    jsr l3e_moth_draw
    lda e_mx
    cmp #160                     ; off the right edge: hold, then the bonus game
    bcc @rts
    jsr l3e_moth_blank
    lda #E_OUT
    sta e_phase
    lda #60
    sta e_tmr
    rts
.endproc

.proc l3e_text2_fix              ; repaint the full text2 line + Mario's image
    ldx #0
@c: phx
    lda l3e_txt2,x
    ldy #9
    jsr l3e_char
    plx
    inx
    cpx #9
    bne @c
    lda spr_x
    sta mario_vx
    jmp draw_player
.endproc

l3e_arc: .byte <-2, <-2, <-1, 0, 1, 2, 2   ; 8f-segment per-frame y deltas (sum 0)
l3e_txt1: .byte $1D,$11,$0A,$17,$14,$2C,$22,$18,$1E,$2C,$16,$0A,$1B,$12,$18,$23
l3e_txt2: .byte $18,$11,$28,$2C,$0D,$0A,$12,$1C,$22
.proc l3e_type1
    dec e_tmr
    bne @rts
    lda #16
    sta e_tmr
    ldx e_ix
    cpx #16
    bcs @rts
    lda l3e_txt1,x
    ldy #5                       ; row 5 (dy 40), start col 1
    jsr l3e_char
    inc e_ix
@rts:
    rts
.endproc

.proc l3e_char                   ; A = tile, Y = row, X = char index; col base per
    pha                          ; row. Room drawing is s=0 by design (the scroll
    tya                          ; ends 0 mod 32) -- no anchoring needed.
    asl
    asl
    asl
    sta dy
    cpy #9
    beq @r9
    txa                          ; row 5: col 1 + i  -> dcol = 2 + i*2
    asl
    clc
    adc #2
    bra @setc
@r9:
    txa                          ; row 9: col 4 + i
    asl
    clc
    adc #8
@setc:
    sta dcol
    pla
    jsr get_tile_src
    jsr set_dst
    jmp blit_tile
.endproc

; --- the transform swirl: 4-quadrant 16x16 (tile $06 or $07 by phase) ---
.proc l3e_swirl
    jsr l3e_moth_blank_at_capt   ; wipe the previous swirl/captive image
    lda e_ix
    lsr
    lsr
    lsr
    and #1
    clc
    adc #6                       ; tile $06 / $07
    sta tmpH3
    stz spr_subx
    ldy #0
@q: phy
    lda quad_cols,y
    clc
    adc #CAPT_X/4
    sta dcol
    lda quad_rows,y
    clc
    adc #CAPT_Y
    sta dy
    lda @flips,y
    sta do_flip
    ldx tmpH3
    tya
    and #2                       ; bottom quadrants blit bottom-up (y-mirror)
    bne @yf
    jsr draw_quad
    bra @nx
@yf:
    jsr draw_tile_yflip
@nx:
    ply
    iny
    cpy #4
    bne @q
    stz do_flip
    rts
@flips: .byte 0, 1, 0, 1
.endproc

.proc l3e_moth_blank_at_capt     ; 2-row blank box at the captive/swirl home
    lda #CAPT_X/4
    sta dcol
    lda #CAPT_Y
    sta dy
    ldx #2
    jmp l3e_box
.endproc


.segment "CODE"                  ; generic helpers: FIXED has slack, the overlay
                                 ; window is the tight one
.proc l3e_box                    ; blank an X-row x 3-cell box at (dcol, dy).
@row:                            ; (No stride clip: post-de-anchor the callers'
    ldy #3                       ; dcol tops out at 46.)
@col:
    phx
    phy
    jsr set_dst
    jsr blit_blank
    ply
    plx
    lda dcol
    clc
    adc #2
    sta dcol
    dey
    bne @col
    lda dcol
    sec
    sbc #6
    sta dcol
    lda dy
    clc
    adc #8
    sta dy
    dex
    bne @row
    rts
.endproc
.segment "L13E"

; the rescue scene's own OBJ overlay tiles (GB loads them at $8A00 during the
; ending; the W1 sheet has different graphics at those indices): the MOTH.
moth_tiles: .incbin "../build/gfx/moth.svt"
.proc l3e_mothtile               ; X = moth sheet index (0-7), edge-clipped
    lda dcol
    cmp #46
    bcc :+
    rts
:   txa
    asl
    asl
    asl
    asl
    clc
    adc #<moth_tiles
    sta src_ptr
    lda #>moth_tiles
    adc #0
    sta src_ptr+1
    jsr set_dst
    stz blit_opaque
    jmp sprite_blit_subpx
.endproc

.proc l3e_moth_blank             ; blank the cell box at the last drawn spot;
    lda e_px                     ; NEVER row 15+ (the floor band lives there)
    lsr
    lsr
    and #$FE
    sta dcol
    lda e_py
    and #$F8
    sta dy
    ldx #3                       ; 3 rows (an aligned box wastes one blank row of
    lda dy                       ; sky -- harmless; the floor cap below protects
    cmp #104                     ; the checker band)
    bcc :+
    ldx #2
:   jmp l3e_box
.endproc

.proc l3e_moth_draw              ; erase old box, draw the 2x2 moth at (e_mx,e_my)
    jsr l3e_moth_blank
    jsr l3e_text2_fix            ; the blank box crosses the "OH! DAISY" row and
                                 ; Mario's edge mid-hop -- repaint what it ate
    lda e_mx
    sta e_px
    lda e_my
    sta e_py
    lda e_mx
    and #3
    sta spr_subx
    lda #1
    sta do_flip
    lda e_hop                    ; wings open in flight, folded at rest
    beq @sit
    stz tmpL3                    ; sheet cols 0-1 = flying
    bra @go
@sit:
    lda #2                       ; sheet cols 2-3 = sitting
    sta tmpL3
@go:
    ldy #0
@q: phy
    lda e_mx
    lsr
    lsr
    clc
    adc quad_cols,y
    sta dcol
    lda e_my
    clc
    adc quad_rows,y
    sta dy
    lda tmpL3                    ; sheet: [fly TL TR sit TL TR fly BL BR sit BL BR]
    clc                          ; order below composes the GB's PAIR-SWAPPED
    adc @tofs,y                  ; mirrored metasprite (left = hi tile, flipped)
    tax
    jsr l3e_mothtile
    ply
    iny
    cpy #4
    bne @q
    stz do_flip
    stz spr_subx
    rts
@tofs: .byte 1, 0, 5, 4
.endproc

.segment "CODE"

.segment "L13E"
.segment "CODE"

.proc l3e_mario_draw             ; blank-erase + draw at the current walk pos
    lda prev_col
    and #$FE
    sta dcol
    lda prev_y
    and #$F8
    sta dy
    ldx #2                       ; y is floor-aligned (104): 2 rows, floor untouched
    jsr l3e_box
    lda spr_x                    ; the render pass normally derives mario_vx
    sta mario_vx                 ; (room s=0: screen == fb)
    jsr draw_player
    lda spr_col
    sta prev_col
    lda spr_y
    sta prev_y
    rts
.endproc
.segment "CODE"


; ---------------------------------------------------------------------------
; BONUS GAME (top-door exit). RE: docs/14 "Bonus game RE" — screen drawn by code
; (states $12/$13), prizes = tiles $01/$02/$03 (1/2/3-UP) + $E5 (flower) in a random
; rotation; Mario on a random floor; every-3-frames tick: the ladder blinks around the
; 3 inter-floor gaps while Mario cycles down a floor; A registers only while a ladder
; is visible; then Mario walks right to the pedestal and the prize is awarded.
; (Port simplification: Mario takes his own floor's prize — the traced run also went
; walk->award with no climb. Climb states $18/$19 not modeled.)

; (the bonus game lives in L11CODE: a bank-1-only blob, copied to RAM $1500 at
; bonus entry -- see the segment near the end of this file)


; bonus_enter_copy: map bank 1 and copy the L11CODE blob (at the TITLE0 address,
; placed there by the packer) into the shared overlay RAM at $1500. The next
; load_level restores whichever overlay the next level needs.
.proc bonus_enter_copy
    lda #<__TITLE0_LOAD__
    sta lvl_ptr
    lda #>__TITLE0_LOAD__
    sta lvl_ptr+1
.endproc                         ; fall through
.proc copy_overlay               ; bank 1 -> 8 pages from (lvl_ptr) to $1500
    lda #(1 << 5) | (SYSCTRL_NMI_EN | SYSCTRL_TIMER_IRQ | SYSCTRL_LCD)
    sta SYS_CTRL
.endproc                         ; falls through
.proc copy_win8                  ; 8 pages from (lvl_ptr) to the $1500 window
    lda #$15
    sta tmpH2
    stz tmpL2
    ldx #8
@pg:
    ldy #0
:   lda (lvl_ptr),y
    sta (tmpL2),y
    iny
    bne :-
    inc lvl_ptr+1
    inc tmpH2
    dex
    bne @pg
    rts
.endproc

; --- SFX player: replays build-time captured register streams of the ORIGINAL's
; sound effects (tools/extract_sfx.py). Row: delay, mask(b0 ch1/b1 ch2/b2 noise),
; payload (3/3/1 bytes); delay $FF ends the stream. ---
.proc sfx_play                   ; A = SFX id (see build/audio/sfx.inc)
    tax
    lda sfx_used                 ; silence the interrupted stream's channels first --
    and #1                       ; an orphaned noise channel otherwise drones forever
    beq :+                       ; (user-caught: jump during the explosion)
    stz CH1_VOLDUTY
:   lda sfx_used
    and #2
    beq :+
    stz CH2_VOLDUTY
:   lda sfx_used
    and #4
    beq :+
    stz CH4_FREQVOL
:
    lda sfx_offsets_lo,x
    clc
    adc #<sfx_data
    sta sfx_p
    lda sfx_offsets_hi,x
    adc #>sfx_data
    sta sfx_p+1
    stz sfx_wait
    lda sfx_chmask,x             ; claim the stream's channels up-front (like the
    sta sfx_used                 ; GB's ownership flags): the music yields them NOW
    lda sfx_nctrl,x              ; noise ctrl incl. the per-sound LFSR width (bit0:
    sta CH4_CTRL                 ; the fly death is the GB's 7-bit buzz; the rest 15-bit)
    rts
.endproc

.proc sfx_tick
    lda sfx_p+1
    beq @idle
    lda sfx_wait
    beq @row
    dec sfx_wait
@idle:
    rts
@row:
    lda (sfx_p)                  ; delay byte
    cmp #$FF
    bne :+
    jmp @end
:   jsr @inc
    lda (sfx_p)                  ; mask
    sta tmpL
    and #$0F
    sta tmpH
    lda tmpL
    lsr
    lsr
    lsr
    lsr
    ora tmpH
    ora sfx_used
    sta sfx_used
    jsr @inc
    lda tmpL
    and #1
    beq :+
    lda (sfx_p)
    sta CH1_FLO
    jsr @inc
    lda (sfx_p)
    sta CH1_FHI
    jsr @inc
    lda (sfx_p)
    sta CH1_VOLDUTY
    ldy #$FF
    sty CH1_LEN
    jsr @inc
:   lda tmpL
    and #2
    beq :+
    lda (sfx_p)
    sta CH2_FLO
    jsr @inc
    lda (sfx_p)
    sta CH2_FHI
    jsr @inc
    lda (sfx_p)
    sta CH2_VOLDUTY
    ldy #$FF
    sty CH2_LEN
    jsr @inc
:   lda tmpL
    and #4
    beq :+
    lda (sfx_p)
    sta CH4_FREQVOL
    ldy #$FF
    sty CH4_LEN
    jsr @inc
:   lda tmpL                     ; vol-only rows (freq unchanged: envelope steps)
    and #$10
    beq :+
    lda (sfx_p)
    sta CH1_VOLDUTY
    jsr @inc
:   lda tmpL
    and #$20
    beq :+
    lda (sfx_p)
    sta CH2_VOLDUTY
    jsr @inc
:   lda (sfx_p)                  ; next row's delay: 0 = SAME frame (multi-channel rows)
    cmp #$FF
    beq @end
    sta sfx_wait
    bne :+
    jmp @row                     ; 0-delay: keep applying this frame (was stretching time)
:   rts
@end:
    lda sfx_used                 ; silence whatever the stream touched
    and #1
    beq :+
    stz CH1_VOLDUTY
:   lda sfx_used
    and #2
    beq :+
    stz CH2_VOLDUTY
:   lda sfx_used
    and #4
    beq :+
    stz CH4_FREQVOL
:   stz sfx_p+1
    rts
@inc:
    inc sfx_p
    bne :+
    inc sfx_p+1
:   rts
.endproc

.segment "LEVELS"                ; the sequencer lives with its data (FIXED is full)
; --- Music sequencer: interprets the ORIGINAL's bank-3 track data, extracted +
; frequency-converted at build time by tools/extract_music.py. Format RE'd from
; MusicStart_6AB5 / the walker at $6CBE and VALIDATED end-to-end against PyBoy
; write-log captures of track $07 (61/61 + 175/175 note events matched in order,
; timing within 0.5 frames -- docs/23-audio.md). Two channel blocks (GB ch1/ch2
; -> the SV squares), X = block offset (0/12), Y = SV register offset (0/4).
; Phrase bytes: $00 = next phrase from the list ($FFFF entry = jump/loop, $0000
; = song end), $01 = hold cell, $9D e d c = instrument (e = GB NRx2 envelope,
; c = GB NRx1 duty), $A0-$AF = cell length := lentab[x] ticks, else = note
; (byte*2 indexes the converted freq table). Ticks at 64Hz (the GB driver's
; timer rate), derived from the 61Hz frame by Bresenham. Envelope steps run at
; tick rate = the GB's 64Hz envelope clock. Music yields any channel a live
; SFX stream claims (sfx_chmask, set at sfx_play) and reclaims it afterwards.
.proc mus_start                  ; A = track index (MUS_* in build/audio/music.inc)
    tax
    lda mus_base_lo,x            ; per-track data base: old tracks sit in the LEVELS
    sta mus_base                 ; prefix blob, the 1-3 ending set in FIXED
    lda mus_base_hi,x
    sta mus_base+1
    lda mus_lt_lo,x
    clc
    adc mus_base
    sta mus_lt
    lda mus_lt_hi,x
    adc mus_base+1
    sta mus_lt+1
    lda mus_l1_lo,x
    clc
    adc mus_base
    sta mus_list
    lda mus_l1_hi,x
    adc mus_base+1
    sta mus_list+1
    lda mus_l2_lo,x
    clc
    adc mus_base
    sta mus_list+12
    lda mus_l2_hi,x
    adc mus_base+1
    sta mus_list+1+12
    lda mus_l3_lo,x
    clc
    adc mus_base
    sta mus_list+24
    lda mus_l3_hi,x
    adc mus_base+1
    sta mus_list+1+24
    lda mus_l4_lo,x
    clc
    adc mus_base
    sta mus_list+36
    lda mus_l4_hi,x
    adc mus_base+1
    sta mus_list+1+36
    ldx #36
@init:
    lda #<mus_zero               ; point the phrase ptr at a ROM $00: the first
    sta mus_pos,x                ; tick pulls phrase 1 from the list
    lda #>mus_zero
    sta mus_pos+1,x
    lda #1
    sta mus_wait,x
    sta mus_len,x
    sta mus_ectr,x
    stz mus_vol,x
    stz mus_env,x
    lda #$40
    sta mus_duty,x
    txa
    beq @armed
    sec
    sbc #12
    tax
    bra @init
@armed:
    lda #$60                     ; ch3 borrows a square at 50% duty (the wave voice's
    sta mus_duty+24              ; stand-in -- the one declared mixing decision)
    lda #$FF
    sta mus_ch3+10               ; ch3: nothing borrowed yet
    stz mus_ch4+10               ; noise: no burst running
    stz sq_user
    stz sq_user+1
    lda #%00011111               ; noise ctrl: ON + L + R + continuous + 15-BIT LFSR
    sta CH4_CTRL                 ; (bit0=0 is the 7-bit metallic buzz -- "awful" drums)
    lda #1
    sta mus_on
    stz mus_acc
    rts
.endproc

.proc mus_stop                   ; silence + stop (channels the SFX owns are left alone)
    stz mus_on
    stz mus_pos+1+24             ; ch3 + noise off
    stz mus_pos+1+36
    lda #$FF
    sta mus_ch3+10
    lda sfx_p+1                  ; noise: silence unless an SFX stream owns it
    beq :+
    lda sfx_used
    and #4
    bne :++
:   stz CH4_FREQVOL
:   ldx #0
    ldy #0
    jsr @kill
    ldx #12
    ldy #4
@kill:
    stz mus_pos+1,x
    stz mus_vol,x
    jsr mus_free
    bcc :+
    lda #$40
    sta CH1_VOLDUTY,y
:   rts
.endproc

.proc mus_tick                   ; every frame, all modes
    lda mus_on
    bne :+
    rts
:   lda paused
    beq :+
    rts                          ; frozen while paused (silenced at pause entry)
:   jsr @tick
    lda mus_acc                  ; rate ticks per 61 frames: 1 base tick + carry
    clc
    adc mus_rate
    sta mus_acc
    cmp #61
    bcc @done
    sbc #61
    sta mus_acc                  ; fall through: the extra tick
@tick:
    ldx #0
    ldy #0
    jsr mus_ch
    ldx #12
    ldy #4
    jsr mus_ch
    jsr mus_ch3t
    jsr mus_chn
    lda mus_pos+1                ; all four channels ended (one-shot jingle) -> off
    ora mus_pos+1+12
    ora mus_pos+1+24
    ora mus_pos+1+36
    bne @done
    stz mus_on
@done:
    rts
.endproc

.proc mus_ch                     ; X = channel block (0/12), Y = SV reg offset (0/4)
    lda mus_pos+1,x
    bne :+
    rts                          ; channel inactive
:   lda mus_env,x                ; --- envelope step (64Hz, like the GB) ---
    and #7
    beq @adv                     ; period 0 = static volume
    lda mus_vol,x
    beq @adv                     ; already silent
    dec mus_ectr,x
    bne @adv
    lda mus_env,x
    and #7
    sta mus_ectr,x
    lda mus_env,x
    and #8
    bne @up
    dec mus_vol,x
    bra @wr
@up:lda mus_vol,x
    cmp #15
    bcs @adv
    inc mus_vol,x
@wr:jsr mus_wrvol
@adv:
    dec mus_wait,x               ; --- cell timing ---
    beq @cell
    rts
@cell:
    lda (mus_pos,x)
    inc mus_pos,x
    bne :+
    inc mus_pos+1,x
:   cmp #0
    bne :+
    jmp @next_phrase
:   cmp #1
    beq @hold
    cmp #$9D
    beq @inst
    cmp #$A0
    bcs @setlen
    ; --- note cell: A = note byte, freq at music_data + byte*2 ---
    sta tmpL
    stz tmpH
    asl tmpL
    rol tmpH
    lda tmpL
    clc
    adc #<music_data
    sta tmpL
    lda tmpH
    adc #>music_data
    sta tmpH
    cpy #0                       ; the owner line reclaims its square from ch3
    bne :+
    stz sq_user
    bra :++
:   stz sq_user+1
:   jsr mus_free
    bcc @regs_done               ; SFX owns this square: advance silently
    lda (tmpL)
    sta CH1_FLO,y
    inc tmpL
    bne :+
    inc tmpH
:   lda (tmpL)
    sta CH1_FHI,y
    lda #$FF
    sta CH1_LEN,y
@regs_done:
    lda mus_env,x                ; restart the envelope
    lsr
    lsr
    lsr
    lsr
    sta mus_vol,x
    lda mus_env,x
    and #7
    sta mus_ectr,x
    jsr mus_wrvol
@hold:
    lda mus_len,x
    sta mus_wait,x
    rts
@setlen:
    and #$0F
    sty tmpH3
    tay
    lda (mus_lt),y
    ldy tmpH3
    sta mus_len,x
    jmp @cell
@inst:
    lda (mus_pos,x)              ; param 0 = GB NRx2 envelope
    sta mus_env,x
    jsr @incp
    jsr @incp                    ; param 1: unobserved in any register write; skipped
    lda (mus_pos,x)              ; param 2 = GB NRx1: bits 7:6 duty -> SV bits 5:4
    lsr
    lsr
    and #$30
    ora #$40
    sta mus_duty,x
    jsr @incp
    jmp @cell
@next_phrase:
    lda (mus_list,x)             ; entry lo
    sta tmpL
    jsr @incl
    lda (mus_list,x)             ; entry hi: 0 = end-all, $FE = dormant, $FF = jump
    jsr @incl
    cmp #0
    beq @end
    cmp #$FE
    beq @dormant
    cmp #$FF
    beq @jump
    pha
    lda tmpL
    clc
    adc mus_base
    sta mus_pos,x
    pla
    adc mus_base+1
    sta mus_pos+1,x
    jmp @cell
@jump:
    lda (mus_list,x)             ; the loop target (a list offset)
    sta tmpL
    jsr @incl
    lda (mus_list,x)
    pha
    lda tmpL
    clc
    adc mus_base
    sta mus_list,x
    pla
    adc mus_base+1
    sta mus_list+1,x
    bra @next_phrase
@dormant:
    stz mus_pos+1,x              ; unterminated/null on the GB = inactive channel;
    stz mus_vol,x                ; it never ends the song
    jsr mus_free
    bcc @end0
    lda #$40
    sta CH1_VOLDUTY,y
@end0:
    rts
@end:
    jmp mus_stop                 ; ANY channel's REAL END entry stops the WHOLE song
                                 ; ($6CB1: clears $dfe9 + full APU reset)
@incp:
    inc mus_pos,x
    bne :+
    inc mus_pos+1,x
:   rts
@incl:
    inc mus_list,x
    bne :+
    inc mus_list+1,x
:   rts
.endproc

.proc mus_wrvol                  ; write vol|duty for channel Y (0/4), SFX-gated
    jsr mus_free
    bcc @skip
    lda mus_vol,x
    ora mus_duty,x
    sta CH1_VOLDUTY,y
@skip:
    rts
.endproc

.proc mus_free                   ; C = channel Y is NOT claimed by a live SFX stream
    lda sfx_p+1
    beq @free
    cpy #0
    bne :+
    lda #1
    bra :++
:   lda #2
:   and sfx_used
    beq @free
    clc
    rts
@free:
    sec
    rts
.endproc

; --- ch3: the GB wave line on a BORROWED square. SV has two squares for the GB's
; three tonal voices; ch3 (the busiest line: 96 notes vs 52/77 in track 7, and the
; ONLY voice sounding for 14% of the tune) plays on whichever square's owner line
; has fully decayed (mus_vol == 0). The owner steals its square back at its next
; note-on (it stamps sq_user); ch3 then stops touching those registers. Wave
; frequency = octave below the shared note table: F3 = F*2+1 (65536 vs 131072
; in the GB formulas). Duty fixed 50%.
.proc mus_ch3t
    ldx #24
    lda mus_pos+1,x
    bne :+
    rts
:   lda mus_env,x                ; envelope (writes gated through mus3_wr)
    and #7
    beq @adv
    lda mus_vol,x
    beq @adv
    dec mus_ectr,x
    bne @adv
    lda mus_env,x
    and #7
    sta mus_ectr,x
    lda mus_env,x
    and #8
    bne @up
    dec mus_vol,x
    bra @wr
@up:lda mus_vol,x
    cmp #15
    bcs @adv
    inc mus_vol,x
@wr:jsr mus3_wr
@adv:
    dec mus_wait,x
    beq @cell
    rts
@cell:
    lda (mus_pos,x)
    inc mus_pos,x
    bne :+
    inc mus_pos+1,x
:   cmp #0
    bne :+
    jmp @next_phrase
:   cmp #1
    bne :+
    jmp @hold
:   cmp #$9D
    bne :+
    jmp @inst
:   cmp #$A0
    bcc :+
    jmp @setlen
:   ; --- note: octave-down freq, then pick a free square ---
    sta tmpL
    stz tmpH
    asl tmpL
    rol tmpH
    lda tmpL
    clc
    adc #<music_data
    sta tmpL
    lda tmpH
    adc #>music_data
    sta tmpH
    lda (tmpL)                   ; F -> tmpL2/tmpH2
    sta tmpL2
    inc tmpL
    bne :+
    inc tmpH
:   lda (tmpL)
    sta tmpH2
    asl tmpL2                    ; F*2+1 = the octave below (wave 65536 vs square
    rol tmpH2                    ; 131072 in the GB freq formulas)
    lda tmpL2
    ora #1
    sta tmpL2
    lda tmpH2
    cmp #8                       ; clamp to 11 bits
    bcc :+
    lda #7
    sta tmpH2
    lda #$FF
    sta tmpL2
:   ldy #0                       ; square 1 free? (owner line decayed + no SFX claim)
    lda mus_vol
    bne @try2
    jsr mus_free
    bcs @have
@try2:
    ldy #4
    lda mus_vol+12
    bne @nofree
    jsr mus_free
    bcs @have
@nofree:
    lda #$FF                     ; all busy: the note advances silently (the GB has
    sta mus_ch3+10               ; three voices sounding; we drop ch3 only here)
    bra @env
@have:
    sty mus_ch3+10
    cpy #0                       ; stamp the square as ch3's
    bne :+
    lda #1
    sta sq_user
    bra :++
:   lda #1
    sta sq_user+1
:   lda tmpL2
    sta CH1_FLO,y
    lda tmpH2
    sta CH1_FHI,y
    lda #$FF
    sta CH1_LEN,y
@env:
    lda mus_env,x                ; restart the envelope state either way
    lsr
    lsr
    lsr
    lsr
    sta mus_vol,x
    lda mus_env,x
    and #7
    sta mus_ectr,x
    jsr mus3_wr
@hold:
    lda mus_len,x
    sta mus_wait,x
    rts
@setlen:
    and #$0F
    tay
    lda (mus_lt),y
    sta mus_len,x
    jmp @cell
@inst:
    lda (mus_pos,x)              ; param 0 = envelope; params 1/2 skipped (duty is
    sta mus_env,x                ; fixed 50% for the borrowed-square wave voice)
    jsr @incp
    jsr @incp
    jsr @incp
    jmp @cell
@next_phrase:
    lda (mus_list,x)
    sta tmpL
    jsr @incl
    lda (mus_list,x)
    jsr @incl
    cmp #0
    beq @end
    cmp #$FE
    beq @dormant
    cmp #$FF
    beq @jump
    pha
    lda tmpL
    clc
    adc mus_base
    sta mus_pos,x
    pla
    adc mus_base+1
    sta mus_pos+1,x
    jmp @cell
@jump:
    lda (mus_list,x)
    sta tmpL
    jsr @incl
    lda (mus_list,x)
    pha
    lda tmpL
    clc
    adc mus_base
    sta mus_list,x
    pla
    adc mus_base+1
    sta mus_list+1,x
    bra @next_phrase
@dormant:
    stz mus_pos+1,x
    stz mus_vol,x
    jsr mus3_wr                  ; silence the borrowed square, release it
    lda #$FF
    sta mus_ch3+10
    rts
@end:
    jmp mus_stop                 ; whole-song stop ($6CB1)
@incp:
    inc mus_pos,x
    bne :+
    inc mus_pos+1,x
:   rts
@incl:
    inc mus_list,x
    bne :+
    inc mus_list+1,x
:   rts
.endproc

.proc mus3_wr                    ; volume write to the borrowed square, if still ours
    ldy mus_ch3+10
    bmi @skip
    ldx #0
    cpy #0
    beq :+
    ldx #1
:   lda sq_user,x
    cmp #1
    beq @ours
    lda #$FF                     ; the owner took it back: stop touching it
    sta mus_ch3+10
    ldx #24
    rts
@ours:
    jsr mus_free
    bcc @done
    lda mus_vol+24
    ora #$60                     ; enable + 50% duty
    sta CH1_VOLDUTY,y
@done:
    ldx #24
@skip:
    rts
.endproc

; --- ch4: the drums on the SV noise channel. Drum table (build-time converted):
; 3 bytes each [FREQVOL init, GB NRx2 envelope, cutoff ticks] -- GB drums are
; length-gated bursts (NR44 bit6), so a tick-counter silences the burst like the
; GB's length counter. On the GB's ch4 EVERY non-command byte is a drum ($01 is
; the vol-0 silent drum) -- verified 95/95 hits against the track-7 capture.
.proc mus_chn
    ldx #36
    lda mus_pos+1,x
    bne :+
    rts
:   lda mus_ch4+10               ; burst cutoff (the GB length counter's stand-in)
    beq @envstep
    dec mus_ch4+10
    bne @envstep
    stz mus_vol,x
    jsr musn_wr
@envstep:
    lda mus_env,x
    and #7
    beq @adv
    lda mus_vol,x
    beq @adv
    dec mus_ectr,x
    bne @adv
    lda mus_env,x
    and #7
    sta mus_ectr,x
    dec mus_vol,x                ; drums only decay
    jsr musn_wr
@adv:
    dec mus_wait,x
    beq @cell
    rts
@cell:
    lda (mus_pos,x)
    inc mus_pos,x
    bne :+
    inc mus_pos+1,x
:   cmp #0
    beq @next_phrase
    cmp #$9D
    beq @inst
    cmp #$A0
    bcs @setlen
    ; --- drum hit: 1-based index into the converted drum table ---
    dec a
    sta tmpL
    asl
    clc
    adc tmpL                     ; *3
    clc
    adc #<(music2_data+MUS_DRUMS)
    sta tmpL
    lda #0
    adc #>(music2_data+MUS_DRUMS)
    sta tmpH
    lda (tmpL)                   ; FREQVOL init
    pha
    and #$F0
    sta mus_duty,x
    pla
    and #$0F
    sta mus_vol,x
    inc tmpL
    bne :+
    inc tmpH
:   lda (tmpL)                   ; envelope byte
    sta mus_env,x
    and #7
    sta mus_ectr,x
    inc tmpL
    bne :+
    inc tmpH
:   lda (tmpL)                   ; cutoff ticks (0 = none)
    sta mus_ch4+10
    jsr musn_wr
    lda #$FF
    sta CH4_LEN
@hold:
    lda mus_len,x
    sta mus_wait,x
    rts
@setlen:
    and #$0F
    tay
    lda (mus_lt),y
    sta mus_len,x
    bra @cell
@inst:
    jsr @incp                    ; params land in the GB's struct shadow; every
    jsr @incp                    ; note-on overwrites them -- consume and ignore
    jsr @incp
    bra @cell
@next_phrase:
    lda (mus_list,x)
    sta tmpL
    jsr @incl
    lda (mus_list,x)
    jsr @incl
    cmp #0
    beq @end
    cmp #$FE
    beq @dormant
    cmp #$FF
    beq @jump
    pha
    lda tmpL
    clc
    adc mus_base
    sta mus_pos,x
    pla
    adc mus_base+1
    sta mus_pos+1,x
    jmp @cell
@jump:
    lda (mus_list,x)
    sta tmpL
    jsr @incl
    lda (mus_list,x)
    pha
    lda tmpL
    clc
    adc mus_base
    sta mus_list,x
    pla
    adc mus_base+1
    sta mus_list+1,x
    bra @next_phrase
@dormant:
    stz mus_pos+1,x
    stz mus_vol,x
    jsr musn_wr
    rts
@end:
    jmp mus_stop                 ; whole-song stop ($6CB1)
@incp:
    inc mus_pos,x
    bne :+
    inc mus_pos+1,x
:   rts
@incl:
    inc mus_list,x
    bne :+
    inc mus_list+1,x
:   rts
.endproc

.proc musn_wr                    ; noise FREQVOL write, yielded to a claiming SFX
    lda sfx_p+1
    beq :+
    lda sfx_used
    and #4
    bne @skip
:   lda mus_vol+36
    ora mus_duty+36
    sta CH4_FREQVOL
@skip:
    rts
.endproc

; --- the pause ding-dong (RE $66D6/$69EC): three short pips on GB ch2 as the pause
; counter passes $28/$20/$18 (8 ticks apart), then it freezes -- exactly three.
; Structs $66F2/$66EE/$66F2: high (X=$7C1 = 2081Hz), low ($783 = 1049Hz), high;
; duty 2, vol 14, cut ~55ms by the length counter. SV: F = 59 / 118 / 59.
.proc pause_dingdong
.ifdef HWMARK
    rts                          ; probe builds: body donated to the marker code
.else
    lda pause_snd
    bne :+
    rts
:   dec pause_snd
    lda pause_snd
    cmp #18
    beq @hi
    cmp #10
    beq @lo
    cmp #2
    beq @hi
    cmp #15                      ; ~3 frames after each pip: the GB length cut (55ms)
    beq @off
    cmp #7
    beq @off
    cmp #0
    beq @off
    rts
@hi:
    lda #59                      ; 2083 Hz
    bra @pip
@lo:
    lda #118                     ; 1050 Hz
@pip:
    sta CH2_FLO
    stz CH2_FHI
    lda #$FF
    sta CH2_LEN
    lda #$6E                     ; enable + duty 2 + vol 14
    sta CH2_VOLDUTY
    rts
@off:
    lda #$40
    sta CH2_VOLDUTY
    rts
.endif
.endproc

mus_zero: .byte 0                ; mus_start seeds phrase ptrs here ("fetch next phrase")

.segment "LEVELS"
.include "../build/audio/sfx.inc"
sfx_data:
    .incbin "../build/audio/sfx.bin"
.include "../build/audio/music.inc"
.export mus_l1_lo, mus_l1_hi, mus_l2_lo, mus_l2_hi, mus_l3_lo, mus_l3_hi
.export mus_l4_lo, mus_l4_hi, music_data
music_data:
    .incbin "../build/audio/music.bin"
.segment "CODE"

; pause_strip: draw (paused=1) or clear (paused=0) the original's "♥PAUSE♥" window strip:
; tiles $2C,$84,P,A,U,S,E,$84,$2C at the screen bottom-right (row 18, cols 11-19). Clearing
; repaints the dirt fill ($61) that draw_column puts there.
.proc pause_strip
    lda paused
    beq @clear
    lda scroll_s                 ; anchor in SCREEN coords: the display window is offset by
    lsr                          ; the scroll, so the fb x = 88 + scroll_s (byte = /4)
    lsr
    clc
    adc #22                      ; (88/4) + scroll_s/4
    sta tmpH3                    ; base byte col
    stz b_i
@loop:
    lda b_i
    asl
    clc
    adc tmpH3
    sta dcol
    lda #144                     ; screen bottom strip (row 18)
    sta dy
    jsr set_dst
    ldx b_i
    lda @txt,x
    jsr get_tile_src
    jsr blit_tile
    inc b_i
    lda b_i
    cmp #9
    bne @loop
    rts
@clear:
    lda scroll_s                 ; unpause: restore the map band under the strip
    clc
    adc #88
    sta rb_vx
    lda #144
    sta rb_y
    lda #10
    sta rb_cols
    lda #1
    sta rb_rows
    jmp restore_bg
@txt: .byte $2C,$84,$19,$0A,$1E,$1C,$0E,$84,$2C   ; the exact $079C bytes
.endproc

; game_over: blank screen + "GAME OVER" text, hold ~4s, then a full machine restart
; (the original shows GAME OVER then returns to the title; the port has no title yet).
.proc game_over
.ifdef HWMARK
    jmp game_over                ; probe builds: body donated (never reached)
.else
    lda #143                     ; trace: the strip rises WY 143 -> 64 at 1px/frame over the
    sta tmpH3                    ; FROZEN game screen, then holds ~256 frames, then exits
@anim:
    jsr @wait1
    dec tmpH3                    ; the strip rises 1px; the new OPAQUE draw covers all of the
    lda scroll_s                 ; old image except its bottom 1px sliver -> restore only the
    sta rb_vx                    ; single tile row containing it (screen-anchored, like PAUSE)
    lda tmpH3
    clc
    adc #8
    sta rb_y
    lda #20
    sta rb_cols
    lda #1
    sta rb_rows
    jsr restore_bg
    jsr @text                    ; draw the 17 glyphs at the new pixel Y
    lda tmpH3
    cmp #64
    bne @anim
    lda #255                     ; hold
    sta tmpL3
@hold:
    jsr @wait1
    dec tmpL3
    bne @hold
    jmp reset
@wait1:
    lda frame_flag
    beq @wait1
    stz frame_flag
    jsr sfx_tick
    jsr mus_tick
    rts
@text:
    stz b_i
@t:
    lda scroll_s                 ; screen-anchored: 17 tiles from screen x=0 (original WX=7)
    lsr
    lsr
    sta dcol
    lda b_i
    asl
    clc
    adc dcol
    sta dcol
    lda tmpH3
    sta dy
    jsr set_dst
    ldx b_i
    lda @txt,x                   ; FONT tiles come from the BG set -- get_tile_src picks it
    jsr get_tile_src             ; (draw_quad reads the OBJ set = Mario tiles = the garbage)
    jsr blit_tile
    inc b_i
    lda b_i
    cmp #17
    bne @t
    rts
@txt: .byte $2C,$2C,$2C,$2C,$2C,$10,$0A,$16,$0E,$2C,$2C,$18,$1F,$0E,$1B,$2C,$2C  ; $1CD7
.endif
.endproc

; next_level: level complete — advance to the next level (GB State_08: $ffe4+1) and
; start it FRESH from column 0. Score, coins, lives and Mario's power-ups
; (big/superball) PERSIST; everything level-local resets. Levels shipped so far:
; 1-1 and 1-2 — the wrap constant grows as more of World 1 comes online.
NUM_LEVELS = 6
.proc next_level
    stz goal_phase
    stz room_mode
    lda cur_level
    inc a
    cmp #NUM_LEVELS
    bcc :+
    lda #0                       ; past the last shipped level: wrap to 1-1
:   sta cur_level
    jsr load_level               ; map the new bank + rebind the level pointers
    jsr ovl_bind                 ; window vectors for this level's overlay
    lda surf_map
    sta map_base
    lda surf_map+1
    sta map_base+1
    stz cam_x                    ; a completed level always restarts at the very start
    stz cam_x+1                  ; (checkpoints are a DEATH mechanic — do_respawn's)
    lda cam_x                    ; fb_col0 = cam/8
    sta fb_col0
    lda cam_x+1
    sta fb_col0+1
    lsr fb_col0+1
    ror fb_col0
    lsr fb_col0+1
    ror fb_col0
    lsr fb_col0+1
    ror fb_col0
    stz spawn_idx                ; fast-forward the spawn list to the checkpoint (else all
@sff:                            ; earlier entries would fire at once on the first frame)
    lda spawn_idx
    asl
    asl
    clc
    adc spawn_idx                ; entry offset = idx*5 (list <= 51 entries)
    tay
    lda spawn_tab+1,y
    cmp #$FF
    beq @sffd
    cmp cam_x+1
    bcc @sfn
    bne @sffd
    lda spawn_tab,y
    cmp cam_x
    bcs @sffd
@sfn:
    inc spawn_idx
    bra @sff
@sffd:
    stz scroll_s
    stz prev_scroll_s
    stz scroll_vis
    stz XSCROLL
    stz jump_state
    stz fall_v
    stz arc_idx
    stz h_idx
    stz h_toggle
    stz skid_t                   ; no brake/momentum state survives a respawn
    stz move_t
    stz mdir
    stz walk_t
    stz walk_i
    stz mario_facing
    stz mario_frame
    stz prev_frame
    stz mario_duck
    stz mario_grow
    stz mario_starT
    stz star_flash
    stz mc_tmr
    lda #$FF
    sta mc_colh
    stz spawn_idx
    stz mario_shrink
    stz hurt_inv
    jsr clear_objects
    jsr clear_tile_mod
    stz shift_px
    lda #40
    sta spr_x
    sta mario_vx
    sta prev_vx
    lda #112
    sta spr_y
    sta prev_y
    jsr render_background
    jsr render_status_bar
    jsr hud_init                 ; clock back to 400 (score/coins/lives untouched)
    jsr draw_hud
    jsr draw_player
    lda #3                       ; 64Hz driver (GB: TMA=0 at level init)
    sta mus_rate
    jsr lvl_music                ; per-level tune (GB table $07CE)
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
    lda #$FF                     ; ONE-SHOT (user-verified on GB in 1-1 AND 1-3:
    sta pipe_tab+1,x             ; a used pipe never re-opens): poison the col hi
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
    ldx #0                       ; byte index into pipe_tab (5 bytes/pipe)
    ldy #0
@loop:
    lda pipe_tab+1,x           ; entry_col high == feet_col high?
    cmp feet_col+1
    bne @next
    lda feet_col                 ; feet_col - entry_col in {0,1} ?
    sec
    sbc pipe_tab,x
    cmp #2
    bcs @next
    lda pipe_tab+2,x           ; -> room index
    rts
@next:
    txa
    clc
    adc #5
    tax
    iny
    cpy pipe_cnt
    bne @loop
    lda #$FF
    rts
.endproc

; enter_room: A = room index. Switch to the room map and drop Mario in at the top-left.
; (The surface state was saved when the sink animation began, in pipe_check.)
.proc enter_room
    pha
    ldx #39                      ; fresh room state every entry (GB reloads the room)
    lda #0
:   sta tile_mod+640,x
    dex
    bpl :-
    lda #1
    sta room_mode
    pla
    asl                          ; map_base = room_tbl[room*2]
    tax
    lda room_tbl,x
    sta map_base
    lda room_tbl+1,x
    sta map_base+1
    stz cam_x
    stz cam_x+1
    stz fb_col0
    stz fb_col0+1
    stz scroll_s
    stz prev_scroll_s
    stz shift_px
    stz scroll_vis
    stz XSCROLL
    stz mario_facing
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
    lda mario_starT               ; underground music ($dfe8=$04 at room entry, $07C8;
    bne :+                        ; skipped while the star tune owns the music, $17AB)
    lda #MUS_UNDER
    jsr mus_start
:   rts
.endproc

; exit_room: return to the surface at the saved camera, standing.
.proc exit_room
    stz room_mode
    lda surf_map
    sta map_base
    lda surf_map+1
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
    lda mario_starT               ; surface music restored via the level table ($07A3),
    bne :+                        ; which returns early while the star is active
    jsr lvl_music                ; per-level tune (GB table $07CE)
:   rts
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
    sta map_row                  ; (rows 0-1 wrap to $FE/$FF = the STATUS BAR rows)
    lda t_col                    ; VRAM tile col = t_col + ri
    clc
    adc ri
    cmp #24                      ; past the 48-byte row stride (24 tile cols incl. the
    bcs @skip                    ; streaming margin)? never blit -- it bleeds into the next row
    sta dcol                     ; stash VRAM tile col (drives dest byte col)
    clc                          ; world col = fb_col0 + VRAM tile col
    adc fb_col0
    sta feet_col
    lda fb_col0+1
    adc #0
    sta feet_col+1
    lda map_row
    cmp #18                      ; rows 0..17 restorable; $FE/$FF (the HUD rows) skip too --
    bcs @skip                    ; nothing is drawn there while Mario occludes behind the HUD
    cmp #16
    bcc @maptile
    lda #$61                     ; dirt band (rows 16,17): solid fill, same as draw_column --
    bra @havetile                ; previously SKIPPED, so sprites falling through the ground
@maptile:                        ; (brick shards) left permanent imprints in the dirt
    sta mrow
    jsr read_map_tile            ; effective tile (used-block transform applied)
    bra @havetile
@havetile:
    pha                          ; the effective tile
    lda dcol                     ; dcol = tile_col*2
    asl
    sta dcol
    lda dy                       ; dy = VRAM tile row * 8 (scanline)
    asl
    asl
    asl
    sta dy
    jsr set_dst
    pla
    cmp #$2C                     ; blank sky (most of a flying shard's erase area):
    beq @blank                   ; zero-fill directly -- skip the src lookup + copy
    jsr get_tile_src
    jsr blit_tile
    bra @skip
@blank:
    jsr blit_blank
@skip:
    inc rj
    lda rj
    cmp rb_rows
    beq :+
    jmp @rloop
:   inc ri
    lda ri
    cmp rb_cols
    beq :+
    jmp @cloop
:   rts
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
    stz stream_pend              ; full re-render supersedes any queued margin columns
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
    jsr lvl_ws                   ; "W-S" under WORLD (row 1 cols 12/14; the '-' is
    pha                          ; static in the template)
    txa
    ldx #12
    jsr put_hud
    pla
    ldx #14
    jsr put_hud
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
    lda timer
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
    lda timer                    ; hit 000? TIME-UP death: the hop plays (harness: state
    ora timer+1                  ; $03 fires with $da1d=$FF regardless of size/star),
    bne @hurry                   ; then the " TIME UP " strip, then the reload
    jsr mus_stop                 ; the jingle REPLACES the music
    lda #SFX_DFE8_02             ; the death jingle plays on time-up too
    jsr sfx_play
    lda #1
    sta timeup
    sta death_anim
    stz mario_duck
    stz ride
    rts
@hurry:                          ; SML's hurry-up: no separate track -- the DRIVER speeds
    lda timer+1                  ; up (bank2 $5851: time 100 -> TMA=$30 = 78.8Hz ticks,
    cmp #1                       ; time 050 -> TMA=$50 = 93.1Hz; TMA reset to 0 at level
    bne @try50                   ; init/death/goal). Port: the Bresenham add per frame.
    lda timer
    bne @done
    lda #18                      ; 61+18 = 79 ticks per 61 frames
    sta mus_rate
    rts
@try50:
    cmp #0
    bne @done
    lda timer
    cmp #$50
    bne @done
    lda #32                      ; 61+32 = 93 ticks per 61 frames
    sta mus_rate
@done:
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
; following him; cam_max (runtime, per level) = max scroll = (lvl_cols - 20) * 8 px.
PIN_X   = 64

; ---------------------------------------------------------------------------
; move_player: walk via the real speed table. Up to PIN_X Mario moves on screen;
; past it his rightward motion scrolls the camera (cam_x) instead, until the level
; end (CAM_MAX) where he walks to the right screen edge. The level never scrolls back.
.proc move_player                ; accelerating walk via the real speed table (px-precise)
    lda skid_t                   ; turn-around brake (GB $c20d=1 state, $1d1e): input is
    beq @nobrake                 ; ignored and Mario is frozen for 8 frames, showing the
    dec skid_t                   ; skid pose (grounded) with the OLD facing
    bne :+
    stz mdir                     ; brake over: direction memory cleared ($1d6b),
    stz walk_t                   ; pose -> stand and the walk cycle restarts ($1d71)
    stz walk_i
    stz mario_frame
:   stz h_idx                    ; speed restarts slow ($c20e=0 at $1d71)
    rts
@nobrake:
    lda move_t                   ; $1d3a: momentum just reached full while slow ->
    cmp #6                       ; walk speed (the acceleration step; also mid-air)
    bne @accdone
    lda h_idx
    bne @accdone
    lda #2
    sta h_idx
@accdone:
    lda pad_held                 ; B rule (bank3 $4975): held + grounded -> run (4)
    and #GB_B                    ; once momentum >= 3, else walk (2); released ->
    beq @brel                    ; a run decays to walk (even mid-air)
    lda jump_state
    bne @bdone
    lda move_t
    cmp #3
    lda #4
    bcs :+
    lda #2
:   sta h_idx
    bra @bdone
@brel:
    lda h_idx
    cmp #4
    bne @bdone
    lda #2
    sta h_idx
@bdone:
    stz mario_duck               ; big Mario, grounded, holding Down -> duck (no walk)
    lda mario_big
    beq @walk
    lda jump_state
    bne @walk
    lda pad_held
    and #GB_DOWN
    beq @walk
    inc mario_duck
    stz move_t                   ; ducking clears the momentum ($1da6)
    rts
@walk:
    lda pad_held
    and #GB_RIGHT
    beq :+
    jmp @right
:   lda pad_held
    and #GB_LEFT
    beq :+
    jmp @left
:   stz h_idx                    ; neutral: speed collapses to slow ($c20e=0, $1d5e)
    lda move_t                   ; momentum decays, and while it lasts Mario GLIDES
    beq @mclr                    ; on in the remembered direction (the $1d5e
    dec move_t                   ; re-dispatch; capture: 6f at 0.5px/f = ~3px)
    lda mdir
    cmp #1
    bne :+
    jmp @rmove
:   cmp #2
    bne :+
    jmp @lmove
:   rts
@mclr:
    stz mdir
    rts
@brake:                          ; opposite direction pressed while moving: the GB
    lda #8                       ; brake ($1e48): $c20c=8 -> 8 input-ignored frames,
    sta skid_t                   ; skid pose, facing NOT flipped
    stz move_t
    rts
@right:
    lda mdir                     ; was moving LEFT -> the turn skid
    cmp #2
    beq @brake
    lda #1                       ; remember the motion direction ($c20d=$10)
    sta mdir
    lda move_t                   ; momentum ramp, cap 6 ($c20c, $1dd8)
    cmp #6
    bcs @rmove
    inc move_t
@rmove:
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
    cmp cam_max+1
    bcc @scroll
    bne @atmax
    lda cam_x
    cmp cam_max
    bcc @scroll
@atmax:                          ; camera maxed -> Mario walks INTO the goal door and stops
    lda tmpL                     ; CENTERED in the arch (cols 298-299 = screen 144-159; the
    cmp #145                     ; original's $c202=160 spans exactly those cells)
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
    cmp cam_max+1
    bcc @rdone
    bne @doclamp
    lda cam_x
    cmp cam_max
    bcc @rdone
@doclamp:
    lda cam_max
    sta cam_x
    lda cam_max+1
    sta cam_x+1
@rdone:
    rts
@setx:
    lda tmpL
    sta spr_x
    rts
@left:
    lda mdir                     ; was moving RIGHT -> the turn skid
    cmp #1
    bne :+
    jmp @brake
:   lda #2                       ; remember the motion direction ($c20d=$20)
    sta mdir
    lda move_t                   ; momentum ramp, cap 6 ($c20c, $1dd8)
    cmp #6
    bcs @lmove
    inc move_t
@lmove:
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

; calc_step: read speedtab[h_idx+toggle] -> h_step, flip the toggle (GB $1eb4).
; h_idx is the persistent speed index ($c20e); move_player's entry rules set it.
.proc calc_step
    lda h_idx                    ; speedtab[idx + toggle]
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
; scroll_apply (FRAME START only): reconcile pixels+coords+scroll with cam_x. The framebuffer holds
; 24 columns (world cols fb_col0..fb_col0+23). We hardware-scroll across the 8-byte
; (32px) off-screen margin via XSCROLL; when the camera moves a full margin past
; fb_col0 we DMA-shift the framebuffer left 8 bytes (4 cols) and stream 4 fresh
; columns into the right margin. Scroll is byte-aligned (4px steps) so the status
; bar and Mario stay pixel-exact while reusing the byte-aligned blits.
; (fbmax_col, runtime per level = lvl_cols - 24: last fb_col0 that keeps cols
;  fb_col0..+23 inside the level.)
.proc scroll_apply
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
    cmp fbmax_col+1
    bcc @doshift
    bne @clampend
    lda fb_col0
    cmp fbmax_col
    bcc @doshift
@clampend:                       ; at the level end: pin scroll to the last margin (<=32)
    lda tmpL
    cmp #33
    bcc @apply
    lda #32
    bra @apply
@doshift:
    jsr flush_stream             ; a queued margin column from the PREVIOUS shift must
                                 ; be drawn before shifting again, or it strands as a
                                 ; stale band inside the visible area
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
    lda death_anim               ; dying? the DEAD pose: tiles $0F/$1F + their X-mirrors
    beq :+                       ; (RE State_03 builds exactly this 16x16 OAM group)
    jmp @dead
:   lda star_flash               ; star invincibility: Mario blinks (skip the draw this phase;
    beq :+                       ; the erase runs every frame regardless, so nothing goes stale)
    rts
:   lda hurt_inv                 ; post-hit mercy: blink too
    and #2
    beq :+
    rts
:                                ; (during the goal sequence Mario stays VISIBLE, standing
                                 ;  framed in the door arch -- original-accurate)
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
    lda mario_grow               ; growing (or shrinking)? flash big<->small every 4 frames
    ora mario_shrink
    beq @sizesel
    and #$04
    bne @big                     ; timer bit2 set -> big tiles this frame
    bra @small                   ; else small tiles
@sizesel:
    lda mario_big                ; small or big ("Super") Mario pose set?
    beq @small
    lda mario_duck               ; big + ducking -> force the duck pose (index 6 -> offset 24)
    beq @big
    ldx #24
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
    lda spr_y                    ; Mario draws OVER the HUD (GB sprites sit above the BG
    cmp #153                     ; status bar); his erase restores the template. Only clip
    bcs @bottom                  ; the bottom: dy>152 would spill past line 160
    cmp #16                      ; quads in the HUD band: OCCLUDE (Mario passes behind the
    bcc @bottom                  ; HUD) until the row-split renderer lands -- the two scroll
    lda spr_col                  ; TL   domains otherwise tear his halves apart
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
@bottom:
    lda spr_y                    ; bottom quads below the frame? clip
    clc
    adc #8
    cmp #153
    bcc :+
    rts
:   cmp #16                      ; bottom pair in the HUD band? occlude it too
    bcs :+
    rts
:   lda spr_col                  ; BL (y+8)
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
@dead:
    lda spr_y                    ; 4 mirrored quads at Mario's spot; the bottom clip
    cmp #153                     ; hides rows past the frame as he falls out
    bcs @dbot
    lda mario_vx
    and #3
    sta spr_subx
    lda mario_vx
    lsr
    lsr
    sta dcol
    lda spr_y
    sta dy
    stz do_flip
    ldx #$0F
    jsr draw_quad
    lda mario_vx
    lsr
    lsr
    ina
    ina
    sta dcol
    lda spr_y
    sta dy
    lda #1
    sta do_flip
    ldx #$0F
    jsr draw_quad
@dbot:
    lda spr_y
    clc
    adc #8
    cmp #153
    bcs @ddone
    cmp #16
    bcc @ddone
    lda mario_vx
    and #3
    sta spr_subx
    lda mario_vx
    lsr
    lsr
    sta dcol
    lda spr_y
    clc
    adc #8
    sta dy
    stz do_flip
    ldx #$1F
    jsr draw_quad
    lda mario_vx
    lsr
    lsr
    ina
    ina
    sta dcol
    lda spr_y
    clc
    adc #8
    sta dy
    lda #1
    sta do_flip
    ldx #$1F
    jsr draw_quad
@ddone:
    stz do_flip
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
OBJ_FLOWER = 3
OBJ_BALL   = 4
OBJ_HEART  = 5                   ; 1-up heart ($2a): same hop->walk engine as the mushroom
OBJ_STAR   = 6                   ; star ($2c): rises, then bounces forward in small arcs
OBJ_DEBRIS = 7                   ; brick-break shard: flies along the jump arc (trace-verified)
OBJ_POPUP  = 8                   ; floating score text ("1000"/"1UP"): 2 glyph tiles side by side
OBJ_BOUNCE = 9                   ; bonked-block hop: the block tile as a sprite, cell blank under it
OBJ_PLATV  = 10                  ; end-area moving platform, vertical (SML type $0A)
OBJ_PLATH  = 11                  ; end-area moving platform, horizontal (SML type $0B)
PLAT_TILE  = $EF                 ; platform = 3x tile $EF (24px; metasprite param $12)
; patrol geometry from the goal trace at cam-max (GB OAM coords -8/-16 -> world):
DEBRIS_TILE = $62                ; all 4 shards are OBJ tile $62 (mGBA OAM trace)
DEBRIS_HI  = 7                   ; jump-arc start index: high pair rises 21px (trace: 21px)
DEBRIS_LO  = 11                  ; low pair rises 13px (trace: 13px)
COINSPIN   = $F6                 ; coin-pop spin: $F6->$F7->$F8->$F7 ping-pong, 1 tile/frame
POP_1000_L = $59                 ; "10" glyph  (popup value $10 -> tiles $59,$57 in bank2 $5892)
POP_1000_R = $57                 ; "00"
POP_1UP_L  = $5E                 ; "1U"        (popup value $ff -> tiles $5E,$5F)
POP_1UP_R  = $5F                 ; "P."
HEART_TILE = $84                 ; heart = 1 OBJ tile (metasprite param $17)
JREL_IDX   = 13                  ; A released mid-rise -> arc index skips here (calibrated)
OBJ_CHIB   = 12                  ; Chibibo/Goombo (SML type $00): leftward walker
OBJ_SQUASH = 13                  ; squashed enemy corpse: static tile (in o_vx), short timer
CHIB_TA    = $90                 ; Chibibo walk frames (metasprite params $00/$01)
CHIB_TB    = $91
POP_100_L  = $59                 ; "100" popup = value $01 -> tiles $59,$58 (bank2 $5892)
POP_100_R  = $58
OBJ_NOKO   = 14                  ; Nokobon / Bombshell Koopa (SML type $04): 8x16 walker
OBJ_BOMB   = 15                  ; its stomped shell: ticking bomb (type $05) -- harmless touch
OBJ_BOOM   = 16                  ; the explosion (type $46): 16px wide, contact HURTS
NOKO_B1    = $97                 ; walk frame A: bottom / top
NOKO_T1    = $96
NOKO_B2    = $99                 ; walk frame B
NOKO_T2    = $98
BOMB_TA    = $9A                 ; bomb blink tiles
BOMB_TB    = $9B
BOOM_TA    = $9D                 ; explosion cloud (drawn + X-mirrored pair)
BOOM_TB    = $9E
BOMB_FUSE  = 63                  ; trace-exact: stomp f694 -> explosion f757 (~1.0s)
BOOM_LIFE  = 44                  ; trace: >=43 frames live (capture ended mid-cloud)
OBJ_FLY    = 17                  ; the Fly (SML type $0E): sits, then hops toward Mario
OBJ_CORPSE = 18                  ; ball/star kill: the enemy Y-FLIPPED, hops and falls off
; --- the 1-3 kit (types >= OBJ_GIFT dispatch into the bank-2 RAM overlay, L3CODE).
; OBJ_GIFT sits NEXT TO OBJ_STONE: both are 8px RIDEABLES (plat_land/plat_xover/
; ride_support accept the STONE..GIFT pair as one class). ---
OBJ_GIFT   = 22                  ; $13->$14: the hidden-block LIFT ($E6): ride -> rises
OBJ_SUU    = 23                  ; $02: bobbing spider (8x16, rises 16px, anim at the top)
OBJ_ROCK   = 24                  ; $0C: spiky ball (16x8): hangs ~174f, falls thru terrain
OBJ_GAO    = 25                  ; $3F: sphinx statue (16x16): fires every 137f
OBJ_FIRE   = 26                  ; $23: Gao's fireball (8x8 $E2): 1px/f x, 0.5px/f aimed y
OBJ_BAT    = 27                  ; $08: moai flyer (32x16): bobs, launches 2 shots/cycle
OBJ_BULL   = 28                  ; $1E: the flyer's shot (16x8): 1px/f horizontal
OBJ_GSQ    = 29                  ; $40: stomped Gao (flat pair ~48f, then the corpse)
OBJ_GCORP  = 30                  ; $41: Gao corpse: kill_flip-style hop + fall
                                 ; the screen (GB type $0D; slot capture: rise 7px, fall to
                                 ; +2px/f, 1px/f sideways drift away from the killer)
FLY_TL     = $A0                 ; 16x16 metasprite, frame A: A0 A1 / B0 B1
FLY_BL     = $B0
FLY_TL2    = $A2                 ; frame B
FLY_BL2    = $B2
FLY_SQ     = $A8                 ; flattened corpse pair $A8+$A9 (param $2C)
FLY_SIT    = 55                  ; trace: ~55 grounded frames between hops
OBJ_BUNBUN = 19                  ; Bunbun bee (SML type $42, 1-2/4-2): flies level toward
                                 ; Mario, hovers, drops an arrow (slot capture 2026-07-13:
                                 ; 1px/f x 40f fly, 33f hover, arrow at hover+17, re-face
                                 ; each cycle; wing flap = params $30/$31 every 8f)
OBJ_ARROW  = 20                  ; its arrow (type $45): 1px/f straight down, x frozen, no
                                 ; terrain collision, off the bottom; ANY contact hurts
OBJ_STONE  = 21                  ; stepping stone (type $36): static rideable 8px block;
                                 ; landing morphs it ($3186: $36->$37) -> short beat, then
                                 ; falls 1px/f carrying the rider (script $399D)
BUN_TL     = $C0                 ; bunbun 16x16, faces LEFT natively: C0 C1 / D0 D1
BUN_BL     = $D0                 ;   (frame B = +2, like the fly's tile pairs)
BUN_SQ     = $C8                 ; stomped: flat pair $C8+$C9 (param $34)
BUN_FLY_T  = 40                  ; cycle: fly frames,
BUN_HOV_T  = 33                  ;   hover frames,
BUN_DROP_T = 57                  ;   arrow drop at cycle tick 40+17
ARROW_T    = $AC                 ; arrow: shaft on top, HEAD at the bottom — it points
ARROW_B    = $BC                 ; down (param $44 list: $BC at base y, $AC at y-8)
STONE_T    = $EE                 ; the stone's single 8x8 tile (param $21)
STONE_BEAT = 8                   ; triggered: one script step's pause before the drop ($399D E7)
STAR_TA    = $86                 ; star twinkles between $86 and $85 (param $19 list)
STAR_TB    = $85
BALL_TILE  = $60                 ; superball = 1 OBJ tile (mGBA OAM trace)
BALL_SPD   = 2                   ; 2 px/frame, both axes (45 deg diagonal, from the trace)
BALL_LIFE  = 90                  ; max lifetime (frames); also expires off-screen
MUSH_TILE  = $83                 ; SML Super Mushroom = a single 8x8 OBJ sprite (verified via
                                 ; SameBoy OAM/VRAM dump: the only on-screen item sprite)
COIN_TILE  = $F4                 ; spinning-coin tile (same as floating coins; $5F was garbage)
FLOWER_TA  = $E0                 ; Superball Flower: 8x8 OBJ sprite, 2-frame flash $E0<->$E5
FLOWER_TB  = $E5                 ; (both verified in the obj set via mGBA VRAM dump)
FLOWER_RISE = 7                  ; emerge: rise 7px out of the block, then sit (trace: y 79->72)

; clear_objects: free all slots (level restart / pipe transition).
.proc clear_objects
    stz ride                     ; no platforms left to ride
    ldx #OBJ_MAX-1
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
    cpx #OBJ_MAX
    bne @l
    sec
    rts
@ok:
    stz o_hp,x                   ; fresh slot: full health
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

; spawn_walker (A = OBJ_MUSH or OBJ_HEART): the mushroom-style item — hop out of the block,
; then drop + walk. The 1-up heart uses the IDENTICAL engine in the original (types $2A/$2B
; share the $28/$29 physics + script; only the sprite param differs).
.proc spawn_walker
    pha
    jsr spawn_item_snd
    pla
    sta tmpH
    jsr find_free_evict
    bcs @full
    lda tmpH
    sta o_type,x
    jsr obj_set_x8
    lda mrow                     ; o_y = mrow*8 (feet rest on the block top)
    asl
    asl
    asl
    sta o_y,x
    lda #1                       ; walk right
    sta o_vx,x
    lda #$FB                     ; vy = -5/update: the upward "pop"
    sta o_vy,x
    lda #25                      ; HOP duration (updates) ~= the original's $28 stage (~50 frames)
    sta o_tmr,x
@full:
    rts
.endproc

; spawn_flower: Superball Flower — emerges from the block then sits still (no movement).
; Only spawned when Mario is ALREADY big (small Mario gets a mushroom instead). RE'd from an
; mGBA trace (tools/trace_flower.lua): type $2D rises ~7px over ~20 frames while flashing, then
; morphs to $2E and sits animating in place; physics byte0=$00 => no gravity, no wall bounce.
.proc spawn_item_snd             ; the item-emerge sound (user-ID'd: id 8 = $dfe0=$0B)
    lda #SFX_DFE0_0B
    jmp sfx_play
.endproc
.proc spawn_flower
    jsr spawn_item_snd
    jsr find_free_evict
    bcs @full
    lda #OBJ_FLOWER
    sta o_type,x
    jsr obj_set_x8
    lda mrow                     ; start at the block, then rise UP to o_y=mrow*8 (= one tile on
    asl                          ; top of the block: block draws at dy=mrow*8+16, the flower at
    asl                          ; dy=o_y+8, so o_y=mrow*8 sits it exactly on the block's top)
    asl
    clc
    adc #FLOWER_RISE
    sta o_y,x
    stz o_vx,x                   ; the flower never moves horizontally or falls
    stz o_vy,x
    lda #FLOWER_RISE             ; emerge counter: rise this many px (1/update) up to the block top
    sta o_tmr,x
@full:
    rts
.endproc

; --- star ($2c -> type $2C rise, morph $34 bounce; RE'd from the AI scripts @ $38C3/$3964) ---
; The $34 script encodes the hop as a per-update vy ramp (up 3,2,1,1,0 then falling) with
; X speed 1 throughout; floor contact restarts the ramp; walls reverse X.
; the star's flight, TRACE-EXACT (/tmp/sml_star.txt): ONE symmetric eased arc -- 19px
; rise over ~42 frames, mirrored fall, x drifting 1px/3 frames -- then X freezes and
; it sinks 1px/frame straight down through everything until off-screen. No loop.
; Entries are per object-update (30Hz); x moves on 2 of 3 updates (0.33px/f).
star_ay: .byte $FE,$FE,$FF, $FE,$FF,$FF, $FE,$FF,$FF, $FF,$FF,$00, $FF,$FF,$00
         .byte $FF,$00,$00, $FF,$00,$00
         .byte $00,$00,$01, $00,$00,$01, $00,$01,$01, $00,$01,$01, $01,$01,$02
         .byte $01,$01,$02, $01,$02,$02
star_ax: .byte 1,1,0,1,1,0,1,1,0,1,1,0,1,1,0,1,1,0,1,1,0
         .byte 1,1,0,1,1,0,1,1,0,1,1,0,1,1,0,1,1,0,1,1,0
STAR_ARC_N = 42

; spawn_star: rise straight out of the block (script: 2 updates x 4px), then bounce forward.
.proc spawn_star
    jsr spawn_item_snd
    jsr find_free_evict
    bcs @full
    lda #OBJ_STAR
    sta o_type,x
    jsr obj_set_x8
    lda mrow
    asl
    asl
    asl
    sta o_y,x
    lda #1                       ; travels forward; reverses on walls
    sta o_vx,x
    lda #2                       ; emerge: 2 updates x 4px = 8px rise (script vel $40 x2)
    sta o_tmr,x
    stz o_st,x
@full:
    rts
.endproc

; upd_star (oi=slot): every-other-frame like the other items. Emerge, then bounce via the
; star_vy ramp; floor restarts the ramp; wall reverses X; Mario overlap -> invincibility.
.proc upd_star
    lda frame_count
    lsr
    bcc :+
    rts
:   ldx oi
    lda o_tmr,x                  ; emerging: 4px/update straight up, no X motion
    beq @bounce
    dec o_tmr,x
    lda o_y,x
    sec
    sbc #4
    sta o_y,x
    jmp @consume
@bounce:
    lda o_y,x                    ; RE (phys $34 = $0C: NO floor-response bits): the star
    cmp #160                     ; NEVER collides with terrain -- the arc is pure script,
    bcc :+                       ; net-sinking each loop until it leaves the screen
    cmp #240
    bcs :+
    stz o_type,x                 ; fell out -> gone (the original's off-screen cull)
    rts
:   ldy o_st,x                   ; arc done? sink 1px/frame, x frozen (trace: dead vertical)
    cpy #STAR_ARC_N
    bcc :+
    lda o_y,x
    clc
    adc #2
    sta o_y,x
    bra @consume2
:   lda star_ay,y                ; y += star_ay[st] (the traced arc)
    clc
    adc o_y,x
    sta o_y,x
    lda star_ax,y                ; x drifts on 2 of 3 updates during the arc
    beq @noax
    inc o_st,x
    bra @xmove2
@noax:
    inc o_st,x
    bra @consume2
@xmove2:
    lda o_vx,x                   ; wall ahead (one row above the feet) -> reverse
    bmi @wleft
    lda o_xl,x
    clc
    adc #8
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    bra @wtest
@wleft:
    lda o_xl,x
    sec
    sbc #1
    sta feet_col
    lda o_xh,x
    sbc #0
    sta feet_col+1
@wtest:
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    ldx oi
    lda o_y,x
    lsr
    lsr
    lsr
    sec
    sbc #1
    sta mrow
    jsr read_solid
    beq @wmove
    ldx oi
    lda o_vx,x
    eor #$FF
    ina
    sta o_vx,x
    bra @consume
@wmove:
    jsr mush_xmove
@consume2:
@consume:
    ldx oi                       ; Mario overlap -> invincibility (same AABB as the mushroom)
    lda cam_x
    clc
    adc spr_x
    sta tmpL
    lda cam_x+1
    adc #0
    sta tmpH
    sec
    lda tmpL
    sbc o_xl,x
    sta tmpL
    lda tmpH
    sbc o_xh,x
    sta tmpH
    bpl @posdx
    sec
    lda #0
    sbc tmpL
    sta tmpL
    lda #0
    sbc tmpH
    sta tmpH
@posdx:
    lda tmpH
    bne @done
    lda tmpL
    cmp #14
    bcs @done
    lda spr_y
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #16
    bcs @done
    lda #248                     ; star! 248 ticks, dec every 4th frame (~16s; $c0d3=$f8)
    sta mario_starT
    stz star_flash
    lda #MUS_STAR                ; the star tune ($09C9 writes $dfe8=$0C with the timer);
    jsr mus_start                ; it is ONE-SHOT -- its end also ends the star ($1F08)
    lda #$00                     ; +1000
    ldx #$10
    jsr add_score
    lda #POP_1000_L              ; floating "1000"
    ldy #POP_1000_R
    jsr spawn_popup
    ldx oi
    stz o_type,x
@done:
    rts
.endproc

; --- brick debris (trace: tools/trace_bounce.lua) --- 4 shards, all tile $62, x = +/-1 px
; EVERY frame, y follows Mario's own jump-arc table: the high pair from index 7 (21px rise),
; the low pair from index 11 (13px), hold at the $7F apex, then fall back down the mirrored
; table. Exactly how the original steps $c218/28/38/48 along JumpArcTable each frame.
.proc spawn_debris4
    ldx #OBJ_MAX-1               ; the original keeps debris in 4 FIXED slots ($c218/28/38/48):
:   lda o_type,x                 ; a second break OVERWRITES the first set -- never 8 shards.
    cmp #OBJ_DEBRIS              ; (their pending erase survives: o_pdr stays set, so the old
    bne :+                       ; images are wiped this frame before the new ones draw)
    stz o_type,x
:   dex
    bpl :--
    lda #$FF                     ; left, high arc
    ldy #DEBRIS_HI
    jsr spawn_debris1
    lda #$FF                     ; left, low arc
    ldy #DEBRIS_LO
    jsr spawn_debris1
    lda #1                       ; right, high arc
    ldy #DEBRIS_HI
    jsr spawn_debris1
    lda #1                       ; right, low arc
    ldy #DEBRIS_LO
    jsr spawn_debris1
    rts
.endproc

.proc spawn_debris1              ; A = vx (+1/-1), Y = jump-arc start index
    sta tmpL
    sty tmpH
    jsr find_free_obj
    bcs @full
    lda #OBJ_DEBRIS
    sta o_type,x
    jsr obj_set_x8               ; o_x = the brick cell's left edge
    lda tmpL
    sta o_vx,x
    bpl @right
    lda o_xl,x                   ; left shard: 4px left of the cell
    sec
    sbc #4
    sta o_xl,x
    lda o_xh,x
    sbc #0
    sta o_xh,x
    bra @sety
@right:
    lda o_xl,x                   ; right shard: 4px right
    clc
    adc #4
    sta o_xl,x
    lda o_xh,x
    adc #0
    sta o_xh,x
@sety:
    lda mrow                     ; start inside the brick cell (obj space: dy = o_y + 8)
    asl
    asl
    asl
    clc
    adc #8
    sta o_y,x
    lda tmpH
    sta o_st,x                   ; jump-arc index
    stz o_vy,x                   ; phase 0 = rising
@full:
    rts
.endproc

; upd_debris: runs EVERY frame (shards are fast). Rise along the arc, hold at the $7F apex,
; then walk the same table backwards for the fall; free the slot below the screen.
.proc upd_debris
    jsr mush_xmove               ; o_x += o_vx (+/-1, sign-extended)
    ldx oi
    lda o_vy,x                   ; phase: 0 = rising, 1 = falling
    bne @fall
    ldy o_st,x
    lda jumparc,y
    cmp #$7F                     ; apex marker -> fall from next frame
    beq @apex
    sta tmpL
    lda o_y,x
    sec
    sbc tmpL
    sta o_y,x
    inc o_st,x
    bra @cull
@apex:
    lda #1
    sta o_vy,x
    bra @cull
@fall:
    lda o_st,x                   ; mirror: walk the arc back down; hold at entry 0 (2px/f)
    beq :+
    dec o_st,x
:   ldy o_st,x
    lda jumparc,y
    clc
    adc o_y,x
    sta o_y,x
@cull:
    ldx oi
    lda o_y,x                    ; fell below the screen -> free
    cmp #160
    bcc @done
    cmp #240                     ; (a wrap above the top while rising is not "below")
    bcs @done
    stz o_type,x
@done:
    rts
.endproc

; --- floating score popup ("1000"/"1UP") --- RE bank2 $5892/$59a5: 2 glyph sprites at the
; pickup point, rising 1px every 2 frames, 32 ticks (= 64 frames) then gone.
.proc mario_anchor               ; tmpL2/H2 = Mario world x, tmpH3 = his y
    lda cam_x                    ; (original: $ffeb = $c202 + $fc, $ffec = $c201 - $10)
    clc
    adc spr_x
    sta tmpL2
    lda cam_x+1
    adc #0
    sta tmpH2
    lda spr_y
    sta tmpH3
    rts
.endproc

.proc spawn_popup                ; A = left glyph tile, Y = right glyph tile, at MARIO
    pha
    jsr mario_anchor
    pla
at:                              ; ...or at tmpL2/H2 (world x) + tmpH3 (y):
    sta tmpL                     ; a KILL tag can ride the VICTIM instead (GB film:
    sty tmpH                     ; "5000" above the boss's burst, Mario at range)
    jsr find_free_obj
    bcs @full
    lda #OBJ_POPUP
    sta o_type,x
    lda tmpL2
    sec
    sbc #4
    sta o_xl,x
    lda tmpH2
    sbc #0
    sta o_xh,x
    lda tmpH3
    sec
    sbc #16
    sta o_y,x
    lda tmpL
    sta o_vx,x                   ; left glyph rides in o_vx (a popup never moves in X)
    lda tmpH
    sta o_st,x                   ; right glyph in o_st
    lda #32                      ; 32 ticks (one tick per 2 frames)
    sta o_tmr,x
@full:
    rts
.endproc
spawn_popup_at = spawn_popup::at

.proc upd_popup
    lda frame_count              ; 1px up every 2nd frame (slot-staggered so several
    eor oi                       ; popups don't concentrate on the same frames)
    lsr
    bcc :+
    rts
:   ldx oi
    dec o_y,x
    dec o_tmr,x
    bne @done
    stz o_type,x
@done:
    rts
.endproc

; --- bonked-block hop --- trace: the block's own tile rises -2,-2 then falls +1,+2 (~5
; frames) as a sprite, then the cell's final tile is stamped. The final tile is stamped
; immediately underneath (the hop sprite covers it), so scrolling stays consistent.
bounce_dy: .byte $FE,$FE,$01,$02

.proc spawn_bounce               ; A = the pre-bonk display tile ($80/$81, $82 for bricks/mc)
    sta tmpL
    jsr find_free_evict
    bcs @full
    lda #OBJ_BOUNCE
    sta o_type,x
    jsr obj_set_x8
    lda mrow                     ; the block cell in object space (dy = o_y+8 = (mrow+2)*8)
    asl
    asl
    asl
    clc
    adc #8
    sta o_y,x
    lda tmpL
    sta o_vx,x                   ; the tile it shows
    stz o_st,x
@full:
    rts
.endproc

.proc upd_bounce
    ldx oi
    ldy o_st,x
    lda bounce_dy,y
    clc
    adc o_y,x
    sta o_y,x
    inc o_st,x
    lda o_st,x
    cmp #4
    bne @done
    stz o_type,x                 ; anim over (the final tile is already stamped in the BG)
@done:
    rts
.endproc

; --- moving platforms (SML types $0A/$0B), TABLE-DRIVEN from the spawn list.
; GB truth (scripts $3638/$364A + 1-2 slot captures, 2026-07-13): a platform spawns
; at world x = fire+192+x_off*4 and patrols AWAY first at 0.5px/frame, ping-pong:
; vertical = spawn y DOWN 60px and back; horizontal = spawn x LEFT 53px and back.
; (These bounds reproduce 1-1's dedicated goal-trace patrol exactly: o_y 64..124 /
; x 2291..2344.) o_st = offset from the spawn point, o_vy = returning flag. ---

; upd_platv: down 60px from the spawn point and back; carries the rider.
.proc upd_platv
    lda frame_count
    lsr
    bcc :+
    rts
:   ldx oi
    lda o_vy,x
    bne @up
    inc o_y,x                    ; away: down
    jsr carry_y_dn
    ldx oi
    inc o_st,x
    lda o_st,x
    cmp #60
    bcc @done
    lda #1
    sta o_vy,x
@done:
    rts
@up:
    dec o_y,x
    jsr carry_y_up
    ldx oi
    dec o_st,x
    bne @done
    stz o_vy,x
    rts
.endproc

carry_y_dn:                      ; riding this slot? Mario follows the platform
    jsr riding_this
    bne :+
    inc spr_y
:   rts
carry_y_up:
    jsr riding_this
    bne :+
    dec spr_y
:   rts
riding_this:                     ; Z=1 if Mario rides slot oi
    lda ride
    beq @no
    dea
    cmp oi
    rts
@no:
    lda #1                       ; clear Z
    rts

; upd_plath: left 53px from the spawn point and back; carries the rider.
.proc upd_plath
    lda frame_count
    lsr
    bcc :+
    rts
:   ldx oi
    lda o_vy,x
    bne @right
    lda o_xl,x                   ; away: left
    bne :+
    dec o_xh,x
:   dec o_xl,x
    jsr riding_this
    bne :+
    dec spr_x
:   ldx oi
    inc o_st,x
    lda o_st,x
    cmp #53
    bcc @done
    lda #1
    sta o_vy,x
@done:
    rts
@right:
    inc o_xl,x
    bne :+
    inc o_xh,x
:   jsr riding_this
    bne :+
    inc spr_x
:   ldx oi
    dec o_st,x
    bne @done
    stz o_vy,x
    rts
.endproc

; plat_land: called while FALLING (tmpL = this frame's fall delta). If Mario's feet crossed
; a platform's top this frame and he x-overlaps it, land + ride. Returns A=1 if landed.
.proc l3_above                   ; bcc = Mario is on the stomp side (4+px above)
    lda spr_y
    clc
    adc #4
    cmp o_y,x
    rts
.endproc

.proc plat_land
    stz oi2
@loop:
    ldx oi2
    lda o_type,x
    cmp #OBJ_PLATV
    beq @try
    cmp #OBJ_PLATH
    beq @try
    cmp #OBJ_STONE
    beq @try
    cmp #OBJ_GIFT                ; the 1-3 hidden-block lift rides like a stone
    beq @try
@next:
    inc oi2
    lda oi2
    cmp #OBJ_MAX
    bne @loop
    lda #0
    rts
@try:
    lda o_y,x                    ; T = platform top = o_y - 8
    sec
    sbc #8
    sta tmpH                     ; tmpH = T
    lda spr_y                    ; crossed T this frame? old = spr_y - tmpL <= T <= spr_y
    cmp tmpH
    bcc @next                    ; still above it
    lda spr_y
    sec
    sbc tmpL
    sbc #3                       ; +3px slop: stepping off a SINKING stone onto its
    cmp tmpH                     ; neighbour still catches -- tuned so RUNNING
    bcc :+                       ; crosses the collapsing bridge but WALKING falls,
    bne @next                    ; like the GB (user-calibrated thresholds)
:   jsr plat_xover               ; x-overlap?
    bcs @next
    ldx oi2
    lda tmpH                     ; land: snap to the platform top + ride it
    sta spr_y
    stz jump_state
    stz fall_v
    lda oi2
    ina
    sta ride
    lda #1
    rts
.endproc

; plat_xover: C=0 if Mario's centre is within +/-16 px of platform slot oi2's centre.
.proc plat_xover
    ldx oi2
    lda cam_x                    ; Mario centre world x = cam + spr_x + 8
    clc
    adc spr_x
    sta tmpL2
    lda cam_x+1
    adc #0
    sta tmpH2
    lda tmpL2
    clc
    adc #8
    sta tmpL2
    bcc :+
    inc tmpH2
:   lda o_type,x                 ; platform centre = o_x + 12 (24px); stone/lift = o_x + 4
    cmp #OBJ_STONE
    beq :+
    cmp #OBJ_GIFT
    bne :++
:   lda o_xl,x
    clc
    adc #4
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    bra @diff
:   lda o_xl,x
    clc
    adc #12
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
@diff:
    sec                          ; diff = mario - plat (16-bit, abs)
    lda tmpL2
    sbc tmpL3
    sta tmpL3
    lda tmpH2
    sbc tmpH3
    bpl @pos
    eor #$FF
    tay
    lda tmpL3
    eor #$FF
    ina
    sta tmpL3
    bne :+
    iny
:   tya
@pos:
    bne @no                      ; |diff| >= 256
    ldy #16                      ; overlap window: platform +/-16, stone/lift +/-12
    lda o_type,x
    cmp #OBJ_STONE
    beq :+
    cmp #OBJ_GIFT
    bne :++
:   ldy #12
:   sty tmpH3
    lda tmpL3
    cmp tmpH3
    bcs @no
    clc
    rts
@no:
    sec
    rts
.endproc

; ride_support: A=1 if Mario is still supported by the platform he rides (x-overlap holds).
.proc ride_support
    lda ride
    beq @no
    dea
    sta oi2
    ldx oi2
    lda o_type,x                 ; platform still there?
    cmp #OBJ_PLATV
    beq :+
    cmp #OBJ_PLATH
    beq :+
    cmp #OBJ_STONE
    beq :+
    cmp #OBJ_GIFT
    bne @off
:   jsr plat_xover
    bcs @off
    lda #1
    rts
@off:
    stz ride
@no:
    lda #0
    rts
.endproc

; --- ENEMIES (stage 1: Chibibo, SML type $00) ---------------------------------
; spawn_check: fire spawn-table entries whose fire_cam <= cam_x. An enemy enters at the
; screen's right edge (world x = cam + 192, the streaming margin), at the entry's o_y.
.proc spawn_check
    lda spawn_idx
    asl
    asl
    clc
    adc spawn_idx                ; entry offset = idx*5 (list <= 51 entries)
    tay
    lda spawn_tab+1,y          ; fire_cam hi ($FF = end of table)
    cmp #$FF
    beq @done
    cmp cam_x+1
    bcc @fire
    bne @done
    lda spawn_tab,y
    cmp cam_x
    bcs @done                    ; STRICT: fires only once the camera passes the column
@fire:
    lda spawn_tab+3,y          ; type: Chibibo $00, Nokobon $04, Fly $0E, Bunbun $42,
    beq @chib                  ; stone $36, moving platforms $0A/$0B
    cmp #$04
    bne :+
    jsr spawn_noko
    bra @skip
:   cmp #$0E
    bne :+
    jsr spawn_fly
    bra @skip
:   cmp #$42
    bne :+
    jsr spawn_bunbun
    bra @skip
:   cmp #$36
    bne :+
    jsr spawn_stone
    bra @skip
:   cmp #$0A
    bne :+
    jsr spawn_platv
    bra @skip
:   cmp #$0B
    bne :+
    jsr spawn_plath
    bra @skip
:   cmp #$02                     ; 1-3 kit (RAM overlay): $02 spider, $0C spiky ball,
    beq @l3                      ; $3F Gao, $08 moai flyer
    cmp #$0C
    beq @l3
    cmp #$3F
    beq @l3
    cmp #$08
    beq @l3
@unk:
    ldx cur_level                ; W2+: EVERY unknown type goes to the overlay's
    cpx #3                       ; spawn entry (it consumes what it doesn't know);
    bcs @ovl                     ; W1 surface: consume (C is clear on this path --
    bra @skip                    ; a set carry would jam the spawner)
@l3:
    ldx cur_level                ; kit types ($02/$0C/$3F/$08): levels 2+ have a
    cpx #2                       ; resident overlay; on 0/1 the window is stale
    bcc @unk
@ovl:
    jsr ovl_spawn
    bra @skip
@chib:
    jsr spawn_chib
@skip:
    bcs @done                    ; pool full: DON'T consume — retry this entry next
    inc spawn_idx                ; frame (spawn x is fire-based so it still lands
    jmp spawn_check              ; right; the GB dodges this with 10 slots). Several
@done:                           ; entries can share a fire column.
    rts
.endproc

.proc obj_alloc_typed            ; A = type -> C=0: X = fresh slot with the type
    sta tmpL2                    ; stored; C=1: pool full. Preserves Y.
    phy
    jsr find_free_obj
    ply
    bcs @rts
    lda tmpL2
    sta o_type,x
@rts:
    rts
.endproc
; --- overlay ABI: the engine reaches window code ($1500) through RAM vectors,
; so DIFFERENT overlays (the 1-3 kit / the W2 kit) can back the same calls.
ovl_spawn:  jmp (ovl_vec+0)      ; A = GB type, Y = spawn entry (C=0 spawned/consumed)
ovl_update: jmp (ovl_vec+2)      ; X = slot (types >= OBJ_GIFT)
ovl_width:  jmp (ovl_vec+10)     ; A = erase width for kit types
.proc ovl_bind                   ; call RIGHT AFTER load_level (level bank mapped):
    lda cur_level                ; bind the window vectors for this level's overlay
    cmp #3
    bcs @w2
    ldx #11                      ; W1: the kit's addresses (staged at boot; levels
                                 ; 0/1 never route through them -- harmless)
:   lda l3vec_ram,x
    sta ovl_vec,x
    dex
    bpl :-
    rts
@w2:
    lda hdr_buf+20               ; W2+: header +20/21 = the blob's bank address
    sta lvl_ptr
    lda hdr_buf+21
    sta lvl_ptr+1
    jsr copy_win8                ; blob -> $1500 (8 pages; bank already mapped)
    jmp $1500                    ; the blob's init entry binds its own vectors
@rts:
    rts
.endproc


.proc spawn_noko
    lda #OBJ_NOKO                ; walks left, same measured speed engine as the Chibibo
    .byte $2C                    ; BIT abs: swallow the next LDA
.endproc
.proc spawn_chib
    lda #OBJ_CHIB
.endproc                         ; falls into the shared walker core
.assert spawn_chib = spawn_noko+3, error, "noko->chib fall-through split!"
.assert spawn_edge_walker = spawn_chib+2, error, "chib->walker fall-through split!"
.proc spawn_edge_walker          ; A = type; Y = table byte offset. Left-walker
    jsr obj_alloc_typed          ; entering at world cam+180 (GB enters at OAM 188)
    bcs @full
    lda cam_x
    clc
    adc #180
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda spawn_tab+2,y          ; feet line from the table
    sta o_y,x
    lda #$FF                     ; walks LEFT (toward Mario), 1px/update
    sta o_vx,x
    stz o_st,x
    stz o_tmr,x
    clc                          ; C=0: spawned
@full:
    rts
.endproc

.proc spawn_fly
    lda #OBJ_FLY
    jsr spawn_edge_walker
    bcs @full
    lda o_xl,x                   ; trace: enters at OAM 199 = world cam+191
    clc
    adc #11
    sta o_xl,x
    bcc :+
    inc o_xh,x
:   lda #FLY_SIT                 ; state 0 (sitting) already set by the core
    sta o_tmr,x
    clc
@full:
    rts
.endproc

.segment "LEVELS"                ; the 1-2 entity pack lives in the banked common
                                 ; prefix (FIXED is full); identical in every bank
; spawn_tabx: slot X gets its world x from spawn entry Y — the GB spawner rule
; ($249B): world x = fire_cam + 192 + x_off*4 (matches both traced 1-1 platforms).
.proc spawn_tabx
    lda spawn_tab,y
    clc
    adc #192
    sta o_xl,x
    lda spawn_tab+1,y
    adc #0
    sta o_xh,x
    lda spawn_tab+4,y
    asl
    asl
    clc
    adc o_xl,x
    sta o_xl,x
    bcc :+
    inc o_xh,x
:   rts
.endproc

.proc spawn_platv                ; vertical: spawns at the patrol TOP, heads down
    lda #OBJ_PLATV
    bra spawn_plat
.endproc
.proc spawn_plath                ; horizontal: spawns at the RIGHT bound, heads left
    lda #OBJ_PLATH
    ; falls through
.endproc
.proc spawn_plat                 ; A = platform type; patrol origin from entry Y
    jsr obj_alloc_typed
    bcs @full
    jsr spawn_tabx
    lda spawn_tab+2,y            ; o_y = bin oy + 16 (platform top+8 convention; this
    clc                          ; reproduces 1-1's traced o_y bounds 64..124 exactly)
    adc #16
    sta o_y,x
    stz o_st,x                   ; offset 0 = at the spawn point,
    stz o_vy,x                   ; heading away (down / left)
    clc                          ; C=0: spawned
@full:
    rts
.endproc

.segment "L12"
.proc spawn_bunbun               ; the bee flies level at its spawn height
    lda #OBJ_BUNBUN
    jsr obj_alloc_typed
    bcs @full
    jsr spawn_tabx
    lda spawn_tab+2,y
    sta o_y,x
    lda #$FF                     ; faces Mario ONCE at spawn = always left (it enters
    sta o_vx,x                   ; at the right edge) and never turns
    stz o_tmr,x                  ; cycle tick
    stz o_st,x
    clc                          ; C=0: spawned
@full:
    rts
.endproc
.segment "LEVELS"


; p1_init / p1_next: rotated pass-1 slot walk. The scan origin advances once per
; frame so the redraw budget (dirty_bud) starves no slot: an over-budget mover just
; keeps last frame's image (<= a few px of lag under extreme load, instead of the
; whole frame missing its deadline = the visible flicker).
.proc p1_init
    lda rot1
    ina
    cmp #OBJ_MAX
    bcc :+
    lda #0
:   sta rot1
    sta oi
    stz p1c
    lda #3                       ; movers redrawn per frame, at most (Mario exempt);
    ldy shift_px                 ; the shift frame already carries blank+stream+fold —
    beq :+                       ; take 1 mover and push the rest to the pend frames,
    lda #1                       ; which run at 60-75% (a 30Hz mover deferred once =
:   sta dirty_bud                ; 2px of lag for one frame, invisible)
    rts
.endproc
.proc p1_next                    ; C=1 when all slots visited; else oi = next slot
    inc p1c
    lda p1c
    cmp #OBJ_MAX
    bcs @done
    lda oi
    ina
    cmp #OBJ_MAX
    bcc :+
    lda #0
:   sta oi
    clc
    rts
@done:
    sec
    rts
.endproc

; mark_slot_y: overlap propagation hit on slot Y. If its drawn state truly matches
; (same position AND anim token) it can redraw WITHOUT an erase — the draw repaints
; its exact old pixels. A budget-DEFERRED mover is 'clean' but HAS moved: it gets a
; FULL dirty (erase + draw) or its old image would linger (debris-crumb bug).
.proc mark_slot_y
    lda o_nvx,y
    cmp o_pvx,y
    bne @full
    lda o_ndy,y
    cmp o_pvy,y
    bne @full
    phx
    tya
    tax
    jsr anim_token
    plx
    cmp o_pfr,y
    bne @full
    lda o_nfl,y                  ; truly unmoved: draw-only refresh
    ora #4
    bra @st
@full:
    lda o_nfl,y                  ; moved while deferred (or mid anim flip):
    ora #1                       ; full erase + draw
@st:
    sta o_nfl,y
    rts
.endproc



; bonk_kill_above: a hopping block bonk (?-block/hidden/brick/multi-coin) kills any
; enemy standing ON the bonked cell (feet_col/mrow): dead-flip corpse + the class
; kill score (user-verified vs GB — the classic block-bounce kill, "100" popup for
; walkers). Enemy feet = o_y+16, so "on the block" = (o_y>>3)+2 == mrow.
.proc bonk_kill_above
    stz oi2
@loop:
    ldx oi2
    lda o_type,x
    cmp #OBJ_CHIB
    beq @cand
    cmp #OBJ_NOKO
    beq @cand
    cmp #OBJ_FLY
    beq @cand
    cmp #OBJ_BUNBUN
    beq @cand
    cmp #OBJ_GIFT                 ; 1-3 kit: victim handling via the overlay
    bcs @cand
@next:
    inc oi2
    lda oi2
    cmp #OBJ_MAX
    bne @loop
    rts
@cand:
    lda o_y,x                    ; standing on the bonked cell? the walkers' own ground
    lsr                          ; rule: o_y>>3 == the solid row under their feet
    lsr
    lsr
    cmp mrow
    bne @next
    lda feet_col                 ; cell centre = col*8 + 4 (16-bit)
    sta tmpL2
    lda feet_col+1
    sta tmpH2
    asl tmpL2
    rol tmpH2
    asl tmpL2
    rol tmpH2
    asl tmpL2
    rol tmpH2
    lda tmpL2
    clc
    adc #4
    sta tmpL2
    bcc :+
    inc tmpH2
:   lda o_xl,x                   ; |enemy centre (o_x+4) - cell centre| < 10
    clc
    adc #4
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    sec
    lda tmpL2
    sbc tmpL3
    sta tmpL3
    lda tmpH2
    sbc tmpH3
    bpl @pos
    eor #$FF
    tay
    sec
    lda #0
    sbc tmpL3
    sta tmpL3
    tya
@pos:
    bne @next                    ; |dx| >= 256
    lda tmpL3
    cmp #10
    bcs @next
    lda o_type,x
    cmp #OBJ_GIFT
    bcc :+
    jsr l3_bonk                  ; 1-3 kit: per-type bonk outcome
    jmp @next
:
    lda #$01                     ; kill value by class (star/ball convention):
    sta tmpH3                    ; walkers 100, fly 400, bunbun 800
    lda o_type,x
    cmp #OBJ_FLY
    bne :+
    lda #$04
    sta tmpH3
:   cmp #OBJ_BUNBUN
    bne :+
    lda #$08
    sta tmpH3
:   lda o_vx,x                   ; the corpse keeps its walk direction
    bmi :+
    lda #1
    bra :++
:   lda #$FF
:   jsr kill_flip
    lda tmpH3
    jsr award_kill
    jmp @next                    ; keep scanning: two enemies can share a block
.endproc

; upd_bunbun: the slot-captured cycle — fly 1px/f toward Mario 40f (wings flap per
; 8f), hover 33f dropping an arrow at tick 57, loop re-facing Mario each cycle.
.segment "L12"
.proc upd_bunbun
    ldx oi
    lda o_xl,x                   ; off-screen-left cull (walker rule)
    clc
    adc #20
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    lda tmpH3
    cmp cam_x+1
    bcc @cull
    bne @alive
    lda tmpL3
    cmp cam_x
    bcs @alive
@cull:
    stz o_type,x
    rts
@alive:
    lda o_tmr,x                  ; direction is FIXED at spawn (user-verified vs GB:
    cmp #BUN_FLY_T               ; the bee never turns to chase — it drops its arrows
                                 ; and leaves the screen)
    bcs @hover
    txa                          ; move 2px every OTHER frame (slot-staggered): same
    eor frame_count              ; 1px/f trajectory, but the screen position changes
    lsr                          ; at 30Hz -> the dirty-skip halves the sprite
    bcs @tick                    ; blit/erase load (the 2-bee flicker fix)
    lda o_vx,x
    bmi @ml
    lda o_xl,x
    clc
    adc #2
    sta o_xl,x
    bcc @tick
    inc o_xh,x
    bra @tick
@ml:
    lda o_xl,x
    sec
    sbc #2
    sta o_xl,x
    bcs @tick
    dec o_xh,x
    bra @tick
@hover:
    cmp #BUN_DROP_T
    bne @tick
    jsr bunbun_drop
@tick:
    ldx oi
    inc o_tmr,x
    lda o_tmr,x
    cmp #BUN_FLY_T+BUN_HOV_T
    bcc :+
    stz o_tmr,x
:   jmp enemy_contact
.endproc
.segment "LEVELS"


; upd_arrow: 1px/frame straight down, x frozen, straight through terrain, gone off
; the bottom. ANY contact hurts — no stomp ($3186 row for $45: no morph on top contact).
.segment "L12"
.proc bunbun_drop                ; release the arrow at the bee's position
    jsr find_free_obj
    bcs @full
    ldy oi
    lda #OBJ_ARROW
    sta o_type,x
    lda o_xl,y
    sta o_xl,x
    lda o_xh,y
    sta o_xh,x
    lda o_y,y
    ina                          ; capture: the arrow appears 1px below the flight line
    sta o_y,x
    tya                          ; the arrow inherits the BEE's motion parity (o_st):
    and #1                       ; the pair moves on the same frames, so on off-frames
    sta o_st,x                   ; neither seeds the overlap-dirty chain
@full:
    rts
.endproc
.segment "LEVELS"

.segment "L12"
.proc upd_arrow
    ldx oi
    lda o_st,x                   ; fall 2px every OTHER frame on the BEE's parity
    eor frame_count              ; (30Hz motion, 1px/f average — see the bee note)
    lsr
    bcs @coll
    lda o_y,x
    ina
    ina
    sta o_y,x
    cmp #168
    bcc @coll
    stz o_type,x
    rts
@coll:
    jsr mario_dx                 ; |mario - arrow| (shared geometry)
@pdx:
    lda tmpH3
    bne @done
    lda tmpL3
    cmp #8                       ; the arrow is skinny
    bcs @done
    lda spr_y
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #14
    bcs @done
    lda mario_starT              ; star: the arrow just dies (+100, class-0 like walkers)
    beq @hurt
    stz o_type,x
    lda #$01
    jmp award_kill
@hurt:
    jmp hurt_mario
@done:
    rts
.endproc
.segment "LEVELS"

.segment "CODE"

.proc spawn_stone                ; stepping stone: static until ridden
    phy
    jsr find_free_obj
    ply
    bcs @full
    lda #OBJ_STONE
    sta o_type,x
    jsr spawn_tabx
    lda spawn_tab+2,y
    sta o_y,x
    stz o_st,x                   ; 0 = untriggered (o_tmr set at trigger; o_vx unused)
    clc                          ; C=0: spawned
@full:
    rts
.endproc

; upd_stone: static and rideable until Mario lands on it; then one script-step beat
; and a 1px/frame drop, carrying the rider ($36 -> $37, script $399D).
.proc upd_stone
    ldx oi
    lda o_st,x
    bne @falling
    lda ride                     ; the landing itself is detected by plat_land
    beq @done
    dea
    cmp oi
    bne @done
    lda #1
    sta o_st,x
    lda #STONE_BEAT
    sta o_tmr,x
@done:
    rts
@falling:
    lda o_tmr,x
    beq @drop
    dec o_tmr,x
    rts
@drop:
    inc o_y,x
    jsr carry_y_dn
    ldx oi
    lda o_y,x
    cmp #168                     ; off the bottom (the rider keeps falling — pit rules)
    bcc :+
    stz o_type,x
:   rts
.endproc

; upd_chib: the Chibibo walker -- mushroom-style movement (every other frame) + COMBAT.
; RE ($08C7): stomp iff Mario's y is 4+ px above the enemy's (within the x window);
; stomp -> squash + fixed bounce + "100"; side -> hurt (big: shrink, small: death).
.proc upd_chib
    ldx oi                       ; walked off-screen-left? despawn (original: screen-exit
    lda o_xl,x                   ; culls the slot -- keeping them alive exhausted slots and
    clc                          ; even silently ate multi-coin spawn requests)
    adc #20
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    lda tmpH3
    cmp cam_x+1
    bcc @cull
    bne :+
    lda tmpL3
    cmp cam_x
    bcs :+
@cull:
    stz o_type,x
    rts
:   lda frame_count
    lsr
    bcs :+
    jmp @combat                  ; movement at 30Hz; combat EVERY frame
:   ldx oi
    lda o_xl,x                   ; feet_col = (o_x + 4) >> 3
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
    bne @grounded
    ldx oi                       ; airborne: fall 2px/update
    lda o_y,x
    clc
    adc #2
    sta o_y,x
    jmp @combat
@grounded:
    ldx oi                       ; snap + walk with wall reversal (mushroom pattern)
    lda mrow
    asl
    asl
    asl
    sta o_y,x
    dec mrow                     ; BURIED? (body row solid too -- e.g. a spawn inside raised
    jsr read_solid               ; terrain): rise one row per update until clear, don't walk
    beq @clear
    ldx oi
    lda o_y,x
    sec
    sbc #8
    sta o_y,x
    jmp @combat
@clear:
    ldx oi
    lda o_vx,x
    bmi @wleft
    lda o_xl,x
    clc
    adc #8
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    bra @wchk
@wleft:
    lda o_xl,x
    sec
    sbc #1
    sta feet_col
    lda o_xh,x
    sbc #0
    sta feet_col+1
@wchk:
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    lsr feet_col+1
    ror feet_col
    ldx oi
    lda o_y,x
    lsr
    lsr
    lsr
    dea                          ; body row (one above the feet)
    sta mrow
    jsr read_solid
    beq @wmove
    ldx oi                       ; wall -> reverse
    lda o_vx,x
    eor #$FF
    ina
    sta o_vx,x
    bra @combat
@wmove:
    ldx oi
    lda o_type,x                 ; the Nokobon TURNS AT LEDGES (user-verified vs 1-2 in the
    cmp #OBJ_NOKO                ; original: it patrols platforms without falling off --
    bne @wm2                     ; phys byte0 bit0, $07 vs the Chibibo's $06)
    lda o_y,x                    ; floor row in the AHEAD column (feet_col still holds it)
    lsr
    lsr
    lsr
    sta mrow
    jsr read_solid
    bne @wm2                     ; ground ahead -> keep walking
    ldx oi                       ; edge -> reverse
    lda o_vx,x
    eor #$FF
    ina
    sta o_vx,x
    bra @combat
@wm2:
    ldx oi                       ; ORIGINAL walk speed = 1px per 3 FRAMES (trace: 24px/72f
    inc o_st,x                   ; on the ground) = 2 moves per 3 object-updates
    lda o_st,x
    cmp #3
    bcc @domove
    stz o_st,x
    bra @combat
@domove:
    jsr mush_xmove
@combat:
    jmp enemy_contact
.endproc

; upd_fly: the Fly (trace-derived): sits ~55f buzzing, then a 48-frame hop toward
; Mario -- 15px arc (y-deltas every 3rd frame from fly_arc), 1px per 2 frames of
; drift in the hop direction (chosen at hop start, tracking Mario).
.proc upd_fly
    ldx oi
    lda o_xl,x                   ; off-screen-left cull, like the walkers
    clc
    adc #20
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    lda tmpH3
    cmp cam_x+1
    bcc @cull
    bne :+
    lda tmpL3
    cmp cam_x
    bcs :+
@cull:
    stz o_type,x
    rts
:   lda o_st,x
    bne @hop
    dec o_tmr,x                  ; --- sitting: count down to the next hop ---
    bne @contact
    lda #1                       ; launch: pick the direction toward Mario NOW (F0 60)
    sta o_st,x
    stz o_tmr,x                  ; hop phase 0..47
    lda cam_x                    ; mario world x
    clc
    adc spr_x
    sta tmpL2
    lda cam_x+1
    adc #0
    sta tmpH2
    lda tmpL2                    ; enemy - mario: borrow -> mario is right of it
    cmp o_xl,x
    lda tmpH2
    sbc o_xh,x
    bcc @faceL
    lda #1                       ; hop right
    sta o_vx,x
    bra @contact
@faceL:
    lda #$FF                     ; hop left
    sta o_vx,x
    bra @contact
@hop:
    lda o_tmr,x                  ; --- hopping: phase 0..47 ---
    cmp #48
    bcc :+
    stz o_st,x                   ; landed: back to sitting
    lda #FLY_SIT
    sta o_tmr,x
    bra @contact
:   tay
    and #1                       ; x drift: 1px every 2 frames, in the hop direction
    bne @ystep
    lda o_vx,x
    bmi @xl
    lda o_xl,x
    clc
    adc #1
    sta o_xl,x
    bcc @ystep
    inc o_xh,x
    bra @ystep
@xl:
    lda o_xl,x
    sec
    sbc #1
    sta o_xl,x
    bcs @ystep
    dec o_xh,x
@ystep:
    lda fly_dy,y                 ; per-frame y delta (the 15px trace arc, 0 between steps)
    beq @nody
    clc
    adc o_y,x
    sta o_y,x
@nody:
    inc o_tmr,x
@contact:
    jmp enemy_contact

; trace f2436-2481: rise 4,4,2,2,1,1,1 / hover (+1 drift) / fall 1,1,2,2,4,4 -- one
; step every 3rd frame, 48 frames total, deltas sum to zero.
fly_dy:
    .byte 256-4,0,0, 256-4,0,0, 256-2,0,0, 256-2,0,0, 256-1,0,0, 256-1,0,0, 256-1,0,0
    .byte 0,0,0, 1,0,0, 0,0,0
    .byte 1,0,0, 1,0,0, 2,0,0, 2,0,0, 4,0,0, 4,0,0
.endproc

; enemy_contact: shared enemy-vs-Mario resolution (walkers + the fly): bottom cull,
; overlap test, star kill, position-rule stomp (result branched by type), side hurt.
.segment "LEVELS"                
.proc enemy_contact
    ldx oi
    lda o_y,x                    ; cull once fallen off the bottom
    cmp #160
    bcc :+
    cmp #240
    bcs :+
    stz o_type,x
    rts
:   jsr mario_dx
    lda tmpH3
    beq :+
    jmp @done
:   lda tmpL3
    cmp #10
    bcc :+
    jmp @done
:
    lda spr_y                    ; y overlap: |spr_y - o_y| < 14 (his feet vs its feet)
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #14
    bcc :+
    jmp @done
:   lda mario_starT              ; star -> instant kill
    beq :+
    jmp @kill
:   lda spr_y                    ; STOMP TEST (RE $08C7): Mario at least 4px above
    clc
    adc #4
    cmp o_y,x
    bcc @stomp
    jmp hurt_mario               ; side contact
@stomp:
    ldx oi
    lda #$01                     ; base value code (RE $0A29 by phys byte2>>6):
    sta tmpH2                    ; walkers class 0 = 100
    lda o_type,x
    cmp #OBJ_NOKO
    beq @sbomb
    cmp #OBJ_FLY
    beq @sfly
    cmp #OBJ_BUNBUN
    beq @sbun
    lda #OBJ_SQUASH              ; Chibibo -> squashed corpse ($91)
    sta o_type,x
    lda #CHIB_TB
    sta o_vx,x
    lda #32
    sta o_tmr,x
    stz o_st,x
    bra @sboth
@sbun:
    lda #$08                     ; Bunbun class 2 = 800 (phys $3375 byte2>>6)
    sta tmpH2
    lda #OBJ_SQUASH              ; -> the flat bee pair $C8+$C9 (param $34), then gone
    sta o_type,x
    lda #BUN_SQ
    sta o_vx,x
    lda #32
    sta o_tmr,x
    lda #1                       ; pair flag: two tiles side by side
    sta o_st,x
    bra @sboth
@sfly:
    lda #$04                     ; fly class 1 = 400
    sta tmpH2
    lda #OBJ_SQUASH              ; Fly -> flattened 2-tile corpse ($A8+$A9)
    sta o_type,x
    lda #FLY_SQ
    sta o_vx,x
    lda #32
    sta o_tmr,x
    lda #1                       ; pair flag: squash draws two tiles
    sta o_st,x
    bra @sboth
@sbomb:
    lda #OBJ_BOMB                ; Nokobon -> the TICKING BOMB (RE $3186: $04 -> $05)
    sta o_type,x
    lda #BOMB_FUSE
    sta o_tmr,x
    stz o_vx,x
@sboth:
    lda #1                       ; Mario's fixed stomp bounce: a short hop
    sta jump_state
    lda #14
    sta arc_idx
    stz fall_v
    stz ride
    lda tmpH2                    ; value code saved at @stomp entry (fly 400, walkers 100)
    jsr award_stomp              ; combo-chained score + the right popup tag
@done:
    rts
@kill:
    ldx oi                       ; star kill: the DEAD-FLIP corpse (captured GB type
    lda #$01                     ; $0D: Y-flipped, 7px hop then falls off-screen,
    sta tmpH2                    ; 1px/f drift away from Mario)
    lda o_type,x
    cmp #OBJ_FLY
    bne :+
    lda #$04                     ; fly class = 400
    sta tmpH2
:   cmp #OBJ_BUNBUN
    bne :+
    lda #$08                     ; bunbun class = 800
    sta tmpH2
:   lda #1                       ; thrown away from Mario: he walks into it, so the
    ldy mario_facing             ; drift follows his facing (right -> thrown right)
    beq :+
    lda #$FF
:   jsr kill_flip
    lda tmpH2                    ; base value code, no chain on kills
    jmp award_kill
.endproc

.segment "CODE"

; award_stomp / award_kill: score + popup from the VALUE CODE (RE $0A29 class table
; + the bank2 popup engine's code->tiles/points map). A = base code ($01/$04/$08/$50).
; Stomps run the COMBO chain ($ff9c/$ff9d): within the 50-frame window the code is
; shifted left by the chain count (max 3): 100-200-400-800, fly 400-800-1000-2000.
; Kills (ball/star) award the base code only.
.proc award_stomp
    pha
    lda #SFX_DFE0_03             ; stomp/kill chirp ($dfe0=$03 per the stomp path $090D)
    jsr sfx_play
    pla
    pha
    lda combo_t
    bne @chain
    stz combo_n                  ; window expired: chain resets
    bra @go
@chain:
    lda combo_n
    cmp #3
    bcs @go
    inc combo_n
@go:
    lda #50
    sta combo_t
    pla
    cmp #$50                     ; 5000 never doubles (cp $50 in the original)
    bcs award_kill
    ldy combo_n
    beq award_kill
:   asl
    dey
    bne :-
    ; fall through
.endproc
.proc award_kill                 ; popup at Mario (the pre-boss callers)
    pha
    jsr mario_anchor
    pla
.endproc                         ; fall through
.proc award_kill_at              ; popup at tmpL2/H2/tmpH3 (the victim)
    pha
    tax                          ; add the code as BCD hundreds (the original's amount
    lda #$00                     ; chain is literally D=code, E=00)
    jsr add_score
    pla
    ; code -> popup tiles: left $59+step, right $58; >= $10 -> left $59+step, right $57
    ldy #$58
    cmp #$10
    bcc :+
    ldy #$57
    lsr                          ; $10/$20/$40/$50/$80 -> $01/$02/$04/$05/$08
    lsr
    lsr
    lsr
:   tax
    lda @lt-1,x                  ; left tile by code: $01->$59 .. $08->$5D
    jmp spawn_popup_at           ; A = left tile, Y = right tile
@lt: .byte $59,$5A,$5A,$5B,$5C,$5C,$5C,$5D
.endproc

; hurt_mario: shared side-contact/explosion damage (RE: big -> shrink flash + powers
; lost + mercy blink; small -> death). Respects mercy/grow/shrink windows.
.proc hurt_mario
    lda hurt_inv
    ora mario_grow
    ora mario_shrink
    bne @no
    lda mario_big
    beq @die
    lda #SFX_DFE0_06             ; the shrink sound (user-ID'd: big Mario hit)
    jsr sfx_play
    lda #$50
    sta mario_shrink
    stz mario_duck
    rts
@die:
    jsr mus_stop                 ; the jingle REPLACES the music
    lda #SFX_DFE8_02             ; the death jingle ($dfe8=$02, RE $09F1)
    jsr sfx_play
    lda #1                       ; enemy deaths play the HOP (RE states $03/$04); pit
    sta death_anim               ; deaths keep the direct fall path (state $01)
    stz mario_duck
    stz ride
@no:
    rts
.endproc

; death_frame: one frame of the death hop (RE State_04 @ $0BC9): y += death_curve[i]
; (38 eased entries, ~21px rise), then +2/frame after the $7F terminator, until the
; sprite leaves the screen -> the normal death pause + checkpoint respawn.
.proc death_frame
    ldx death_anim
    lda death_curve-1,x
    cmp #$7F
    beq @fall
    clc
    adc spr_y
    sta spr_y
    inc death_anim
    rts
@fall:
    lda spr_y
    clc
    adc #2
    sta spr_y
    cmp #168
    bcc :+
    stz death_anim
    lda timeup
    beq @resp
    stz timeup
    jsr timeup_strip             ; " TIME UP " bottom-right for 160 frames (harness-exact)
@resp:
    jmp do_respawn
:   rts
.endproc

; timeup_strip: the state-$3B/$3C sequence -- the 9 tiles from ROM $1D14 (" TIME UP ")
; in the PAUSE window position (bottom-right, screen-anchored), held 160 frames
; ($ffa6=$A0). The respawn's full re-render cleans it up.
.proc timeup_strip
    lda scroll_s
    lsr
    lsr
    clc
    adc #22                      ; screen x 88 (the pause strip's spot), byte-granular
    sta tmpH3
    stz b_i
@loop:
    lda b_i
    asl
    clc
    adc tmpH3
    sta dcol
    lda #144
    sta dy
    jsr set_dst
    ldx b_i
    lda @txt,x
    jsr get_tile_src
    jsr blit_tile
    inc b_i
    lda b_i
    cmp #9
    bne @loop
    lda #160
    sta tmpL3
@wait:
    lda frame_flag
    beq @wait
    stz frame_flag
    jsr sfx_tick
    jsr mus_tick
    dec tmpL3
    bne @wait
    rts
@txt: .byte $2C,$1D,$12,$16,$0E,$2C,$1E,$19,$2C   ; the exact $1D14 bytes: " TIME UP "
.endproc

.segment "LEVELS"
death_curve:                     ; ROM $0C19 verbatim (signed y deltas + $7F end)
    .byte $FE,$FE,$FE,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF
    .byte $00,$FF,$00,$00,$FF,$00,$00,$00,$01,$00,$00,$01,$00,$01,$01,$01
    .byte $01,$01,$01,$01,$01,$01,$7F
.segment "CODE"


; upd_bomb: the stomped Nokobon's shell ticks (~2.4s, blinking) then explodes.
; Touching the ticking bomb is HARMLESS (RE: its $3186 row is all zeros).
.proc upd_bomb
    ldx oi
    dec o_tmr,x
    bne @tick
    lda #SFX_DFF8_01             ; the bang (the explosion script's F9 01)
    jsr sfx_play
    ldx oi
    lda #OBJ_BOOM                ; fuse out -> the explosion (type $46), 16px wide:
    sta o_type,x                 ; shift left 4px so the cloud is centred on the bomb
    lda #BOOM_LIFE
    sta o_tmr,x
    lda o_xl,x
    sec
    sbc #4
    sta o_xl,x
    bcs @tick
    dec o_xh,x
@tick:
    rts
.endproc

; upd_boom: the explosion -- contact HURTS ($3186[$46] byte2=$FF), then it burns out.
.proc upd_boom
    ldx oi
    dec o_tmr,x
    bne :+
    stz o_type,x
    rts
:   lda cam_x                    ; |mario centre - cloud centre| < 14 ?
    clc
    adc spr_x
    sta tmpL2
    lda cam_x+1
    adc #0
    sta tmpH2
    lda tmpL2
    clc
    adc #8
    sta tmpL2
    bcc :+
    inc tmpH2
:   lda o_xl,x
    clc
    adc #8
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    sec
    lda tmpL2
    sbc tmpL3
    sta tmpL3
    lda tmpH2
    sbc tmpH3
    sta tmpH3
    bpl :+
    sec
    lda #0
    sbc tmpL3
    sta tmpL3
    lda #0
    sbc tmpH3
    sta tmpH3
:   lda tmpH3
    bne @no
    lda tmpL3
    cmp #14
    bcs @no
    lda spr_y                    ; |mario feet - cloud line| < 14
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #14
    bcs @no
    jmp hurt_mario
@no:
    rts
.endproc

; upd_squash: a squashed corpse -- sits still, then vanishes.
.proc upd_squash
    ldx oi
    lda o_xl,x                   ; gravity: fall 1px/f until solid ground under the
    clc                          ; feet (a fly shot mid-hop drops flat, GB $0F)
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
    bne :+
    ldx oi
    inc o_y,x
    rts
:   ldx oi
    dec o_tmr,x
    bne :+
    lda o_vx,x                   ; a stomped fly/bee thumps as the flat frames end
    cmp #FLY_SQ                  ; (GB: the $0F->$15 / $43->$44 morph plays F9 03)
    beq @thump
    cmp #BUN_SQ
    bne @gone
@thump:
    lda #SFX_DFF8_03
    jsr sfx_play
    ldx oi
@gone:
    stz o_type,x
:   rts
.endproc

; title_screen: the original's title, dumped at build time by tools/extract_title.py
; (PyBoy boots the user's ROM and captures the rendered tilemap + tiles). 18 GB rows
; centered on the SV's 20 (rows 1-18). Static; exits on Start.
.segment "TITLE0"               ; the title runs ONLY with bank 0 mapped (code + data)
.proc title_screen
    lda #<title_map              ; 16-bit walk over the 360-byte map (row*20+col
    sta feet_col                 ; overflowed 8 bits past row 12 -> doubled image)
    lda #>title_map
    sta feet_col+1
    stz tmpL3                    ; row 0..17
@row:
    stz tmpH3                    ; col 0..19
@col:
    lda (feet_col)               ; packed tile index
    sta tmpH
    inc feet_col
    bne :+
    inc feet_col+1
:
    stz src_ptr+1                ; src = title_tiles + idx*16
    lda tmpH
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    clc
    adc #<title_tiles
    sta src_ptr
    lda src_ptr+1
    adc #>title_tiles
    sta src_ptr+1
    lda tmpH3                    ; dst: dcol = col*2, dy = row*8 -- flush to the
    asl                          ; top like the GB (the free rows land at the
    sta dcol                     ; BOTTOM, under the level-select indicator)
    lda tmpL3
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr blit_tile
    inc tmpH3
    lda tmpH3
    cmp #20
    bne @col
    inc tmpL3
    lda tmpL3
    cmp #18
    bne @row
    stz cur_level                ; default = 1-1; Select cycles (level-select debug)
    jsr title_lvl_show
@wait:
    lda frame_flag               ; hold until Start is pressed
    beq @wait
    stz frame_flag
    jsr sfx_tick                 ; the sound test needs the player running
    jsr read_input
    lda pad_pressed              ; LEVEL SELECT (debug): Select cycles the start level;
    and #GB_SELECT               ; the "1-1"-style pick shows at the top right.
    beq :+
    lda cur_level
    ina
    cmp #NUM_LEVELS
    bcc @lsel
    lda #0
@lsel:
    sta cur_level
    jsr title_lvl_show
:   lda pad_pressed              ; SOUND TEST: B cycles the SFX id, A replays it.
    and #GB_B                    ; The id shows as two digits in the top-left corner.
    beq :+
    inc b_i
    lda b_i
    cmp #SFX_COUNT
    bcc @playid
    stz b_i
    bra @playid
:   lda pad_pressed
    and #GB_A
    beq :+
@playid:
    lda b_i                      ; show the id (tens/ones font tiles at row 0)
    ldy #0
@tens:
    cmp #10
    bcc @ones
    sbc #10
    iny
    bra @tens
@ones:
    pha
    stz dcol
    stz dy
    phy
    jsr set_dst
    ply
    tya
    jsr get_tile_src
    jsr blit_tile
    lda #2
    sta dcol
    stz dy
    jsr set_dst
    pla
    jsr get_tile_src
    jsr blit_tile
    lda b_i
    jsr sfx_play
:   lda pad_pressed
    and #GB_START
    beq @wait
    rts
.endproc

; title_lvl_show: draw the level-select pick ("1-1".."1-3") at the title's
; BOTTOM right (user request: keep the top clean).
.proc title_lvl_show
    jsr lvl_ws
    pha                          ; stage digit
    txa                          ; world digit
    ldy #28                      ; cells at dcol 28/30/32 (cols 14-16), row 19
    jsr @put
    lda #$29                     ; the HUD font's '-'
    ldy #30
    jsr @put
    pla
    ldy #32
@put:
    pha
    sty dcol
    lda #152                     ; bottom row (the title map is 18 rows; 152-159
    sta dy                       ; is clear framebuffer below it)
    jsr set_dst
    pla
    jsr get_tile_src
    jmp blit_tile
.endproc

.segment "TITLE0"                ; bank 0 ONLY: banks 1+ overlay this range with their
                                 ; level region (title runs strictly with bank 0 mapped)
title_map:                       ; 20x18 remapped indices (build artifact, rule 5)
    .incbin "build/levels/title_map.bin"
title_tiles:                     ; the used tiles, SV-packed
    .incbin "build/gfx/title_tiles.svt"
.segment "CODE"

; ball_active: C=1 if a superball is already live (only one at a time, per the original).
; (FIXED is full; the common prefix is always mapped)
; mario_dx: tmpL3(+H3) = |mario centre - slot X's centre (o_x+4)|, 16-bit.
.segment "LEVELS"
.proc mario_dx
    lda cam_x                    ; mario centre = cam + spr_x + 8
    clc
    adc spr_x
    sta tmpL2
    lda cam_x+1
    adc #0
    sta tmpH2
    lda tmpL2
    clc
    adc #8
    sta tmpL2
    bcc :+
    inc tmpH2
:   lda o_xl,x
    clc
    adc #4
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
    sec
    lda tmpL2
    sbc tmpL3
    sta tmpL3
    lda tmpH2
    sbc tmpH3
    sta tmpH3
    bpl @pdx
    sec
    lda #0
    sbc tmpL3
    sta tmpL3
    lda #0
    sbc tmpH3
    sta tmpH3
@pdx:
    rts
.endproc
.segment "CODE"


; anim_token: A = the animation token for slot X — the dirty test redraws on a
; token change. Bees flap on a SLOT-STAGGERED 8-frame phase (so two bees never
; force a same-frame redraw wave); arrows/stones have no animation at all.
.segment "CODE"                  ; (back in FIXED: the bonus-game move freed it)
.proc anim_token
    lda o_type,x
    cmp #OBJ_GIFT
    bcc :+
    jmp (ovl_vec+4)              ; per-type tokens for the resident kit
:   cmp #OBJ_ARROW
    beq @none
    cmp #OBJ_STONE
    beq @none
    cmp #OBJ_BUNBUN
    bne @raw
    txa
    and #1
    asl
    asl
    clc
    adc frame_count
    and #8
    rts
@raw:
    lda frame_count
    and #8
    rts
@none:
    lda #0
    rts
.endproc
.segment "CODE"
.proc ball_active
    ldx #OBJ_MAX-1
:   lda o_type,x
    cmp #OBJ_BALL
    beq @yes
    dex
    bpl :-
    clc
    rts
@yes:
    sec
    rts
.endproc
.segment "CODE"
.segment "CODE"

; try_fire: B newly pressed + Superball Mario + no ball live -> fire a superball.
.proc try_fire
    lda mario_superball
    beq @no
    lda pad_pressed
    and #$02                     ; B = GB bit 1
    beq @no
    jsr ball_active
    bcs @no
    jsr spawn_ball
@no:
    rts
.endproc

; spawn_ball: launch a superball from Mario's nose, 45-deg down-and-forward. RE'd from an mGBA
; OAM trace: vx = +/-2 by facing, vy = +2 (down), tile $60.
.proc spawn_ball
    jsr find_free_obj
    bcs @full
    lda #OBJ_BALL
    sta o_type,x
    phx                          ; sfx_play clobbers X (the ball's slot)
    lda #SFX_DFE0_02             ; the superball throw (user-ID'd: id 1)
    jsr sfx_play
    plx
    lda cam_x                    ; o_x = Mario world X (cam_x + spr_x)
    clc
    adc spr_x
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda mario_facing
    bne @left
    lda o_xl,x                   ; facing right: nose +8, vx = +2
    clc
    adc #8
    sta o_xl,x
    lda o_xh,x
    adc #0
    sta o_xh,x
    lda #BALL_SPD
    sta o_vx,x
    bra @common
@left:
    lda o_xl,x                   ; facing left: nose -8, vx = -2
    sec
    sbc #8
    sta o_xl,x
    lda o_xh,x
    sbc #0
    sta o_xh,x
    lda #<(256 - BALL_SPD)       ; -2
    sta o_vx,x
@common:
    lda spr_y                    ; o_y = Mario's Y; the ball drops to the floor then bounces
    sta o_y,x
    lda #BALL_SPD                ; vy = +2 (falling)
    sta o_vy,x
    stz o_st,x
    lda #BALL_LIFE
    sta o_tmr,x
@full:
    rts
.endproc

; ball_solid: the superball's tile test -- like read_solid, but a floating coin ($f4) is
; COLLECTED and acts solid, so the ball bounces off it and keeps flying (RE: Call_000_1fd2
; queues the coin award then returns the tile through the `cp $60` solidity check).
.proc ball_solid
    jsr read_map_tile
    cmp #$F4
    beq @coin
    cmp #$60
    bcc @no
    lda #1
    rts
@no:
    lda #0
    rts
@coin:
    jsr mod_test                 ; (already-collected cells read as blank, so this is just
    bne @no                      ;  a same-frame race guard)
    jsr mod_set
    lda feet_col
    sta wcol
    lda feet_col+1
    sta wcol+1
    jsr redraw_one               ; blank the coin cell on screen
    jsr award_coin               ; +1 coin, +100, 1-up at 100
    lda #1                       ; and the cell is solid this frame -> the ball bounces
    rts
.endproc

; upd_ball (oi=slot): move 2px/frame diagonally; bounce off the floor (reverse vy up + arm a
; fixed ~20px rise budget in o_st) and off walls (reverse vx); expire on timer or off-screen.
; Runs EVERY frame -- the ball is fast (2px/frame in the trace), not the every-other object rate.
.proc upd_ball
    ldx oi
    dec o_tmr,x
    bne @move
    jmp @expire
@move:
    jsr mush_xmove               ; o_x += o_vx (sign-extended)
    ldx oi
    lda o_vx,x
    bmi @wleft
    lda o_xl,x                   ; moving right: test (o_x + 6) >> 3
    clc
    adc #6
    bra @wstore
@wleft:
    lda o_xl,x                   ; moving left: test (o_x + 1) >> 3
    clc
    adc #1
@wstore:
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
    ldx oi
    lda o_y,x
    lsr
    lsr
    lsr
    sec
    sbc #1                       ; test the wall one row ABOVE the feet, so the flat floor the
    sta mrow                     ; ball bounces on is never mistaken for a wall (the yo-yo bug)
    jsr ball_solid               ; (a coin here is collected + bounces the ball)
    beq @vert
    ldx oi                       ; wall -> reverse vx
    lda o_vx,x
    eor #$FF
    ina
    sta o_vx,x
@vert:
    ldx oi
    clc
    lda o_y,x
    adc o_vy,x
    sta o_y,x
    lda o_xl,x                   ; ball centre column = (o_x + 4) >> 3 (for floor/ceiling test)
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
    ldx oi
    lda o_vy,x
    bmi @rising
    lda o_y,x                    ; falling: solid floor at the feet row?
    lsr
    lsr
    lsr
    sta mrow
    jsr ball_solid               ; (a coin here is collected + bounces the ball up)
    beq @edge
    ldx oi                       ; floor -> snap onto it and bounce up. NO fixed height: it
    lda mrow                     ; climbs away at 45 deg until a real ceiling/wall or off-screen
    asl
    asl
    asl
    sta o_y,x
    lda #<(256 - BALL_SPD)       ; vy = -2 (up)
    sta o_vy,x
    bra @edge
@rising:
    lda o_y,x                    ; rising: solid ceiling one row above the feet?
    lsr
    lsr
    lsr
    sec
    sbc #1
    sta mrow
    jsr ball_solid               ; (a coin here is collected + bounces the ball down)
    beq @edge
    ldx oi                       ; ceiling -> bounce back down
    lda #BALL_SPD
    sta o_vy,x
@edge:
    jsr ball_hits                ; superball vs enemies (the ball vanishes on a kill)
    ldx oi
    lda o_type,x
    beq @done2
    lda o_y,x
    cmp #160
    bcs @expire
    sec
    lda o_xl,x
    sbc cam_x
    sta tmpL
    lda o_xh,x
    sbc cam_x+1
    bne @expire
    lda tmpL
    cmp #168
    bcs @expire
    rts
@expire:
    ldx oi
    stz o_type,x
@done2:
    rts
.endproc

; ball_hits: scan for an enemy overlapping the ball (slot oi): |dx|<10, |dy|<10 ->
; squash the enemy (+100 & popup) and expire the ball (SML: it vanishes on a kill).
.proc ball_hits
    stz oi2
@loop:
    ldx oi2
    lda o_type,x
    cmp #OBJ_CHIB
    beq :+
    cmp #OBJ_NOKO
    beq :+
    cmp #OBJ_FLY
    beq :+
    cmp #OBJ_BUNBUN
    beq :+
    cmp #OBJ_GAO                 ; superball-killable 1-3 types
    beq :+
    cmp #OBJ_BAT                 ; Totomesu: 5-hit HP (user-verified on GB)
    beq :+
    cmp #OBJ_SUU                 ; the pipe flower dies to the ball while POKING
    beq :+                       ; OUT (user-proven + wiki; upward variety = 100)
    jmp @next
:   ldy oi                       ; dx = |ball - enemy| (16-bit)
    lda o_xl,y
    sec
    sbc o_xl,x
    sta tmpL3
    lda o_xh,y
    sbc o_xh,x
    beq @dxok                    ; hi 0 -> non-negative small
    cmp #$FF
    beq :+
    jmp @next                    ; |dx| >= 256
:
    lda tmpL3                    ; negative: negate
    eor #$FF
    ina
    sta tmpL3
    bne @dxok
    jmp @next
@dxok:
    lda tmpL3
    cmp #10
    bcs @next2b
    ldy oi                       ; dy
    lda o_y,y
    ldx oi2
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #10
    bcc :+
@next2b:
    jmp @next
:   lda #$01                     ; value code: walkers 100
    sta tmpH2
    lda o_type,x
    cmp #OBJ_BAT
    bne :+
    jmp l3_boss_hit              ; X = the boss slot; the ball = oi
:   cmp #OBJ_SUU
    bne :+
    lda o_y,x                    ; only while poking out of the pipe (retracted =
    cmp o_vy,x                   ; head at the rim: the ball passes through)
    bcs @next2b
    sta tmpH3                    ; the +100 tag rises from the pipe (user's shot);
    jsr victim_xy                ; the kill is a morph to $FF = silent despawn
    stz o_type,x                 ; (RE $2a68: HP 0 -> table+3 = $FF for type $02)
    lda #$01                     ; upward flower = 100 (class 0; wiki confirms)
    jsr award_kill_at
    bra @ballgone
:   cmp #OBJ_GAO
    bne :+
    lda #1                       ; corpse thrown along Mario's facing
    ldy mario_facing
    beq @gk
    lda #$FF
@gk:
    jsr l3_gao_kill              ; thump + flipped corpse
    lda #$08                     ; class 2 = 800
    jsr award_kill
@ballgone:
    ldx oi
    stz o_type,x                 ; the ball expires against it
    rts
:   cmp #OBJ_BUNBUN
    bne :+
    lda #$08                     ; bunbun 800
    sta tmpH2
    bra @bkill
:   cmp #OBJ_FLY
    bne @bkill
    lda #$04                     ; fly 400
    sta tmpH2
    lda o_hp,x                   ; the fly takes TWO balls (user-verified on GB):
    bne @bkill                   ; the first just expires against it
    inc o_hp,x
    ldx oi
    stz o_type,x
    rts
@bkill:
    ldy oi                       ; drift away along the ball's flight direction
    lda o_vx,y
    bmi :+
    lda #1
    bra :++
:   lda #$FF
:   jsr kill_flip
    lda tmpH2
    jsr award_kill
    ldx oi
    stz o_type,x
    rts
@next:
    inc oi2
    lda oi2
    cmp #OBJ_MAX
    beq :+
    jmp @loop
:   rts
.endproc

.segment "LEVELS"                ; corpse machinery lives with the level data (FIXED full)
; kill_flip: X = enemy slot, A = sideways drift (+1/-1, away from the killer).
; Convert a live enemy to the dead-flip corpse (the GB's universal type $0D:
; captured star-kill: type -> $0D, kept fields, arc counter). Kind -> o_tmr.
.proc kill_flip
    sta o_vx,x
    lda o_type,x
    ldy #0                       ; kind 0 = chibibo
    cmp #OBJ_NOKO
    bne :+
    ldy #1
:   cmp #OBJ_FLY
    bne :+
    ldy #2
:   cmp #OBJ_BUNBUN
    bne :+
    ldy #3
:   tya
    sta o_tmr,x
    lda #OBJ_CORPSE
    sta o_type,x
    stz o_st,x
    cpy #2                       ; fly/bunbun kill chains ($15/$44 scripts) play the
    bcc :+                       ; F9 03 kill thump ($dff8=$03) the moment they morph
    lda #SFX_DFF8_03
    jsr sfx_play
:   rts
.endproc

; upd_corpse: the captured arc -- corpse_dy for 23 ticks, then +2/frame; x += o_vx
; every frame; despawns off the bottom. No collision with anything.
.proc upd_corpse
    ldx oi
    txa                          ; two steps every OTHER frame (slot-staggered):
    eor frame_count              ; the same captured trajectory at 30Hz screen
    lsr                          ; updates — half the redraw/erase load (a double
    bcs @skip                    ; kill was the worst measured frame)
    jsr corpse_step
    ldx oi
    lda o_type,x                 ; despawned inside step 1?
    beq @skip
    jmp corpse_step
@skip:
    rts
.endproc
.proc corpse_step
    ldx oi
    lda o_st,x
    cmp #23
    bcs @term
    jsr mush_xmove               ; sideways drift ONLY during the arc (GB: the x
    ldx oi                       ; freezes exactly when the +2/f fall begins)
    lda o_st,x
    tay
    lda corpse_dy,y
    clc
    adc o_y,x
    sta o_y,x
    inc o_st,x
    bra @clip
@term:
    lda o_y,x
    clc
    adc #2
    sta o_y,x
@clip:
    lda o_y,x
    cmp #160
    bcc :+
    stz o_type,x                 ; off the bottom -> gone
:   rts
.endproc

corpse_dy:                       ; the star-kill capture, verbatim (23 signed deltas)
    .byte $FF,$FF,$FF,$FF,$FF,$00,$FF,$00,$FF,$00,$00,$00,$00
    .byte $01,$00,$01,$00,$01,$01,$01,$01,$01,$01

; draw_tile_yflip: like draw_quad, but the tile's 8 rows are blitted bottom-up
; (the GB corpse OAM carries the Y-flip attribute).
.proc draw_tile_yflip
    txa                          ; src = chardata + X*16
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
    ldy #0                       ; flipbuf = rows 7..0 (2 bytes each)
    ldx #14
:   lda (src_ptr),y
    sta flipbuf,x
    iny
    lda (src_ptr),y
    sta flipbuf+1,x
    iny
    dex
    dex
    bpl :-
    lda #<flipbuf
    sta src_ptr
    lda #>flipbuf
    sta src_ptr+1
    jsr set_dst
    stz blit_opaque
    jsr sprite_blit_subpx
    rts
.endproc

.segment "CODE"

; spawn_coin: a coin pops straight up from the block and falls away (~24 frames).
.proc spawn_coin
    jsr find_free_evict
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
    lda #32                      ; RE (bank2 $5892): block coins are $c0-marked popups -- they
    sta o_tmr,x                  ; rise 1px EVERY frame for 32 ticks, spinning $F6/$F7/$F8
    stz o_st,x                   ; spin phase 0..3
@full:
    rts
.endproc

; update_objects: per-frame physics for every active slot.
.proc update_objects
    stz oi
@loop:
    ldx oi
    lda o_type,x
    bne :+
    jmp @next
:   cmp #OBJ_GIFT
    bcc :+
    jsr ovl_update               ; the resident kit overlay (types 22+)
    jmp @next
:   cmp #OBJ_COIN
    beq @coin
    cmp #OBJ_FLOWER
    beq @flower
    cmp #OBJ_BALL
    beq @ball
    cmp #OBJ_STAR
    beq @star
    cmp #OBJ_DEBRIS
    beq @debris
    cmp #OBJ_POPUP
    beq @popup
    cmp #OBJ_BOUNCE
    beq @bounce
    cmp #OBJ_PLATV
    beq @platv
    cmp #OBJ_PLATH
    beq @plath
    cmp #OBJ_CHIB
    beq @chib
    cmp #OBJ_NOKO
    beq @chib                    ; same walker engine (combat branches by type inside)
    cmp #OBJ_SQUASH
    beq @squash
    cmp #OBJ_CORPSE
    beq @corpse
    cmp #OBJ_BOMB
    beq @bomb
    cmp #OBJ_BOOM
    beq @boom
    cmp #OBJ_FLY
    beq @fly
    cmp #OBJ_BUNBUN
    beq @bunbun
    cmp #OBJ_ARROW
    beq @arrow
    cmp #OBJ_STONE
    beq @stone
    jsr upd_mush                 ; OBJ_MUSH and OBJ_HEART (identical walker engine)
    bra @next
@chib:
    jsr upd_chib
    bra @next
@squash:
    jsr upd_squash
    bra @next
@corpse:
    jsr upd_corpse
    bra @next
@bomb:
    jsr upd_bomb
    bra @next
@boom:
    jsr upd_boom
    bra @next
@fly:
    jsr upd_fly
    bra @next
@platv:
    jsr upd_platv
    bra @next
@plath:
    jsr upd_plath
    bra @next
@coin:
    jsr upd_coin
    bra @next
@flower:
    jsr upd_flower
    bra @next
@ball:
    jsr upd_ball
    bra @next
@star:
    jsr upd_star
    bra @next
@debris:
    jsr upd_debris
    bra @next
@popup:
    jsr upd_popup
    bra @next
@bounce:
    jsr upd_bounce
    bra @next
@bunbun:
    jsr upd_bunbun
    bra @next
@arrow:
    jsr upd_arrow
    bra @next
@stone:
    jsr upd_stone
@next:
    inc oi
    lda oi
    cmp #OBJ_MAX
    beq :+
    jmp @loop
:   rts
.endproc

; upd_coin (X=slot): the block coin-pop -- rises 1px/frame, spin phase advances 1/frame,
; expires after 32 frames (the original's $c0-marked popup path, moved every frame).
.proc upd_coin
    dec o_y,x                    ; straight up, 1px/frame (no gravity arc -- trace-verified)
    lda o_st,x                   ; spin phase 0,1,2,3 -> tiles $F6,$F7,$F8,$F7
    ina
    and #3
    sta o_st,x
    dec o_tmr,x
    bne @done
    stz o_type,x                 ; lifetime over -> free
@done:
    rts
.endproc

; upd_flower (X=slot): emerge (rise FLOWER_RISE px, then sit still), and let Mario pick it up.
; Runs every other frame like the other objects. The flower only exists when Mario is already
; big, so pickup just scores +1000 and despawns (Superball projectile ability = TODO).
.proc upd_flower
    lda frame_count              ; object AI runs every other frame (~30 Hz)
    lsr
    bcc :+
    rts
:   ldx oi
    lda o_tmr,x                  ; still emerging? rise 1px/update out of the block
    beq @sit
    dec o_tmr,x
    dec o_y,x
@sit:
    lda cam_x                    ; --- pickup test: Mario world X = cam_x + spr_x ---
    clc
    adc spr_x
    sta tmpL
    lda cam_x+1
    adc #0
    sta tmpH
    sec                          ; dx = mario_wx - o_x  (abs)
    lda tmpL
    sbc o_xl,x
    sta tmpL
    lda tmpH
    sbc o_xh,x
    sta tmpH
    bpl @posdx
    sec
    lda #0
    sbc tmpL
    sta tmpL
    lda #0
    sbc tmpH
    sta tmpH
@posdx:
    lda tmpH
    bne @done
    lda tmpL
    cmp #14
    bcs @done
    lda spr_y                    ; dy = |mario_y - o_y| < 16 ?
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #16
    bcs @done
    lda #SFX_DFE0_04             ; the powerup-pickup sound (user-ID'd: mushroom/flower)
    jsr sfx_play
    lda #1
    sta mario_superball          ; picked up: grant the Superball ability (B fires superballs)
    lda #$00                     ; +1000
    ldx #$10
    jsr add_score
    lda #POP_1000_L              ; floating "1000"
    ldy #POP_1000_R
    jsr spawn_popup
    ldx oi
    stz o_type,x                 ; despawn the flower
@done:
    rts
.endproc

; upd_mush (X=slot): slide horizontally, fall under gravity onto the floor, and grow Mario
; when he overlaps it. (No wall collision — the mushroom is short-lived; documented.)
.proc upd_mush
    ; The original mushroom is a 2-stage object (RE'd from an mGBA per-frame trace): type $28
    ; "hop" -> morphs to $29 "walker". It hops up-and-right (~0.5px/frame for ~25 updates),
    ; then the walker DROPS STRAIGHT DOWN (x frozen, ~1px/frame) to the floor, then walks
    ; 0.5px/frame and reverses at walls. Object AI runs every OTHER frame (~30Hz) -> 1px/update
    ; = 0.5px/frame. o_tmr counts down the hop (and doubles as the no-insta-grab window).
    lda frame_count
    lsr
    bcc :+
    rts                          ; odd frame -> skip (every-other-frame ~30Hz)
:   lda o_tmr,x
    beq @walker
    ; ===== HOP: arc up + right (gentle), no floor/consume while airborne =====
    dec o_tmr,x
    jsr mush_xmove               ; x += vx
    ldx oi                       ; y += vy ; gentle gravity toward a +1 terminal
    clc
    lda o_y,x
    adc o_vy,x
    sta o_y,x
    lda o_vy,x
    bmi @hgrav
    cmp #1
    bcs @hdone
@hgrav:
    inc o_vy,x
@hdone:
    rts
@walker:
    ; ===== WALKER: floor check -> DROP (airborne) or WALK (grounded) =====
    ldx oi
    lda o_xl,x                   ; feet_col = (o_x + 4) >> 3
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
    bne @grounded
    ; --- DROP: x stays frozen, fall ~1px/frame (2px/update) ---
    ldx oi
    clc
    lda o_y,x
    adc #2
    sta o_y,x
    jmp @consume
@grounded:
    ldx oi                       ; snap to the floor tile top
    lda mrow
    asl
    asl
    asl
    sta o_y,x
    ; --- WALK: wall ahead (body row) -> reverse, else x += vx ---
    lda o_vx,x
    bmi @wleft
    lda o_xl,x                   ; right: ahead = (o_x + 8) >> 3
    clc
    adc #8
    sta feet_col
    lda o_xh,x
    adc #0
    sta feet_col+1
    bra @wchk
@wleft:
    lda o_xl,x                   ; left: ahead = (o_x - 1) >> 3
    sec
    sbc #1
    sta feet_col
    lda o_xh,x
    sbc #0
    sta feet_col+1
@wchk:
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
    beq @wmove
    ldx oi                       ; wall -> reverse direction
    lda o_vx,x
    eor #$FF
    ina
    sta o_vx,x
    jmp @consume
@wmove:
    jsr mush_xmove
@consume:
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
    bpl @posdx
    sec
    lda #0
    sbc tmpL
    sta tmpL
    lda #0
    sbc tmpH
    sta tmpH
@posdx:
    lda tmpH
    bne @done
    lda tmpL
    cmp #14
    bcs @done
    lda spr_y
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #16
    bcs @done
    ldx oi
    lda o_type,x                 ; heart or mushroom?
    cmp #OBJ_HEART
    beq @heart
    lda mario_big
    bne @score                   ; already big -> just score, no grow
    lda #SFX_DFE0_04             ; the powerup-pickup sound (user-ID'd)
    jsr sfx_play
    lda #$50
    sta mario_grow               ; start the 80-frame small->big grow (RE: original sets $ffa6=$50)
    stz mario_duck
@score:
    lda #$00
    ldx #$10
    jsr add_score
    lda #POP_1000_L              ; floating "1000"
    ldy #POP_1000_R
    jsr spawn_popup
    bra @take
@heart:
    jsr add_life_snd             ; 1-up heart (jingle + count)
    lda #POP_1UP_L               ; floating "1UP"
    ldy #POP_1UP_R
    jsr spawn_popup
@take:
    ldx oi
    stz o_type,x
@done:
    rts
.endproc

; mush_xmove: o_x += o_vx (sign-extended). Uses oi for the slot.
.proc mush_xmove
    ldx oi
    ldy #0
    lda o_vx,x
    bpl :+
    ldy #$FF
:   sty tmpH
    clc
    lda o_xl,x
    adc o_vx,x
    sta o_xl,x
    lda o_xh,x
    adc tmpH
    sta o_xh,x
    rts
.endproc

; erase_objects: repaint the background where each object was drawn last frame (shifted with
; render_all: the whole sprite layer for this frame, from LAST frame's logic state.
; Runs at FRAME START (beam above the playfield), in four passes so overlapping
; sprites can never wipe each other (the paired-per-slot version had that bug):
;   1 classify: compute each slot's new screen pos + dirty flag (pos/anim-token/shift)
;   2 propagate: anything a dirty sprite's ERASE rect touches becomes dirty too
;   3 erase every dirty sprite's old image (shift-compensated)
;   4 draw every dirty visible sprite; Mario last (on top); update prev state
; Clean sprites cost nothing (dirty-skip): a 1px/3f walker skips 2 of 3 frames,
; platforms every other frame, an idle scene everything.
.proc render_all
    ; ---------- pass 0: fold a DMA shift into the stored positions ----------
    ; The shift moves every drawn image 32px left INSIDE the framebuffer while the
    ; scroll latch keeps its SCREEN position — so an unmoved sprite is still drawn
    ; correctly. Folding shift_px into o_pvx/prev_vx (same clamp the erases used)
    ; lets the normal dirty test + budget work on shift frames instead of the old
    ; redraw-everything (which made every 32px of scroll a 160%+ frame).
    lda shift_px
    beq @nofold
    ldx #OBJ_MAX-1
@fold:
    lda o_pdr,x
    beq @fnext
    lda o_pvx,x
    cmp shift_px
    bcs :+
    lda shift_px
:   sec
    sbc shift_px
    sta o_pvx,x
@fnext:
    dex
    bpl @fold
    lda prev_vx                  ; Mario's stored fb x
    cmp shift_px
    bcs :+
    lda shift_px
:   sec
    sbc shift_px
    sta prev_vx
@nofold:
    ; ---------- pass 1: classify slots (rotated origin + redraw budget) ----------
    jsr p1_init
@p1:
    ldx oi
    stz o_nfl,x
    lda o_type,x
    beq @p1vis0                  ; dead slot: not visible (erase leftovers via dirty)
    sec                          ; screen x = o_x - cam + scroll_s
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
    bne @p1vis0
    lda tmpL
    cmp #168
    bcs @p1vis0
    ldx oi
    lda o_y,x                    ; dy clip 16..152
    clc
    adc #8
    cmp #16
    bcc @p1vis0
    cmp #153
    bcs @p1vis0
    sta o_ndy,x
    lda tmpL
    sta o_nvx,x
    lda #2                       ; visible
    sta o_nfl,x
    ; dirty?
    lda tmpL                     ; overlaps the strip a streamed column / margin
    jsr stream_hit               ; blank rewrote THIS frame? those pixels are gone —
    bcs @p1dirty                 ; redraw; everyone else keeps the dirty test
    lda o_pdr,x
    beq @p1dirty
    lda o_nvx,x
    cmp o_pvx,x
    bne @p1move
    lda o_ndy,x
    cmp o_pvy,x
    bne @p1move
    jsr anim_token               ; per-type token (must mirror the pass-4 write)
    cmp o_pfr,x
    beq @p1next
@p1move:
    dec dirty_bud                ; pure movement/anim: over budget -> keep last
    bpl @p1dirty                 ; frame's image (overlap propagation may still
    lda o_pvx,x                  ; force it later — consistency preserved)...
    jsr stream_hit               ; UNLESS the kept image intersects the strip a
    bcs @p1dirty                 ; streamed column just wiped — must redraw
    bra @p1next
@p1dirty:
    lda o_nfl,x
    ora #1
    sta o_nfl,x
    bra @p1next
@p1vis0:
    ldx oi
    lda o_pdr,x                  ; not visible: dirty iff something old needs erasing
    beq @p1next
    lda #1
    sta o_nfl,x
@p1next:
    jsr p1_next
    bcs :+
    jmp @p1
:
    ; ---------- Mario: classify ----------
    lda spr_x
    clc
    adc scroll_s
    sta mario_vx
    lda #1
    sta m_dirty
    lda mario_vx                 ; the streamed/blanked strip wiped his pixels?
    jsr stream_hit
    bcs @mclassd
    lda mario_grow
    ora mario_shrink
    ora mario_starT
    ora hurt_inv
    bne @mclassd
    lda mario_vx
    cmp prev_vx
    bne @mclassd
    lda spr_y
    cmp prev_y
    bne @mclassd
    lda mario_frame
    cmp prev_frame
    bne @mclassd
    lda mario_facing
    eor mario_duck
    eor mario_big
    cmp prev_vis
    bne @mclassd
    stz m_dirty
@mclassd:
    ; ---------- pass 2: overlap propagation (2 rounds) ----------
    jsr @spread
    jsr @spread
    ; ---------- pass 3: erase all dirty ----------
    stz oi
@p3:
    ldx oi
    lda o_nfl,x
    and #1
    beq @p3n
    lda o_pdr,x
    beq @p3n
    lda o_pvx,x                  ; erase at the old drawn spot (a DMA shift was
    sta rb_vx                    ; already folded into o_pvx by pass 0)
    lda o_pvy,x
    sta rb_y
    ldy #1
    lda o_pw,x
    bpl @short
    iny                          ; TALL (16px): erase from 8px above, one extra row
    asl                          ; bit6 = EXTRA-TALL (24px: Totomesu) -> one more
    bpl :+
    iny
:   lsr                          ; A = (o_pw<<1)>>1 = o_pw & $7F
    and #$3F
    sta rb_cols
    lda o_pvy,x
    sec
    sbc #8
    sta rb_y
    bra @rows
@short:
    sta rb_cols
@rows:
    lda o_pvy,x
    and #7
    beq :+
    iny
:   sty rb_rows
    jsr restore_bg
    ldx oi
    stz o_pdr,x
@p3n:
    inc oi
    lda oi
    cmp #OBJ_MAX
    bne @p3
    lda m_dirty                  ; Mario's erase (prev_vx pre-folded by pass 0)
    beq @p4s
    lda prev_vx
    sta rb_vx
    lda prev_y
    sta rb_y
    lda #3
    sta rb_cols
    ldy #2
    lda prev_y
    and #7
    beq :+
    iny
:   sty rb_rows
    jsr restore_bg
    ; ---------- pass 4: draw all dirty visible; Mario last ----------
@p4s:
    stz oi
@p4:
    ldx oi
    lda o_nfl,x
    and #5                       ; needs a draw (dirty or refresh-only) ...
    beq @p4skip
    lda o_nfl,x
    and #2                       ; ... and visible
    bne @p4go
@p4skip:
    jmp @p4n
@p4go:
    lda o_nvx,x
    sta ovx
    jsr draw_obj_sprite
    ldx oi
    lda o_nvx,x
    sta o_pvx,x
    lda o_ndy,x
    sta o_pvy,x
    lda #2                       ; drawn width: 2 cols; 3 popup/explosion; 4 platform;
    ldy o_type,x                 ; bit7 = TALL (16px: the Nokobon)
    cpy #OBJ_GIFT
    bcc :+
    jsr ovl_width                ; erase widths for the resident kit
    bra @wset
:
    cpy #OBJ_POPUP
    bne :+
    lda #3
:   cpy #OBJ_SQUASH              ; the fly's FLAT corpse is a 2-tile pair (16px):
    bne @notsq                   ; without the wider erase it smears while falling
    ldy o_st,x
    beq :+
    lda #3
:   ldy #OBJ_SQUASH
@notsq:
    cpy #OBJ_BOOM
    bne :+
    lda #$83                     ; 16x16 four-quadrant cloud: wide + tall erase
:   cpy #OBJ_NOKO
    bne :+
    lda #$82
:   cpy #OBJ_FLY
    bne :+
    lda #$83                     ; 16 wide + tall
:   cpy #OBJ_BUNBUN
    bne :+
    lda #$83                     ; 16 wide + tall
:   cpy #OBJ_ARROW
    bne :+
    lda #$82                     ; 8 wide, 16 tall
:   cpy #OBJ_CORPSE
    bne :+
    lda #2
    ldy o_tmr,x                  ; kind: noko tall, fly wide+tall
    beq :+
    lda #$82
    cpy #1
    beq :+
    lda #$83
:   ldy o_type,x
    cpy #OBJ_PLATV
    bcc :+
    cpy #OBJ_PLATH+1
    bcs :+
    lda #4
:
@wset:
    sta o_pw,x
    jsr anim_token               ; per-type anim token (bee flap slot-staggered;
    sta o_pfr,x                  ; arrows/stones never anim-dirty)
    lda #1
    sta o_pdr,x
@p4n:
    inc oi
    lda oi
    cmp #OBJ_MAX
    beq :+
    jmp @p4
:   lda m_dirty
    beq @out
    jsr draw_player
    lda mario_vx
    sta prev_vx
    lda spr_y
    sta prev_y
    lda mario_frame
    sta prev_frame
    lda mario_facing
    eor mario_duck
    eor mario_big
    sta prev_vis
@out:
    rts
; @spread: one propagation round -- every dirty sprite's OLD rect vs every clean drawn
; sprite's OLD rect (coarse boxes: |dx|<32, |dy|<28); hits become dirty. Mario included.
@spread:
    stz oi2
@sp_i:
    ldx oi2
    lda o_nfl,x
    and #1
    beq @sp_in                   ; i not dirty
    lda o_pdr,x
    beq @sp_in                   ; i has no old image -> its erase can't wipe anyone
    stz tmpL3                    ; j loop
@sp_j:
    ldy tmpL3
    cpy oi2
    beq @sp_jn
    lda o_nfl,y
    and #1
    bne @sp_jn                   ; j already dirty
    lda o_pdr,y
    beq @sp_jn                   ; j not drawn
    lda o_pw,x                   ; box width by the pair's real widths: two narrow
    and #$7F                     ; (8px) sprites need only a 20px box — the wide 32px
    cmp #3                       ; box was chaining arrows to everything nearby
    bcs @sp_wide
    lda o_pw,y
    and #$7F
    cmp #3
    bcs @sp_wide
    lda o_pvx,x
    sec
    sbc o_pvx,y
    bpl :+
    eor #$FF
    ina
:   cmp #20
    bcs @sp_jn
    bra @sp_ychk
@sp_wide:
    lda o_pvx,x
    sec
    sbc o_pvx,y
    bpl :+
    eor #$FF
    ina
:   cmp #32
    bcs @sp_jn
@sp_ychk:
    lda o_pvy,x
    sec
    sbc o_pvy,y
    bpl :+
    eor #$FF
    ina
:   cmp #28
    bcs @sp_jn
    jsr mark_slot_y              ; overlap: j must redraw (erase too if it moved)
@sp_jn:
    inc tmpL3
    lda tmpL3
    cmp #OBJ_MAX
    bne @sp_j
@sp_in:
    inc oi2
    lda oi2
    cmp #OBJ_MAX
    bne @sp_i
    ; Mario vs slots (both directions)
    stz tmpL3
@sp_m:
    ldy tmpL3
    lda o_pdr,y
    beq @sp_mn
    lda prev_vx
    sec
    sbc o_pvx,y
    bpl :+
    eor #$FF
    ina
:   cmp #32
    bcs @sp_mn
    lda prev_y
    sec
    sbc o_pvy,y
    bpl :+
    eor #$FF
    ina
:   cmp #28
    bcs @sp_mn
    lda m_dirty                  ; overlapping pair: if either is dirty, both are
    bne @sp_mset
    lda o_nfl,y
    and #1
    beq @sp_mn
    lda #1
    sta m_dirty
    bra @sp_mn
@sp_mset:
    jsr mark_slot_y
@sp_mn:
    inc tmpL3
    lda tmpL3
    cmp #OBJ_MAX
    bne @sp_m
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
    cmp #OBJ_GIFT
    bcc :+
    jmp (ovl_vec+8)              ; the resident kit draws (RAM overlay)
:   cmp #OBJ_COIN
    bne :+
    jmp @coin
:   cmp #OBJ_FLOWER
    bne :+
    jmp @flower
:   cmp #OBJ_BALL
    bne :+
    jmp @ball
:   cmp #OBJ_POPUP
    bne :+
    jmp @popup
:   cmp #OBJ_BOUNCE
    bne :+
    jmp @bounce
:   cmp #OBJ_PLATV
    bcc :+
    cmp #OBJ_PLATH+1
    bcs :+
    jmp @plat
:   cmp #OBJ_CORPSE
    bne :+
    jmp @corpse
:   cmp #OBJ_HEART
    beq @heart
    cmp #OBJ_CHIB
    beq @chib
    cmp #OBJ_NOKO
    bne :+
    jmp @noko
:   cmp #OBJ_BOMB
    bne :+
    jmp @bomb
:   cmp #OBJ_BOOM
    bne :+
    jmp @boom
:   cmp #OBJ_FLY
    bne :+
    jmp @fly
:   cmp #OBJ_SQUASH
    bne :+
    jmp @squash
:   cmp #OBJ_BUNBUN
    bne :+
    jmp draw_bunbun
:   cmp #OBJ_ARROW
    bne :+
    jmp draw_arrow
:   cmp #OBJ_STONE
    bne :+
    jmp draw_stone
:   cmp #OBJ_STAR
    bne :+
    jmp @stard
:   cmp #OBJ_DEBRIS
    bne :+
    jmp @shard
:
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
@heart:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #HEART_TILE
    jsr draw_quad
    rts
@chib:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda frame_count              ; walk anim = the SAME tile $90 MIRRORED every 8 frames
    lsr                          ; (RE: params $00/$01 are both tile $90, one with the flip
    lsr                          ; attr -- $91 is the SQUASH frame, not a walk frame)
    lsr
    and #1
    sta do_flip
    ldx #CHIB_TA
    jsr draw_quad
    rts
@corpse:
    lda spr_col                  ; the dead-flip: the enemy's own sprite Y-FLIPPED
    sta dcol                     ; (GB corpse OAM attr $40)
    ldx oi
    lda o_tmr,x                  ; kind: 0 chibibo, 1 nokobon, 2 fly
    bne @cnoko
    lda o_y,x                    ; --- chibibo: one tile ---
    clc
    adc #8
    sta dy
    ldx #CHIB_TA
    jmp draw_tile_yflip
@cnoko:
    cmp #2
    beq @cfly
    cmp #3
    bne :+
    jmp draw_cbunbun
:
    ldx oi                       ; --- nokobon 8x16: bottom tile flipped on TOP ---
    lda o_y,x
    sta dy
    ldx #NOKO_B1
    jsr draw_tile_yflip
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    ldx #NOKO_T1
    jmp draw_tile_yflip
@cfly:
    ldx oi                       ; --- fly 16x16: bottom row flipped on top ---
    lda o_y,x
    sta dy
    ldx #FLY_BL
    jsr draw_tile_yflip
    lda spr_col
    ina
    ina
    sta dcol
    ldx oi
    lda o_y,x
    sta dy
    ldx #FLY_BL+1
    jsr draw_tile_yflip
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #FLY_TL
    jsr draw_tile_yflip
    lda spr_col
    ina
    ina
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #FLY_TL+1
    jmp draw_tile_yflip
@squash:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda o_vx,x                   ; corpse tile rides in o_vx
    tax
    jsr draw_quad
    ldx oi
    lda o_st,x                   ; pair flag (fly corpse): second tile 8px right
    beq @sqd
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    ldx oi
    lda o_vx,x
    ina                          ; $A8 -> $A9
    tax
    jsr draw_quad
@sqd:
    rts
@noko:
    ldx oi
    lda o_vx,x                   ; face the walk direction (the tiles face LEFT natively;
    bmi :+                       ; mirror only when walking right)
    lda #1
    bra :++
:   lda #0
:   sta do_flip
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x                    ; bottom tile at dy, shell/bomb tile at dy-8 (8x16)
    clc
    adc #8
    sta dy
    ldx #NOKO_B1
    lda frame_count
    and #8
    beq :+
    ldx #NOKO_B2
:   jsr draw_quad
    ldx oi
    lda do_flip                  ; draw_quad clears it? no -- draw_obj_sprite did; keep set
    pha
    lda o_y,x
    sta dy                       ; top half (dy-8+8 = o_y)
    pla
    sta do_flip
    ldx #NOKO_T1
    lda frame_count
    and #8
    beq :+
    ldx #NOKO_T2
:   jsr draw_quad
    stz do_flip
    rts
@bomb:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda o_tmr,x                  ; blink ~2Hz on the fuse timer
    and #16
    php
    ldx #BOMB_TA
    plp
    beq :+
    ldx #BOMB_TB
:   jsr draw_quad
    rts
@boom:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x                    ; the 16x16 cloud occupies o_y..o_y+16: the TOP
    sta dy                       ; row sits an 8px row ABOVE the anchor, exactly
    lda o_tmr,x                  ; the envelope the TALL erase covers (the shell
    and #4                       ; convention) -- a below-anchor row never erases
    php
    ldx #BOOM_TA
    plp
    beq :+
    ldx #BOOM_TB
:   phx
    stz do_flip
    jsr draw_quad                ; TL
    lda spr_col
    ina
    ina
    sta dcol                     ; TR = the same tile X-mirrored, 8px right
    lda #1
    sta do_flip
    plx
    phx
    jsr draw_quad
    ldx oi                       ; the GB cloud is FOUR mirrored quadrants (16x16,
    lda o_y,x                    ; captured OAM attrs 0/$20/$40/$60)
    clc
    adc #8
    cmp #152
    bcs @boomdone                ; bottom clip at the screen edge
    sta dy
    lda spr_col
    sta dcol
    stz do_flip
    plx
    phx
    jsr draw_tile_yflip          ; BL = y-mirror
    lda spr_col
    ina
    ina
    sta dcol
    lda #1
    sta do_flip
    plx
    phx
    jsr draw_tile_yflip          ; BR = xy-mirror
@boomdone:
    plx
    stz do_flip
    rts
@fly:
    ldx oi
    lda o_vx,x                   ; face the hop direction (tiles face left natively)
    bmi :+
    lda #1
    bra :++
:   lda #0
:   sta tmpH3                    ; facing (do_flip per quad; draw_quad preserves it? set each)
    lda frame_count              ; wing buzz (matches the dirty-skip anim token cadence)
    and #8
    beq :+
    lda #2                       ; frame B tile offset ($A2/$B2)
:   sta tmpL3
    ; TL
    ldx oi
    lda o_y,x
    sta dy                       ; top row at o_y (bottom row at o_y+8, feet line)
    lda spr_col
    sta dcol
    lda tmpH3
    sta do_flip
    lda #FLY_TL
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ; TR
    ldx oi
    lda o_y,x
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    lda tmpH3
    sta do_flip
    lda #FLY_TL+1
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ; BL
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    lda tmpH3
    sta do_flip
    lda #FLY_BL
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ; BR
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    lda tmpH3
    sta do_flip
    lda #FLY_BL+1
    clc
    adc tmpL3
    tax
    jsr draw_quad
    stz do_flip
    rts
@stard:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #STAR_TA                 ; twinkle $86 <-> $85 (~every 8 frames, like the flower)
    lda frame_count
    and #8
    beq :+
    ldx #STAR_TB
:   jsr draw_quad
    rts
@shard:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #DEBRIS_TILE
    jsr draw_quad
    rts
@ball:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #BALL_TILE
    jsr draw_quad
    rts
@flower:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #FLOWER_TA               ; 2-frame flash A<->B (~every 8 frames), like the original
    lda frame_count
    and #8
    beq :+
    ldx #FLOWER_TB
:   jsr draw_quad
    rts
@coin:
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx oi                       ; spin phase -> tile $F6,$F7,$F8,$F7
    lda o_st,x
    cmp #3
    bne :+
    lda #1
:   clc
    adc #COINSPIN
    tax
    jsr draw_quad
    rts
@popup:
    lda spr_col                  ; two glyph tiles side by side (left in o_vx, right in o_st)
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda o_vx,x
    tax
    jsr draw_quad
    lda spr_col                  ; right glyph 8px (= 2 byte-columns) over
    clc
    adc #2
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda o_st,x
    tax
    jsr draw_quad
    rts
@bounce:
    lda spr_col                  ; the hopping block: its pre-bonk tile rides in o_vx
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda o_vx,x
    tax
    jsr draw_quad
    rts
@plat:
    ldx oi                       ; platform: 3x tile $EF side by side (24px)
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    ldx #PLAT_TILE
    jsr draw_quad
    lda spr_col
    clc
    adc #2
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #PLAT_TILE
    jsr draw_quad
    lda spr_col
    clc
    adc #4
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #PLAT_TILE
    jsr draw_quad
    rts
.endproc

; ---------------------------------------------------------------------------
; load_level: bind the engine's per-level pointers/limits to the CURRENT bank's
; level_hdr (leveldata.s), and copy the small tables (rooms/pipes/blocks/spawns)
; to RAM so the rest of the engine keeps absolute indexed addressing. Lives in
; the LEVELS common prefix: identical bytes at the identical address in every
; bank, so it stays valid across a bank switch.
.segment "LEVELS"
.proc load_level
    stz ending13                 ; a fresh level never inherits ending state
    stz e_phase
    stz e_own
    ldx cur_level                ; map the level's ROM bank at $8000 (bank 0 hosts 1-2
    lda lvl_bank_tab,x           ; beside the title -- the smallest W1 level; 1-1 = bank
                                 ; 1). Safe mid-proc: load_level sits in the common
                                 ; prefix, byte-identical at this address in every bank.
    ora #(SYSCTRL_NMI_EN | SYSCTRL_TIMER_IRQ | SYSCTRL_LCD)
    sta SYS_CTRL
    lda #<level_hdr              ; header base: bank 0 = the linked address; banks 1+
    sta lvl_ptr                  ; keep theirs where bank 0 has the TITLE (the packer
    lda #>level_hdr              ; overlays it — the title runs only with bank 0 mapped)
    sta lvl_ptr+1
    lda cur_level
    cmp #1                       ; bank 0's linked resident is LEVEL 1 (1-2)
    beq @hcopy
    ldy #<__TITLE0_LOAD__
    sty lvl_ptr
    ldy #>__TITLE0_LOAD__
    sty lvl_ptr+1
    cmp #2                       ; bank 2: the L3 overlay blob precedes the header
    bne :+
    ldy #<(__TITLE0_LOAD__+__L3CODE_SIZE__)
    sty lvl_ptr
    ldy #>(__TITLE0_LOAD__+__L3CODE_SIZE__)
    sty lvl_ptr+1
    bra @hcopy
:   cmp #0                       ; bank 1: the BONUS blob (L11CODE) precedes the header
    bne @hcopy
    ldy #<(__TITLE0_LOAD__+__L11CODE_SIZE__+__L13E_SIZE__)
    sty lvl_ptr
    ldy #>(__TITLE0_LOAD__+__L11CODE_SIZE__+__L13E_SIZE__)
    sty lvl_ptr+1
@hcopy:
    ldy #21                      ; header -> RAM (22 bytes; +20/21 = overlay blob)
:   lda (lvl_ptr),y
    sta hdr_buf,y
    dey
    bpl :-
    lda hdr_buf+0                ; surface map
    sta surf_map
    lda hdr_buf+1
    sta surf_map+1
    lda hdr_buf+2              ; width in columns
    sta lvl_cols
    lda hdr_buf+3
    sta lvl_cols+1
    lda lvl_cols                 ; cam_max = (cols - 20) * 8
    sec
    sbc #20
    sta cam_max
    lda lvl_cols+1
    sbc #0
    sta cam_max+1
    asl cam_max
    rol cam_max+1
    asl cam_max
    rol cam_max+1
    asl cam_max
    rol cam_max+1
    lda lvl_cols                 ; fbmax_col = cols - 24
    sec
    sbc #24
    sta fbmax_col
    lda lvl_cols+1
    sbc #0
    sta fbmax_col+1
    ldx #5                       ; room map pointers (3 x .addr)
:   lda hdr_buf+4,x
    sta room_tbl,x
    dex
    bpl :-
    lda hdr_buf+10             ; pipes -> RAM (pipe_cnt * 5 bytes)
    sta lvl_ptr
    lda hdr_buf+11
    sta lvl_ptr+1
    lda hdr_buf+12
    sta pipe_cnt
    beq @nopipes
    asl
    asl
    adc pipe_cnt                 ; *5 (<= 3 pipes, no carry)
    tay
:   dey
    lda (lvl_ptr),y
    sta pipe_tab,y
    cpy #0
    bne :-
@nopipes:
    lda hdr_buf+13             ; ?-blocks -> RAM (count * 4 bytes)
    sta lvl_ptr
    lda hdr_buf+14
    sta lvl_ptr+1
    lda hdr_buf+15
    asl
    asl
    sta blk_lim                  ; find_block loop limit
    tay
    beq @noblocks
:   dey
    lda (lvl_ptr),y
    sta block_tab,y
    cpy #0
    bne :-
@noblocks:
    lda hdr_buf+16             ; spawn list -> RAM (256 bytes; the $FFFF sentinel
    sta lvl_ptr                  ; inside the data ends the live part)
    lda hdr_buf+17
    sta lvl_ptr+1
    ldy #0
:   lda (lvl_ptr),y
    sta spawn_tab,y
    iny
    bne :-
    inc lvl_ptr+1
:   lda (lvl_ptr),y              ; second page (spawn_tab is 384 bytes)
    sta spawn_tab+256,y
    iny
    cpy #128
    bne :-
    stz water_on
    lda cur_level                ; 1-3 (bank 2): copy the L3 overlay to RAM + enable
    cmp #2                       ; the water shimmer (GB LevelParamTable / $d014).
    bne @nol3                    ; The packer stores the blob at the TITLE0 address
    lda #<__TITLE0_LOAD__        ; (the header follows it — see @hdr2 above).
    sta lvl_ptr
    lda #>__TITLE0_LOAD__
    sta lvl_ptr+1
    lda #<__L3CODE_RUN__
    sta tmpL2
    lda #>__L3CODE_RUN__
    sta tmpH2
    ldx #8                       ; 8 pages cover the asserted max size
@l3pg:
    ldy #0
:   lda (lvl_ptr),y
    sta (tmpL2),y
    iny
    bne :-
    inc lvl_ptr+1
    inc tmpH2
    dex
    bne @l3pg
    lda #1
    sta water_on
@nol3:
    rts
.endproc

.import __L3CODE_LOAD__, __L3CODE_RUN__, __L3CODE_SIZE__
.import __L11CODE_SIZE__, __L13E_SIZE__
.assert __L13E_SIZE__ <= $7C0, error, "L13E overlay exceeds the RAM window"

.proc l3e_room_copy
    lda #<(__TITLE0_LOAD__+__L11CODE_SIZE__)
    sta lvl_ptr
    lda #>(__TITLE0_LOAD__+__L11CODE_SIZE__)
    sta lvl_ptr+1
    jmp copy_overlay
.endproc
.assert __L3CODE_SIZE__ <= $7C0, error, "L3CODE overlay exceeds the RAM window"
.assert __L11CODE_SIZE__ <= $7C0, error, "L11CODE overlay exceeds the RAM window"


.segment "LEVELS"                ; 1-2 entity draw bodies (FIXED is full; the banked
                                 ; common prefix is always mapped)
.segment "L12"
.proc draw_bunbun
    ldx oi
    lda o_vx,x                   ; face the flight direction (tiles face left natively)
    bmi :+
    lda #1
    bra :++
:   lda #0
:   sta tmpH3
    lda oi                       ; wing flap every 8 frames (params $30/$31), on the
    and #1                       ; slot-staggered phase (must match anim_token)
    asl
    asl
    clc
    adc frame_count
    and #8
    beq :+
    lda #2
:   sta tmpL3
    ldx oi                       ; TL
    lda o_y,x
    sta dy
    lda spr_col
    sta dcol
    lda tmpH3
    sta do_flip
    lda #BUN_TL
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ldx oi                       ; TR
    lda o_y,x
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    lda tmpH3
    sta do_flip
    lda #BUN_TL+1
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ldx oi                       ; BL
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    sta dcol
    lda tmpH3
    sta do_flip
    lda #BUN_BL
    clc
    adc tmpL3
    tax
    jsr draw_quad
    ldx oi                       ; BR
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    ina
    ina
    sta dcol
    lda tmpH3
    sta do_flip
    lda #BUN_BL+1
    clc
    adc tmpL3
    tax
    jsr draw_quad
    stz do_flip
    rts
.endproc
.segment "CODE"
.proc draw_stone
    lda spr_col                  ; one 8x8 tile at the platform line
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #STONE_T
    jsr draw_quad
    rts
.endproc
.segment "L12"
.proc draw_cbunbun
    ldx oi                       ; --- bunbun 16x16: bottom row flipped on top ---
    lda o_y,x
    sta dy
    ldx #BUN_BL
    jsr draw_tile_yflip
    lda spr_col
    ina
    ina
    sta dcol
    ldx oi
    lda o_y,x
    sta dy
    ldx #BUN_BL+1
    jsr draw_tile_yflip
    lda spr_col
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #BUN_TL
    jsr draw_tile_yflip
    lda spr_col
    ina
    ina
    sta dcol
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #BUN_TL+1
    jmp draw_tile_yflip
.endproc
.segment "LEVELS"
.segment "CODE"
.segment "L12"
.proc draw_arrow
    lda spr_col                  ; 8x16: point over shaft, no flip
    sta dcol
    ldx oi
    lda o_y,x
    sta dy
    ldx #ARROW_T
    jsr draw_quad
    ldx oi                       ; same column (dcol survives draw_quad)
    lda o_y,x
    clc
    adc #8
    sta dy
    ldx #ARROW_B
    jsr draw_quad
    rts
.endproc
.segment "CODE"

.segment "LEVELS"
; animate_player: pick the pose index — jump in the air, the 3-frame GB walk cycle
; while moving/gliding, skid during the brake, else standing.
.proc animate_player
    lda jump_state
    beq @ground
    lda #3                       ; jump
    sta mario_frame
    rts
@ground:
    lda skid_t                   ; turn-around brake: metasprite 5 (GB $1e48), held
    beq :+                       ; for the whole 8-frame freeze, old facing
    lda #4
    sta mario_frame
    rts
:   lda pad_held
    and #(GB_LEFT | GB_RIGHT)
    bne @moving
    lda mdir                     ; release glide: the walk anim keeps cycling until
    beq @idle                    ; the direction memory clears (capture: pose walks
@moving:                         ; through the LAST glide frame, stands the next)
    inc walk_t                   ; GB walk cycle ($1701): pose advances every 4 moving
    lda walk_t                   ; frames through metasprites 1 -> 2 -> 3 -> 1 ...
    and #3
    beq @adv
    rts                          ; between advances keep the current pose
@adv:
    ldx walk_i
    lda wcyc,x
    sta mario_frame
    inx
    cpx #3
    bcc :+
    ldx #0
:   stx walk_i
    rts
@idle:
    stz walk_t                   ; walking restarts the cycle at metasprite 1
    stz walk_i
    lda #0                       ; stand
    sta mario_frame
    rts
wcyc: .byte 2, 5, 1              ; port pose ids for GB metasprites 1, 2, 3
.endproc
.segment "CODE"

; mario_poses (4 poses x 4 tiles) and statusbar_tiles (2x20 template) are now
; ROM-derived BUILD ARTIFACTS extracted by tools/extract_tables.py (rule 5) and
; .incbin'd from src/datatables.s — see there.

; ---------------------------------------------------------------------------
; draw_quad: X = tile index; dcol/dy set. src_ptr = chardata + X*16; blit transparent.
.proc draw_quad
    txa                          ; src_ptr = chardata + X*16 -- except tiles
    stz src_ptr+1                ; $A0-$DC: the per-WORLD overlay (GB $8A00 load),
    asl                          ; resolved via the level header's base (hdr_buf
    rol src_ptr+1                ; +18 = chardata for W1, the in-bank blob for W2+)
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    asl
    rol src_ptr+1
    cpx #$A0
    bcc @common
    cpx #$DD
    bcs @common
    clc
    adc hdr_buf+18
    sta src_ptr
    lda src_ptr+1
    adc hdr_buf+19
    bra @haveb
@common:
    clc
    adc #<chardata
    sta src_ptr
    lda src_ptr+1
    adc #>chardata
@haveb:
    sta src_ptr+1
    jsr set_dst
    stz blit_opaque              ; Mario is transparent (GB colour 0 = see-through)
    jsr sprite_blit_subpx
    rts
.endproc

; set_dst: dst_ptr = $4000 + dy*48 + dcol.
.proc set_dst
    ldx dy                       ; dst = $4000 + dy*48 + dcol, via a 160-entry dy*48 table
    lda row48_lo,x               ; (was a shift/add chain -- 10% of the worst frame)
    clc
    adc dcol
    sta dst_ptr
    lda row48_hi,x
    adc #$40
    sta dst_ptr+1
    rts
.endproc

.segment "BSS"               ; dy -> dy*48 split tables, BUILT AT BOOT (they were
row48_lo: .res 160           ; 320 bytes of ROM in the banked prefix = 320 bytes
row48_hi: .res 160           ; paid in EVERY bank)
.segment "CODE"

; build_shtab: the sub-pixel shift/mask tables — for every byte b and subx k:
; the 16-bit b<<(2k) split lo/hi, and the same of b's transparency mask (boot).
.segment "LEVELS"
.proc build_shtab
    ldx #0
@b:
    stz tmpH
    txa
    sta tmpL
    lda tmpL
    sta shtab_lo,x
    lda tmpH
    sta shtab_hi,x
    asl tmpL
    rol tmpH
    asl tmpL
    rol tmpH
    lda tmpL
    sta shtab_lo+256,x
    lda tmpH
    sta shtab_hi+256,x
    asl tmpL
    rol tmpH
    asl tmpL
    rol tmpH
    lda tmpL
    sta shtab_lo+512,x
    lda tmpH
    sta shtab_hi+512,x
    asl tmpL
    rol tmpH
    asl tmpL
    rol tmpH
    lda tmpL
    sta shtab_lo+768,x
    lda tmpH
    sta shtab_hi+768,x
    inx
    beq @done
    jmp @b
@done:
    rts
.endproc

; find_free_evict: find_free_obj, but a FULL pool steals a cosmetic slot
; (popup / debris shard / squash corpse / flip corpse) instead of failing.
; Block outcomes (coin pop, block hop, mushroom/flower/star) must not vanish:
; the GB runs its block machinery OUTSIDE the object pool, so it never fails,
; but a brick break (4 shards + popup) can fill the port's pool for a moment.
; The stolen slot keeps its o_p* draw state, so the old image erases normally.
.proc find_free_evict
    jsr find_free_obj
    bcs @steal
    rts
@steal:
    ldx #0
@l:
    lda o_type,x
    cmp #OBJ_POPUP
    beq @take
    cmp #OBJ_DEBRIS
    beq @take
    cmp #OBJ_SQUASH
    beq @take
    cmp #OBJ_CORPSE
    beq @take
    inx
    cpx #OBJ_MAX
    bne @l
    sec
    rts
@take:
    stz o_hp,x
    clc
    rts
.endproc

.proc stream_one
    lda #4                       ; x = 4 - stream_pend (0..3: which margin column this frame)
    sec
    sbc stream_pend
    tax
    txa                          ; wcol = fb_col0 + 20 + x
    clc
    adc #20
    clc
    adc fb_col0
    sta wcol
    lda fb_col0+1
    adc #0
    sta wcol+1
    txa                          ; publish the rewritten fb-x span for the sprite
    asl                          ; overlap test: this column = [160+x*8, +8); on a
    asl                          ; shift frame blank_margin also zeroed bytes 42-43
    asl                          ; (fb x 168-176), contiguous with column x=0
    clc
    adc #160
    sta stream_x0
    adc #8
    sta stream_x1
    lda shift_px
    beq :+
    lda #176
    sta stream_x1
:   txa
    asl                          ; dbcol = 40 + x*2
    clc
    adc #40
    sta dbcol
    jmp draw_column
.endproc

; stream_hit: C=1 if a sprite at fb x = A (width <= 24px) overlaps the span
; rewritten this frame by stream_one/blank_margin ([stream_x0, stream_x1)).
; Only that strip loses sprite pixels -- redrawing everything at fb x >= 144 on
; stream frames was the residual shift-frame flicker in sprite-heavy scenes.
.proc stream_hit
    ldy stream_flag
    beq @no
    cmp stream_x1
    bcs @no
    clc
    adc #24
    cmp stream_x0
    bcc @no
    beq @no
    sec
    rts
@no:
    clc
    rts
.endproc

; flush_stream: drain any queued margin columns immediately (pre-double-shift guard).
.segment "CODE"
.proc flush_stream
    lda stream_pend
    beq @done
    jsr stream_one
    dec stream_pend
    bra flush_stream
@done:
    rts
.endproc
.segment "LEVELS"

; blank_margin: clear the 8 margin bytes of every playfield line — the linear DMA
; shift just filled them with the next line's left edge (see fb_shift8). Blank
; reads as sky until the stream queue refills the 4 columns.
.proc blank_margin
    lda #<($4000 + 16*48 + 42)   ; only bytes 42..43 can scroll into view before the
    sta cur_dst                  ; queue refills them (40-41 stream this same frame;
    lda #>($4000 + 16*48 + 42)   ; 44-45 refill at shift+2 yet need scroll_s>16 =
    sta cur_dst+1                ; ~10 frames; 46-47 likewise at shift+3 vs s>24)
    ldx #144                     ; lines 16..159
@l:
    lda #0
    sta (cur_dst)
    ldy #1
    sta (cur_dst),y
    lda cur_dst                  ; += stride
    clc
    adc #48
    sta cur_dst
    bcc :+
    inc cur_dst+1
:   dex
    bne @l
    rts
.endproc

; build_row48: fill the dy*48 tables (boot).
.proc build_row48
    stz tmpL
    stz tmpH
    ldx #0
@l: lda tmpL
    sta row48_lo,x
    lda tmpH
    sta row48_hi,x
    lda tmpL
    clc
    adc #48
    sta tmpL
    bcc :+
    inc tmpH
:   inx
    cpx #160
    bne @l
    rts
.endproc
.segment "CODE"


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
; (build_revpix moved to BOOT6: one-shot boot code runs from bank 6)

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
    lda #>shtab_lo               ; table pages for this subx (hi = lo + 4 pages;
                                 ; the lo bytes are zeroed once at boot)
    clc
    adc spr_subx
    sta p_shlo+1
    adc #4
    sta p_shhi+1
    lda blit_opaque              ; opaque: constant masks = the shifted $FF pair,
    beq :+                       ; hoisted out of the row loop
    ldy #$FF
    lda (p_shlo),y
    sta m0
    lda (p_shhi),y
    sta m2
    ora m0
    sta m1
:   lda #8
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
    ldy revpix,x
    bra @vals
@noflip:
    ldy #0
    lda (cur_src),y
    sta s0
    ldy #1
    lda (cur_src),y
    tay
@vals:
    lda spr_subx                 ; byte-aligned: the shift is identity, third byte
    bne @shifted                 ; empty — skip the table walk
    sty s1
    stz s2
    bra @masks
@shifted:
    lda (p_shhi),y               ; Y = right src byte: v1|v2 parts
    sta s2
    lda (p_shlo),y
    sta s1
    ldy s0
    lda (p_shhi),y
    ora s1
    sta s1
    lda (p_shlo),y
    sta s0
@masks:
    lda blit_opaque
    bne @merge                   ; opaque: masks preset
    lda s0                       ; transparency: M(shifted), inlined — M spreads each
    sta tmp_src                  ; nonzero 2-bit pixel to a full 2-bit mask and
    lsr                          ; commutes with the 2-bit-aligned shift
    ora tmp_src
    and #$55
    sta m0
    asl
    ora m0
    sta m0
    lda s1
    sta tmp_src
    lsr
    ora tmp_src
    and #$55
    sta m1
    asl
    ora m1
    sta m1
    lda s2
    sta tmp_src
    lsr
    ora tmp_src
    and #$55
    sta m2
    asl
    ora m2
    sta m2
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
    lda scroll_vis
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
; blit_blank: zero-fill one tile cell at dst_ptr (tile $2C = sky, bytes all $00).
; Same addressing as blit_tile but no source reads -- the erase fast path.
.proc blit_blank
    lda dst_ptr
    sta cur_dst
    lda dst_ptr+1
    sta cur_dst+1
    ldx #8
    lda #0
@row:
    ldy #1
    sta (cur_dst),y
    dey
    sta (cur_dst),y
    lda cur_dst                  ; dst += stride ($30)
    clc
    adc #VRAM_STRIDE
    sta cur_dst
    bcc :+
    inc cur_dst+1
:   lda #0
    dex
    bne @row
    rts
.endproc

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
; THE 1-3 KIT (L3CODE): bank-2-only code + data, linked to run at $1900 in RAM.
; load_level copies it there when level 2 (1-3) loads; every entry point below is
; reached only through type/level guards, so other levels never execute this RAM.
; All behavior is GB-capture-verified (docs/12 "1-3 kit"): PyBoy slot traces for
; the spider cycle, spiky-ball timer, Gao fire cycle + fireball aim, moai flyer
; bob + shot drops, the hidden-block secret, and the $3186 contact-table rows.
; ---------------------------------------------------------------------------
.segment "LEVELS"

MUS_T13 = 7                      ; track $03's index in the extractor's TRACKS list
lvl_track_tab:  .byte MUS_LEVEL, MUS_LEVEL, MUS_T13   ; GB per-level table $07CE
                .byte MUS_LEVEL, MUS_LEVEL, MUS_LEVEL  ; W2: slot 0 IS the world
                                                       ; theme (per-bank music patch)
; level id -> ROM bank, PRE-SHIFTED into SYS_CTRL bits 7:5 (saves the asl chain
; in load_level -- this table lives in the byte-frozen LEVELS prefix).
lvl_bank_tab:   .byte 1<<5, 0<<5, 2<<5, 3<<5, 4<<5, 5<<5

.proc lvl_music                  ; start the current level's tune
    ldx cur_level
    lda lvl_track_tab,x
    jmp mus_start
.endproc

.segment "L3CODE"

; --- tiles (GB OBJ set = SV chardata, indices identical) ---
SUU_TA  = $92                    ; frame A top / +1 bottom; frame B = $94/$95
ROCK_TL = $DD                    ; spiky ball left / $DE right
GAO_TL  = $A4                    ; A4 A5 / B4 B5; mouth open = +2
GAO_SQA = $B9                    ; stomped: B9 + B8 flat pair
FIRE_T  = $E2
GIFT_T  = $E6                    ; (bat tiles: see bat_row_a/b below)

.proc l3_spawn                   ; A = GB type, Y = spawn entry offset; C=0 spawned
    cmp #$02
    bne :+
    lda #OBJ_SUU
    bra @common
:   cmp #$0C
    bne :+
    lda #OBJ_ROCK
    bra @common
:   cmp #$3F
    bne :+
    lda #OBJ_GAO
    .byte $2C                    ; BIT abs: swallow the LDA (saves a byte -- bank 2
:   lda #OBJ_BAT                 ; is packed to the last byte)
@common:
    jsr obj_alloc_typed          ; (bytes: the old inline alloc paid for the room
    bcs @full                    ;  block-contents entries -- bank 2 is packed)
    jsr spawn_tabx               ; exact rule: world x = fire + 192 + x_off*4
    lda spawn_tab+2,y
    sta o_y,x
    ldy o_type,x
    cpy #OBJ_BAT                 ; Totomesu is 32x24 (3 tile rows): anchor o_y at
    bne :+                       ; the HEAD row so the tall erase (o_pvy-8, 2-3
    sec                          ; rows) covers his whole body
    sbc #8
    sta o_y,x
    phx
    jsr mus_stop                 ; GB $252F: a spawning type with score class 3
    lda #MUS_BOSS                ; (phys byte2 >= $C0 -- the bosses) starts the
    jsr mus_start                ; battle track $0B; it KEEPS playing even if he
    plx                          ; dies (captured: no restore until the sphere)
    lda o_y,x                    ; the mus calls clobbered A = the anchored y
:
    stz o_vx,x
    sta o_vy,x                   ; base y = the pipe/column rim (draw clip + hold)
    stz o_tmr,x
    stz o_st,x
    clc
@full:
    rts
.endproc

; --- update dispatch (X = oi on entry) ---
.proc l3_update
    lda o_type,x
    sec
    sbc #OBJ_GIFT
    asl
    tay
    lda l3_updtab+1,y
    pha
    lda l3_updtab,y
    pha
    rts                          ; rts-dispatch into the handler
.endproc
l3_updtab:
    .word upd_gift-1, upd_suu-1, upd_rock-1, upd_gao-1, upd_fire-1
    .word upd_bat-1, upd_bull-1, upd_gsq-1, upd_gcorp-1

.include "kit_sh1.inc"

; --- GAO $3F: static; 137f cycle -- mouth opens at tick 89 (+SFX $04 + fireball
; from the muzzle), closes at wrap. Stomp -> flat 48f; ball/star/bonk -> corpse ---
.proc upd_gao
    jsr l3_cull
    bcc :+
    rts
:   inc o_tmr,x
    lda o_tmr,x
    cmp #89
    bne :+
    jsr gao_fire
    ldx oi
:   lda o_tmr,x
    cmp #137
    bcc :+
    stz o_tmr,x
:   ; contact
    jsr l3_box
    bcs :+
    rts
:   lda mario_starT
    beq :+
    lda #1                       ; star: thrown along Mario's facing
    ldy mario_facing
    beq @sd
    lda #$FF
@sd:
    jsr l3_gao_kill
    lda #$08
    jmp award_kill
:   jsr l3_above
    bcs @hurt                    ; carry set = side/below -> hurt; CLEAR = above
    lda #OBJ_GSQ                 ; stomp: the flat pair ~48f, then the corpse
    sta o_type,x
    lda #48
    sta o_tmr,x
    lda #1                       ; Mario's stomp bounce
    sta jump_state
    lda #14
    sta arc_idx
    stz fall_v
    stz ride
    lda #$08                     ; Gao class 2 = 800, stomp combo chains
    jmp award_stomp
@hurt:
    jmp hurt_mario
.endproc

.proc gao_fire                   ; muzzle = the statue position; aim = Mario's side
    lda #SFX_DFF8_04
    jsr sfx_play
    jsr find_free_obj
    bcs @full
    ldy oi
    lda #OBJ_FIRE
    sta o_type,x
    lda o_xl,y
    sta o_xl,x
    lda o_xh,y
    sta o_xh,x
    lda o_y,y
    sta o_y,x
    jsr l3_aim_vx                ; vx: toward Mario
    sta o_vx,x
    ; vy: 0.5px/f toward Mario's side of the muzzle (capture: up if above, down if below)
    lda spr_y
    cmp o_y,y
    bcs :+
    lda #$FF
    bra @vy
:   lda #1
@vy:
    sta o_vy,x
    stz o_tmr,x
    stz o_st,x
@full:
    rts
.endproc

.proc l3_aim_vx                  ; Y = shooter slot -> A = +1/-1 toward Mario
    lda cam_x
    clc
    adc spr_x
    sta tmpL2
    lda cam_x+1
    adc #0
    cmp o_xh,y
    bcc @left
    bne @right
    lda tmpL2
    cmp o_xl,y
    bcs @right
@left:
    lda #$FF
    rts
@right:
    lda #1
    rts
.endproc

.proc l3_boss_hit                ; a superball hit on Totomesu (X = boss slot)
    inc o_hp,x
    lda o_hp,x
    cmp #5                       ; 5 hits (user-verified; GB: 800 gao + 2000 boss = 2800)
    bcs @die
    lda #SFX_DFF0_01             ; the hit sound (RE $2a68: HP>0 hits on types
    jsr sfx_play                 ; $08/$32 play $dff0=1; HP = slot byte $0C & $3F)
    bra @ball
@die:
    lda #SFX_DFF8_01             ; the burst (the $4F chain's F9 01)
    jsr sfx_play
    ldx oi2
    lda o_y,x                    ; head-anchored 24px: center the cloud, and let
    clc                          ; boom_swap free his slot so the full tall rect
    adc #8                       ; erases (in-place morph left his lower body)
    sta tmpH3
    jsr boom_swap                ; leaves tmpL2/H2/tmpH3 = his spot: the 5000
    lda #$50                     ; tag rides the burst, not Mario (GB film)
    jsr award_kill_at
@ball:
    ldx oi
    stz o_type,x                 ; the ball expires against him
    rts
.endproc

.include "kit_sh2.inc"

.proc l3_gao_kill                ; A = corpse drift dir; X = the Gao slot
    pha
    phx                          ; sfx_play CLOBBERS X — the corpse writes went
    lda #SFX_DFF8_03             ; to a garbage slot (stuck flat squash + the
    jsr sfx_play                 ; ball-killed Gao surviving; user-caught both)
    plx
    pla
    sta o_vx,x
    lda #OBJ_GCORP
    sta o_type,x
    stz o_tmr,x
    rts
.endproc

; --- FIRE $23: 1px/f horizontal, 0.5px/f vertical (slot-staggered), through
; everything; despawns off-screen. Any contact hurts; star/ball no effect ---
.proc upd_fire
    lda o_vx,x
    bmi @ml
    inc o_xl,x
    bne @xd
    inc o_xh,x
    bra @xd
@ml:
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
@xd:
.endproc                          ; (fall through)
.proc upd_fire2
    ldx oi
    txa                          ; y at half rate, slot-staggered like the arrows
    eor frame_count
    lsr
    bcs @ychk
    lda o_y,x
    clc
    adc o_vy,x
    sta o_y,x
@ychk:
    lda o_y,x
    cmp #2                       ; off the top / bottom
    bcc @gone
    cmp #168
    bcs @gone
    jsr l3_xoff                  ; off-screen x -> freed
    bcs @done
    jsr l3_box
    bcs :+
@done:
    rts
:   lda mario_starT
    bne @done
    jmp l3_hurt    
@gone:
    stz o_type,x
    rts
.endproc

.include "kit_sh3.inc"

; --- BAT $08 (moai flyer, 32x16): fixed x; 162f cycle -- hold, bob up 17px and
; back at 0.5px/f; launches a shot at ticks 64 and 121 (SFX $04). Star -> BOOM
; (5000, $3186 class 3); stomp/touch hurt; ball no effect ---
.proc upd_bat
    jsr l3_cull
    bcc :+
    rts
:   lda o_tmr,x
    cmp #64
    beq @shot
    cmp #121
    beq @shot
    bra @bob
@shot:
    jsr bat_shot
    ldx oi
@bob:
    lda o_tmr,x
    cmp #80
    bcc @tick                    ; hold
    cmp #114
    bcs :+
    txa                          ; rise 0.5px/f
    eor frame_count
    lsr
    bcs @tick
    dec o_y,x
    bra @tick
:   cmp #148
    bcs @tick
    txa                          ; sink 0.5px/f
    eor frame_count
    lsr
    bcs @tick
    inc o_y,x
@tick:
    inc o_tmr,x
    lda o_tmr,x
    cmp #162
    bcc :+
    stz o_tmr,x
    lda o_vy,x                   ; cycle wrap: SNAP to the base line (o_vy stores
    sta o_y,x                    ; the ADJUSTED head-row base -- no extra -8!)
:   ; contact box: 32px wide -> test vs the sprite centre (o_x+16): widen |dx|<18
    jsr mario_dx
    lda tmpH3
    bne @no
    lda tmpL3
    cmp #14                      ; only the FRONT (head/forelegs, left 16px) hurts:
    bcs @no                      ; Mario can pass over the back/tail (GB tolerance)
    lda o_y,x
    clc
    adc #8                       ; body centre row (o_y = the head row)
    sta tmpL2
    lda spr_y
    sec
    sbc tmpL2
    bpl :+
    eor #$FF
    ina
:   cmp #14
    bcs @no
    lda mario_starT
    beq @hurt
    lda #SFX_DFF8_01             ; star: the stone head BURSTS ($4F script, F9 01)
    jsr sfx_play
    ldx oi
    lda #OBJ_BOOM
    sta o_type,x
    lda #BOOM_LIFE
    sta o_tmr,x
    lda o_xl,x                   ; centre the 16px cloud on the 32px body
    clc
    adc #8
    sta o_xl,x
    bcc :+
    inc o_xh,x
:   lda #$50                     ; class 3 = 5000
    jmp award_kill
@hurt:
    jmp l3_hurt                  ; side only; the head zone passes through
@no:
    rts
.endproc

.proc bat_shot                   ; launch the $1E shot at (x+8, y-4), toward Mario
    lda #SFX_DFF8_04
    jsr sfx_play
    jsr find_free_obj
    bcs @full
    ldy oi
    lda o_xl,y
    clc
    adc #8
    sta o_xl,x
    lda o_xh,y
    adc #0
    sta o_xh,x
    lda o_y,y
    clc
    adc #4                       ; fire line (o_y = head row; breath from the mouth)
    sta o_y,x
    lda #OBJ_BULL
    sta o_type,x
    lda #$FF                     ; the breath goes his FACING (left) -- never backwards
    sta o_vx,x
    stz o_tmr,x
    stz o_st,x
@full:
    rts
.endproc

; --- BULL $1E: 1px/f horizontal, anim pair every 8f; any contact hurts ---
.proc upd_bull
    txa                          ; 30Hz staggered like the 1-2 arrows: 2px every
    eor frame_count              ; other frame on slot parity -- same trajectory,
    lsr                          ; half the redraws (two shots fly in the fight)
    bcs @done
    lda o_vx,x
    bmi @ml
    lda o_xl,x
    clc
    adc #2
    sta o_xl,x
    bcc @xd
    inc o_xh,x
    bra @xd
@ml:
    lda o_xl,x
    sec
    sbc #2
    sta o_xl,x
    bcs @xd
    dec o_xh,x
@xd:
    jsr l3_xoff                  ; keep while on screen
    bcs @done
    jsr l3_box
    bcs :+
@done:
    rts
:   lda mario_starT
    bne @done
    jmp l3_hurt    
.endproc

.include "kit_sh4.inc"

; --- GSQ: the stomped Gao pair, 48f, then thump + corpse ---
.proc upd_gsq
    dec o_tmr,x
    bne @done
    lda #1                       ; falls thrown along Mario's facing
    ldy mario_facing
    beq :+
    lda #$FF
:   jsr l3_gao_kill
@done:
    rts
.endproc

; --- GCORP: kill_flip motion -- 7f rise, then +2px/f fall, 1px/f drift ---
.proc upd_gcorp
    lda o_tmr,x
    cmp #7
    bcs @fall
    inc o_tmr,x
    dec o_y,x
    bra @drift
@fall:
    lda o_y,x
    clc
    adc #2
    sta o_y,x
    cmp #168
    bcc @drift
    stz o_type,x
    rts
@drift:
    lda o_vx,x
    bmi @dl
    inc o_xl,x
    bne @done
    inc o_xh,x
    rts
@dl:
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
@done:
    rts
.endproc

; --- bonk outcomes (a block hop under them; $3186 +4 column) ---
.proc l3_bonk                    ; X = victim slot
    lda o_type,x
    cmp #OBJ_GAO
    bne :+
    lda #1
    ldy mario_facing
    beq @gd
    lda #$FF
@gd:
    jsr l3_gao_kill
    lda #$08
    jmp award_kill
:   cmp #OBJ_GIFT
    bne :+
    lda #1                       ; the secret floats away (GB +4 = morph $14)
    sta o_st,x
    stz o_tmr,x
    rts
:   cmp #OBJ_BAT
    bne :+
    lda #OBJ_BOOM                ; the moai bursts ($4F)
    sta o_type,x
    lda #BOOM_LIFE
    sta o_tmr,x
    lda #SFX_DFF8_01
    jsr sfx_play
    lda #$50
    jmp award_kill
:   stz o_type,x                 ; spider/rock/shots: silent despawn ($FF), 100
    lda #$01
    jmp award_kill
.endproc

; --- draw dispatch (spr_col/dy conventions of draw_obj_sprite) ---
.proc l3_draw
    sec
    sbc #OBJ_GIFT
    asl
    tay
    lda l3_drwtab+1,y
    pha
    lda l3_drwtab,y
    pha
    rts
.endproc
l3_drwtab:
    .word draw_gift-1, draw_suu-1, draw_rock-1, draw_gao-1, draw_fire-1
    .word draw_bat13-1, draw_bull-1, draw_gsq-1, draw_gcorp-1

.include "kit_sh5.inc"

.proc draw_gcorp                 ; the statue y-flipped (rows swapped, tiles flipped)
    lda #1
    sta w_i
    bra gao_draw
.endproc
.proc draw_gao
    stz w_i
.endproc                          ; fall through
.proc gao_draw
    ldx oi
    lda #0
    ldy w_i
    bne :+                       ; the corpse never opens its mouth
    ldy o_tmr,x
    cpy #89
    bcc :+
    lda #2
:   sta tmpL3
    ldy #0
@q:
    phy
    ldx oi
    tya
    and #2
    beq :+
    lda #8
:   clc
    adc o_y,x
    sta dy
    lda spr_col
    sta dcol
    tya
    and #1
    beq :+
    inc dcol
    inc dcol
:   tya
    and #1
    sta tmpH3
    tya
    and #2                       ; row bit: bottom pair ($B4/B5) on quads 2,3 --
    ldy w_i                      ; INVERTED when y-flipped (bottom row drawn on top)
    beq :+
    eor #2
:   cmp #2
    bne :+
    lda tmpH3
    ora #$10
    sta tmpH3
:   lda #GAO_TL
    clc
    adc tmpH3                    ; <= $B5: never carries
    adc tmpL3
    tax
    lda w_i
    bne @flip
    jsr draw_quad
    bra @nx
@flip:
    jsr draw_tile_yflip
@nx:
    ply
    iny
    cpy #4
    bne @q
    rts
.endproc

.proc draw_fire
    ldx #FIRE_T
    jmp l3_one
.endproc

; Totomesu, 32x24 in 3 rows (GB OAM capture): head $CD $CE (both frames),
; face CA CB CC BA / AB C6 C7 AA, base DA DB DC / BB D6 D7
bat_row_a: .byte $CD,$CE,$CA,$CB,$CC,$BA,$DA,$DB,$DC
bat_row_b: .byte $CD,$CE,$AB,$C6,$C7,$AA,$BB,$D6,$D7
bat_dy:    .byte 0,0,8,8,8,8,16,16,16
bat_dx:    .byte 0,2,0,2,4,6,0,2,4

.proc draw_bat13
    ldy #0
@q:
    phy
    ldx oi
    lda o_y,x
    clc
    adc bat_dy,y
    sta dy
    lda spr_col
    clc
    adc bat_dx,y
    sta dcol
    lda o_tmr,x                  ; frame B while hopping (tick >= 31)
    cmp #31
    bcs @fb
    lda bat_row_a,y
    bra @t
@fb:
    lda bat_row_b,y
@t:
    tax
    jsr draw_quad
    ply
    iny
    cpy #9
    bne @q
    rts
.endproc

.proc draw_bull
    lda frame_count              ; C4 C5 <-> D4 D5 every 8f
    and #8
    beq :+
    lda #$10
:   clc
    adc #$C4
    sta tmpL3
    ina
    sta tmpH3
    jmp l3_pair
.endproc

.include "kit_sh6.inc"

.proc draw_gsq                   ; the flat pair: $B9 left, $B8 right
    lda #GAO_SQA
    sta tmpL3
    lda #GAO_SQA-1
    sta tmpH3
    jmp l3_pair
.endproc

; (draw_gcorp merged into gao_draw above)

.include "kit_sh7.inc"

; --- the water shimmer: every 8 frames re-blit visible $5D cells (rows 4-6)
; with the phase source; cells under a drawn sprite are skipped this tick ---
water_alt: .incbin "build/gfx/water_alt.svt"   ; tile $5D, high plane = ROM $3fc4

; The SPHERE ($E1 at col 297 row 9, on the pedestal): reaching it at max camera
; runs the standard clear entry (GB $1B45: jingle + freeze + tally) and arms the
; x-3 RESCUE ENDING (ending13 -> goal_phase 5 machine after the tally; docs/25).
; The position gate is equivalent to the GB's tile touch: the pedestal walk ends
; at the sphere. Runs from l3_water = every frame, 1-3 only.
.proc l3_goal_chk
    lda goal_phase
    bne @done
    lda cam_x+1
    cmp cam_max+1
    bne @done
    lda cam_x
    cmp cam_max
    bne @done
    lda jump_state
    bne @done
    lda spr_x
    cmp #126                     ; the arena wall stops him at ~130
    bcc @done
    lda #1
    sta goal_phase
    sta ending13                 ; the rescue ending follows the tally
    lda #240
    sta goal_tmr
    stz goal_top
    stz mario_frame
    stz mario_duck
    jsr mus_stop                 ; (mus_rate is 3 all level; nothing to ride at
    lda #MUS_GOAL                ; the pedestal -- ride is clear here)
    jsr mus_start
@done:
    rts
.endproc

.proc l3_water
    jsr l3_goal_chk
    lda frame_count
    and #7
    beq :+
    rts
:   stz w_i
@col:
    lda fb_col0                  ; feet_col = fb_col0 + i
    clc
    adc w_i
    sta feet_col
    lda fb_col0+1
    adc #0
    sta feet_col+1
    lda #4
    sta w_row
@row:
    lda w_row
    sta mrow
    jsr read_map_tile
    cmp #$5D
    bne @next
    ; sprite veto: skip the cell if a drawn sprite overlaps it
    lda w_i
    asl
    asl
    asl
    sta tmpL2                    ; cell fb x
    lda w_row
    ina
    ina
    asl
    asl
    asl
    sta tmpH2                    ; cell dy
    ldx #OBJ_MAX-1
@veto:
    lda o_pdr,x
    beq @vn
    lda o_pvx,x
    sec
    sbc tmpL2
    bpl :+
    eor #$FF
    ina
:   cmp #16
    bcs @vn
    lda o_pvy,x
    sec
    sbc tmpH2
    bpl :+
    eor #$FF
    ina
:   cmp #24
    bcc @next                    ; overlapped: leave it this tick
@vn:
    dex
    bpl @veto
    lda prev_y                   ; Mario veto: any shore cell near his ROW skips a
    sec                          ; tick (cheaper than the full box; he rarely
    sbc tmpH2                    ; overlaps rows 4-6 anyway)
    bpl :+
    eor #$FF
    ina
:   cmp #32
    bcc @next
@clear:
    lda frame_count              ; phase source
    and #8
    beq @orig
    lda #<water_alt
    sta src_ptr
    lda #>water_alt
    sta src_ptr+1
    bra @blit
@orig:
    lda #$5D
    jsr get_tile_src
@blit:
    lda w_i
    asl
    sta dcol
    lda tmpH2
    sta dy
    jsr set_dst
    jsr blit_tile
@next:
    inc w_row
    lda w_row
    cmp #7
    beq :+
    jmp @row
:   inc w_i
    lda w_i
    cmp #24
    beq :+
    jmp @col
:   rts
.endproc


; ---------------------------------------------------------------------------
; THE BONUS GAME (L11CODE): bank-1-only blob, linked to run at RAM $1500 (the
; same window as the 1-3 kit -- they never coexist; load_level restores the
; needed overlay on every level load). Copied by bonus_enter_copy at the top-
; door goal path; runs entirely from RAM with bank 1 mapped or not (all its
; callees live in FIXED or the common prefix).
; ---------------------------------------------------------------------------
.segment "L11CODE"
; bput: blit tile A at (b_row, b_col) of the bonus screen (full-screen coords).
.proc bput
    pha
    lda b_col
    asl
    sta dcol
    lda b_row
    asl
    asl
    asl
    sta dy
    jsr set_dst
    pla
    jsr get_tile_src
    jsr blit_tile
    rts
.endproc

.proc bput_run                   ; A = tile, X = count: blit a horizontal run from b_col
    sta tmpL2
    stx tmpH2
:   lda tmpL2
    jsr bput
    inc b_col
    dec tmpH2
    bne :-
    rts
.endproc

; b_sety: spr_y = 40 + 24*b_floor (floor tops at dy 56/80/104/128; Mario is 16 above).
.proc b_sety
    lda b_floor
    asl
    asl
    asl
    sta tmpL2                    ; floor*8
    asl
    clc
    adc tmpL2                    ; floor*24
    clc
    adc #40
    sta spr_y
    rts
.endproc

; b_erase: blank the 3x3 tile area at Mario's current (spr_x, spr_y).
.proc b_erase
    lda spr_y
    lsr
    lsr
    lsr
    sta tmpL3                    ; top tile row
    stz tmpH3                    ; row counter
@row:
    lda spr_x
    lsr
    lsr
    lsr
    sta tmpL2                    ; left tile col
    stz tmpH2
@col:
    lda tmpL2
    asl
    sta dcol
    lda tmpL3
    asl
    asl
    asl
    sta dy
    jsr set_dst
    jsr blit_blank
    inc tmpL2
    inc tmpH2
    lda tmpH2
    cmp #3
    bne @col
    inc tmpL3
    inc tmpH3
    lda tmpH3
    cmp #3
    bne @row
    rts
.endproc

; b_ladder_cell: draw (A=0) or erase (A=1) the ladder at gap Y (0..2). The ladder is a
; 1-col 4-row strip at BG col 10, rows (7+3*gap)..(+3) — tiles $2E,$2F,$2F,$30, erased
; back to $2D (floor) at top+bottom and $2C between (RE: bank2 $5B27).
.proc b_ladder_cell
    sta tmpH3                    ; 0 draw / 1 erase
    tya
    asl
    sta tmpL3                    ; gap*2
    tya
    clc
    adc tmpL3
    clc
    adc #7
    sta b_row                    ; row = 7 + 3*gap
    lda #10
    sta b_col
    stz b_i
@loop:
    ldx b_i
    ldy tmpH3
    beq :+
    lda b_erasetab,x
    bra @put
:   lda b_ladtab,x
@put:
    jsr bput
    inc b_row
    inc b_i
    lda b_i
    cmp #4
    bne @loop
    rts
b_ladtab:   .byte $2E,$2F,$2F,$30
b_erasetab: .byte $2D,$2C,$2C,$2D
.endproc

; bonus_start: draw the whole bonus screen + place Mario. (RE: State_12/$13/$14.)
.proc bonus_start
    lda #MUS_BONUS               ; the bonus tune replaces the goal fanfare ($0F84
    jsr mus_start                ; writes $dfe8=$12 in the bonus-entry setup)
    stz scroll_s                 ; the level end leaves XSCROLL=32 (sub-shift): the bonus
    stz prev_scroll_s            ; draws at fb cols 0-19, so the window must start at 0
    stz scroll_vis
    stz XSCROLL
    jsr clear_vram               ; blank the full framebuffer (incl. the HUD rows)
    stz b_row                    ; --- border: top row ---
    stz b_col
    lda #$F5
    jsr bput
    inc b_col
    lda #$9F
    ldx #18
    jsr bput_run
    lda #$FC
    jsr bput
    lda #17                      ; --- bottom border (row 17) ---
    sta b_row
    stz b_col
    lda #$FF
    jsr bput
    inc b_col
    lda #$9F
    ldx #18
    jsr bput_run
    lda #$E9
    jsr bput
    lda #1                       ; --- side walls rows 1..16 ---
    sta b_row
@sides:
    stz b_col
    lda #$F8
    jsr bput
    lda #19
    sta b_col
    lda #$F8
    jsr bput
    inc b_row
    lda b_row
    cmp #17
    bne @sides
    lda #2                       ; --- "BONUS GAME" at row 2 col 5 ---
    sta b_row
    lda #5
    sta b_col
    stz b_i
:   ldx b_i
    lda @txt,x
    jsr bput
    inc b_col
    inc b_i
    lda b_i
    cmp #10
    bne :-
    lda #4                       ; --- lives: head icon + x + count at row 4 (original
    sta b_row                    ; tilemap row: E4 2C 2B 00 02 at cols 7-11) ---
    lda #7
    sta b_col
    lda #$E4
    jsr bput
    lda #9
    sta b_col
    lda #$2B                     ; the "x" -- was missing at init (only b_fixhud drew it)
    jsr bput
    lda #10
    sta b_col
    lda lives                    ; BCD tens/ones as font tiles
    lsr
    lsr
    lsr
    lsr
    jsr bput
    inc b_col
    lda lives
    and #$0F
    jsr bput
    stz b_i                      ; --- 4 floors (rows 7/10/13/16, cols 1..18) + pedestals ---
@floors:
    lda b_i
    asl
    sta tmpL3
    lda b_i
    clc
    adc tmpL3
    clc
    adc #7
    sta b_row                    ; floor row = 7+3n
    lda #1
    sta b_col
    lda #$2D
    ldx #18
    jsr bput_run
    dec b_row                    ; pedestal row = floor row - 1
    lda #17
    sta b_col
    lda #$2B
    jsr bput
    inc b_col
    ldx b_i
    lda b_prz,x
    jsr bput
    inc b_i
    lda b_i
    cmp #4
    bne @floors
    lda frame_count              ; Mario's random start floor
    lsr
    lsr
    and #3
    sta b_floor
    lda #16
    sta spr_x
    sta mario_vx
    jsr b_sety
    stz mario_frame
    stz mario_facing
    jsr draw_player
    stz b_tick
    lda #1
    sta b_ladder
    ldy #0                       ; first ladder visible at gap 0
    lda #0
    jsr b_ladder_cell
    rts
@txt: .byte $0B,$18,$17,$1E,$1C,$2C,$10,$0A,$16,$0E   ; "BONUS GAME" (font; $2C = space)
.endproc

; b_fixfloor: repaint the 3 cells of Mario's floor row (and any pedestal cells on the
; row above) that b_erase just blanked.
.proc b_fixfloor
    lda spr_y                    ; floor row = (spr_y + 16) >> 3
    clc
    adc #16
    lsr
    lsr
    lsr
    sta b_row
    sec                          ; only repaint REAL floor rows (7/10/13/16) -- mid-gap rows
    sbc #7                       ; during a climb must stay blank
    bmi @skip
    cmp #10
    bcs @skip
:   cmp #3
    bcc :+
    sbc #3
    bra :-
:   cmp #0
    beq @okrow
@skip:
    rts
@okrow:
    lda spr_x
    lsr
    lsr
    lsr
    sta b_col
    stz b_i
@f:
    lda b_col
    cmp #19                      ; inside the walls only
    bcs @next
    lda #$2D
    jsr bput
    dec b_row                    ; pedestal row: restore the "x" and the prize if touched
    lda b_col
    cmp #17
    bne @nored
    lda #$2B
    jsr bput
    bra @nored2
@nored:
    cmp #18
    bne @nored2
    ldx b_floor
    lda b_prz,x
    jsr bput
@nored2:
    inc b_row
@next:
    inc b_col
    inc b_i
    lda b_i
    cmp #3
    bne @f
    rts
.endproc

; b_fixgap: while climbing, the erase clips BOTH end floors of the gap at the ladder
; columns (10..12) -- repaint them each frame (the ladder redraw then overlays col 10).
.proc b_fixgap
    lda b_gap                    ; top floor row = 7 + 3*gap
    asl
    clc
    adc b_gap
    clc
    adc #7
    sta tmpH3
    lda #2
    sta tmpL3                    ; two rows: top floor, then +3 = bottom floor
@rows:
    lda tmpH3
    sta b_row
    lda #10
    sta b_col
    stz b_i
@cols:
    lda #$2D
    jsr bput
    inc b_col
    inc b_i
    lda b_i
    cmp #3
    bne @cols
    lda tmpH3
    clc
    adc #3
    sta tmpH3
    dec tmpL3
    bne @rows
    rts
.endproc

; b_fixhud: repaint the bonus lives counter (row 4: head $E4 @7, x $2B @9, digits @10-11)
; -- the hop's erase box reaches row 4; repainting keeps it intact AND live as lives tick.
.proc b_fixhud
    lda #4
    sta b_row
    lda #7
    sta b_col
    lda #$E4
    jsr bput
    lda #9
    sta b_col
    lda #$2B
    jsr bput
    lda #10
    sta b_col
    lda lives
    lsr
    lsr
    lsr
    lsr
    jsr bput
    inc b_col
    lda lives
    and #$0F
    jmp bput
.endproc

; bonus_frame: one frame of the bonus game (called instead of the normal play loop).
.proc bonus_frame
    lda bonus_phase
    cmp #2
    bne :+
    jmp @play
:   cmp #3
    bne :+
    jmp @walk
:   cmp #4
    beq @climbup
    cmp #6
    beq @climbdn
    jmp @award
@climbup:
    jsr b_erase
    jsr b_fixgap
    dec spr_y                    ; up the ladder 1px/frame
    jsr @clstep
    lda b_gap                    ; reached the top floor?
    jsr @floory
    cmp spr_y
    bne @cdone
    lda b_gap
    sta b_floor
    lda #MUS_BWALK               ; the walk-to-prize tune (GB state $17 -> $dfe8=$0A)
    jsr mus_start
    lda #3
    sta bonus_phase
@cdone:
    rts
@climbdn:
    jsr b_erase
    jsr b_fixgap
    inc spr_y
    jsr @clstep
    lda b_gap
    ina
    jsr @floory
    cmp spr_y
    bne @cdone
    lda b_gap
    ina
    sta b_floor
    lda #MUS_BWALK               ; the walk-to-prize tune (GB state $17 -> $dfe8=$0A)
    jsr mus_start
    lda #3
    sta bonus_phase
    rts
@clstep:                         ; ladder redrawn under him + climb-ish pose
    lda #0
    ldy b_gap
    jsr b_ladder_cell
    lda spr_y
    lsr
    lsr
    lsr
    and #1
    sta mario_frame
    jmp draw_player
@floory:                         ; A = floor n -> A = its spr_y (40 + 24n = 8n + 16n + 40)
    asl
    asl
    asl
    sta tmpH3                    ; 8n
    asl                          ; 16n
    clc
    adc tmpH3
    clc
    adc #40
    rts
@play:
    lda b_ladder                 ; A while a ladder is visible (odd counter) -> lock it in
    and #1
    beq @tick
    lda pad_pressed
    and #GB_A
    beq @tick
    lda b_ladder                 ; locked: remember the gap, walk to the pedestal
    dea
    lsr
    sta b_gap
    lda #3
    sta bonus_phase
    rts
@tick:
    inc b_tick
    lda b_tick
    cmp #4                       ; harness-measured vs the original: ~4 frames visible +
    beq :+                       ; ~4 blank per gap slot, 24-frame full cycle (was 3/18)
    rts
:   stz b_tick
    lda b_ladder                 ; erase the currently shown ladder (odd) / advance
    and #1
    beq @showit
    lda b_ladder                 ; visible now -> erase it at its gap
    dea
    lsr
    tay
    lda #1
    jsr b_ladder_cell
    bra @cycle
@showit:
    lda b_ladder                 ; hidden -> the NEXT odd shows at gap ((n)/2 mod 3)
@cycle:
    inc b_ladder
    lda b_ladder
    cmp #7
    bcc :+
    lda #1
    sta b_ladder
:   and #1
    beq @mario
    lda b_ladder                 ; became visible: draw at its gap
    dea
    lsr
    tay
    cpy #3
    bcs @mario
    lda #0
    jsr b_ladder_cell
@mario:
    jsr b_erase                  ; Mario cycles DOWN a floor per tick (wraps to the top)
    jsr b_fixfloor               ; (the erase blanks floor cells under him -- repaint)
    lda b_floor
    ina
    and #3
    sta b_floor
    jsr b_sety
    jsr draw_player
    rts
@walk:
    jsr b_erase                  ; walk right 1px/frame to the pedestal (x=128)
    jsr b_fixfloor               ; repaint the floor bricks he just passed over
    lda #0                       ; and keep the locked ladder intact (its end cells sit ON
    ldy b_gap                    ; floor rows, so the erase/repair above clips them)
    jsr b_ladder_cell
    inc spr_x
    lda spr_x
    sta mario_vx
    lsr
    lsr
    lsr
    and #1                       ; simple 2-frame walk cycle
    ina
    sta mario_frame
    jsr draw_player
    lda spr_x
    cmp #80                      ; at the ladder column?
    bne @notlad
    lda b_floor                  ; ladder top at his floor -> climb DOWN; bottom -> UP
    cmp b_gap
    bne :+
    lda #6                       ; climb down to floor gap+1
    sta bonus_phase
    rts
:   lda b_gap
    ina
    cmp b_floor
    bne @notlad
    lda #4                       ; climb up to floor gap
    sta bonus_phase
    rts
@notlad:
    lda spr_x
    cmp #128
    bcc @wdone
    lda #5                       ; reached the prize -> stand there ~68 frames, then the
    sta bonus_phase              ; original does a hard CUT to the top-centre and hops
    lda #68                      ; (harness capture: (128,128) f116-183 -> (88,56) f184)
    sta b_awt
    lda #MUS_BAWARD              ; the award celebration (GB state $1A -> $dfe8=$0D)
    jsr mus_start
    ldx b_floor
    lda b_prz,x
    cmp #$E5                     ; flower?
    beq @flower
    and #$0F                     ; tile $01/$02/$03 = that many lives
    sta b_awn
@wdone:
    rts
@flower:
    lda #MUS_BAWARD              ; the award celebration (same GB award state $1A)
    jsr mus_start
    lda #10                      ; flower: awarded IN PLACE at the pedestal
    sta bonus_phase
    lda #1
    sta mario_superball          ; the superball power always
    lda mario_big
    bne :+
    lda #$50                     ; small -> the grow flash plays at the pedestal
    sta mario_grow
    lda #SFX_DFE0_04             ; the powerup-pickup sound (user-ID'd)
    jsr sfx_play
:   stz b_awn
    lda #120
    sta b_awt
    rts
@award:
    lda bonus_phase
    cmp #5
    bne :+
    jmp @wback
:   cmp #10
    bne :+
    jmp @flowert
:   cmp #11
    bne :+
    dec b_awt                    ; the celebration's tail pause
    bne @adone
    jmp @exit
:
    ; ---- phase 8: the JOY HOP at the top-centre (1px/4f, life at the APEX) ----
    dec b_awt
    bne @adone
    lda #4
    sta b_awt
    lda b_awn
    ora b_gap
    beq @exit0
    lda b_gap
    cmp #5
    bcc @rise
    beq @apex
    cmp #11
    bcc @fall
    stz mario_frame              ; step 11: standing beat between hops
    jsr b_erase
    jsr b_fixfloor
    jsr b_fixhud
    jsr draw_player
    stz b_gap
    rts
@rise:
    lda #3
    sta mario_frame
    jsr b_erase
    jsr b_fixfloor
    jsr b_fixhud
    dec spr_y
    jsr draw_player
    inc b_gap
    rts
@apex:
    lda b_awn
    beq :+
    jsr add_life_snd             ; the 1UP chirp at every hop apex ($dfe0=$08 x lives,
    dec b_awn                    ; 44f apart -- harness-captured; was silent)
:   inc b_gap
    rts
@fall:
    lda #3
    sta mario_frame
    jsr b_erase
    jsr b_fixfloor
    jsr b_fixhud
    inc spr_y
    jsr draw_player
    inc b_gap
    rts
@exit0:
    lda #11                      ; ~70-frame tail pause in its own phase, then leave
    sta bonus_phase
    lda #70
    sta b_awt
@adone:
    rts
    ; ---- phase 5: stand at the pedestal ~68 frames, then the CUT to the top-centre ----
@wback:
    dec b_awt
    beq @cut
    rts
@cut:
    stz mario_frame              ; erase him at the pedestal, repaint the floor there,
    jsr b_erase                  ; and reappear at the top-centre in one frame -- exactly
    jsr b_fixfloor               ; the original's hard cut (no walk, no climb)
    lda #80
    sta spr_x
    sta mario_vx
    lda #40
    sta spr_y
    stz b_floor
    stz mario_facing
    jsr b_fixfloor               ; (top floor cells under the new spot)
    jsr draw_player
    lda #8
    sta bonus_phase
    stz b_gap
    lda #4
    sta b_awt
    rts
    ; ---- phase 10: the flower -- Mario STAYS at the pedestal (user-observed); if he
    ; was small, the GROW FLASH plays right there, then the pause and out ----
@flowert:
    lda mario_grow
    beq @ftimer
    dec mario_grow               ; the 80-frame big<->small flash (draw_player renders it)
    bne :+
    inc mario_big                ; flash done -> big (superball was granted at the trigger)
:   jsr b_erase
    jsr b_fixfloor
    jsr draw_player
    rts
@ftimer:
    dec b_awt
    bne @adone2
    jmp @exit
@adone2:
    rts
@exit:
    stz bonus_phase
    jmp next_level
.endproc
.segment "CODE"

; ---------------------------------------------------------------------------
.segment "VECTORS"
    .addr nmi                ; $FFFA
    .addr reset              ; $FFFC
    .addr irq                ; $FFFE
