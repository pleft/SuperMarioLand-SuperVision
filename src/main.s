; Super Mario Land — Watara Supervision port.
; Phase 5: boot + NMI frame loop + input + software renderer (accurate Mario sprite).
; Hardware per docs/20-supervision-hardware.md; port plan per docs/21-port-mapping.md.

.setcpu "65C02"
.include "supervision.inc"
.import chardata             ; OBJ tiles (src/gfxdata.s) — also the $8800 BG tiles $80-$FF
.import bg_chardata          ; BG tiles (level tiles $00-$7F)
.import level_hdr            ; level header: map/cols/rooms/pipes/blocks/spawns (leveldata.s);
                             ; same address in EVERY bank — load_level binds the engine to it
.import jumparc              ; Mario's jump arc table (27 bytes; $7F = apex)
.import speedtab            ; horizontal walk speed table (px/frame)
.import mario_poses          ; 6 poses x 4 tiles (metasprite tiles from ROM $4C37)
.import mario_big_poses      ; 7 big-Mario poses x 4 tiles (stand,walkA,walkB,jump,skid,walkC,duck)
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
plats_on:    .res 1          ; end-area moving platforms spawned (one-shot)
ride:        .res 1          ; 0 = not riding; else (slot+1) of the platform under Mario
bonus_phase: .res 1          ; bonus game: 0 off, 2 play, 3 walk, 5 award
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
; --- per-level bindings, set by load_level from the current bank's level_hdr ---
cur_level:   .res 1          ; level id 0.. (GB $ffe4); selects the ROM bank
surf_map:    .res 2          ; surface tilemap base (map_base resets to this)
lvl_cols:    .res 2          ; level width in columns
cam_max:     .res 2          ; max scroll = (lvl_cols - 20) * 8 px
fbmax_col:   .res 2          ; last fb_col0 with cols fb_col0..+23 inside the level
room_tbl:    .res 6          ; up to 3 underground-room map pointers
pipe_cnt:    .res 1          ; pipe entries in pipe_tab
pipe_tab:    .res 15         ; RAM copy: 5 bytes/pipe, up to 3 pipes
block_tab:   .res 40         ; RAM copy: 4 bytes/block, up to 10 ?-block entries
spawn_tab:   .res 256        ; RAM copy: 4 bytes/spawn + $FFFF sentinel
revpix:      .res 256        ; reverse the 4 2bpp pixels in a byte (built at boot)
flipbuf:     .res 16         ; row-reversed tile scratch for the Y-flipped corpse draw
tile_mod:    .res 640        ; "modified" bitmap, 1 bit per surface (col,row): used ?-block / broken brick
; --- object slots (items / coin-pop / brick debris). SoA, 8 entries (a brick break spawns
;     4 debris pieces on top of whatever item is live). ---
o_type:      .res 8          ; 0 free, else OBJ_*
o_xl:        .res 8          ; world pixel X (16-bit)
o_xh:        .res 8
o_y:         .res 8          ; world pixel Y (same space as spr_y: feet line)
o_vx:        .res 8          ; signed velocity X
o_vy:        .res 8          ; signed velocity Y (gravity / phase)
o_tmr:       .res 8          ; state timer / lifetime
o_pvx:       .res 8          ; last drawn VRAM pixel X (for erase)
o_pvy:       .res 8          ; last drawn VRAM pixel Y
o_pdr:       .res 8          ; was drawn last frame?
o_st:        .res 8          ; sub-state (star: vy ramp index; debris: jump-arc index)
o_pw:        .res 8          ; last drawn width in tile cols (2 = one quad, 3 = popup pair)
o_pfr:       .res 8          ; anim token at the last draw (flip/twinkle cadence dirty test)
o_nvx:       .res 8          ; this frame's computed screen x (render_all pass 1)
o_ndy:       .res 8          ; this frame's computed dy
o_nfl:       .res 8          ; bit0 = dirty, bit1 = visible (render_all flags)
o_hp:        .res 8          ; extra hits to survive (fly: 1 -- two balls kill, user/GB)

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
    stz scroll_vis
    stz XSCROLL
    stz YSCROLL

    jsr build_revpix             ; pixel-reverse lookup for horizontal sprite flip
    jsr clear_vram
    jsr title_screen             ; the SML title (extracted at build time); waits for Start
    jsr clear_vram
    stz cur_level                ; a fresh game starts at 1-1 (bank 0)
    jsr load_level               ; map the bank + bind level pointers/limits to its header
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
    lda #MUS_LEVEL               ; the 1-1 tune (the original writes track $07 from the
    jsr mus_start                ; per-level table at bank0 $07CE on level entry)
    cli

main_loop:
    lda frame_flag
    beq main_loop
    stz frame_flag
    ; ==== FRAME-START RENDER (the beam is in the HUD rows for the first ~4096 cyc, and
    ; above any sprite for much longer: everything drawn here can't be caught mid-blit).
    ; Uses the state the LOGIC phase computed last frame. ====
    jsr sfx_tick                 ; sound streams run every frame, all modes
    jsr mus_tick                 ; the music sequencer too (self-gated while paused)
    lda bonus_phase              ; the bonus game and pipe animations own their own drawing
    ora pipe_phase
    beq :+
    lda scroll_s
    sta scroll_vis
    jmp @skiprender
:   jsr scroll_apply             ; shift decision + DMA + fb_col0 + scroll_s, ALL here at
    lda scroll_s                 ; frame start: pixels, coords and the scroll register mutate
    sta scroll_vis               ; together, and the logic phase only ever sees coherent state
    jsr render_all               ; sprites: overlap-safe erase set -> erases -> draws
    lda shift_px                 ; a shift queues its 4 margin columns
    beq :+
    lda #4
    sta stream_pend
:   lda stream_pend
    beq :+
    jsr stream_one               ; one margin column per frame (right edge, mostly off-screen)
    dec stream_pend
:   lda hud_dirty
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
    and #GB_START                ; state<$0e gate; the bonus is not pausable)
    beq @nopause
    lda bonus_phase
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
    lda #MUS_LEVEL               ; music back via the level table ($1F1C -> $07A3):
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
    jsr plats_check              ; entering the end area? spawn the two moving platforms
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

; read_map_tile: A = map_base[feet_col][mrow] (the raw tile), or $00 if the row is off-map.
.proc read_map_tile
    lda mrow
    cmp #16
    bcs @off
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
    bne @ret
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
    cmp #$80                     ; only $80/$81 ?-blocks become the used block; anything else
    bcc @keep                    ; (a mod bit that bled onto a blank/wall/coin-row tile in a
    lda #$7F                     ; room) is left RAW, so it can never turn into a solid block
@keep:
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
    jsr spawn_bounce             ; the block hops as a sprite while the outcome resolves
    jsr find_block               ; C=1,A=value if this block is in the contents table
    bcc @coin
    cmp #$c0                     ; multi-coin: special lifecycle, NOT marked used yet
    beq @multicoin
    pha
    jsr mark_used                ; one-shot block -> used ($7F) + redraw
    pla
    cmp #$28                     ; $28 = power-up block
    beq @powerup
    cmp #$2a                     ; $2a = 1-up heart
    beq @heart
    cmp #$2c                     ; $2c = star
    beq @star
    bra @coinspawn               ; unknown listed value -> coin (defensive)
@powerup:                        ; SML size rule: big Mario gets a Superball Flower, small a Mushroom
    lda mario_big
    bne @flower
    lda #OBJ_MUSH
    jsr spawn_walker
    rts
@flower:
    jsr spawn_flower
    rts
@heart:
    lda #OBJ_HEART               ; walks exactly like the mushroom (types $2A/$2B == $28/$29)
    jsr spawn_walker
    rts
@star:
    jsr spawn_star
    rts
@coin:
    jsr mark_used
@coinspawn:
    jsr spawn_coin               ; coin-pop animation
    jsr award_coin               ; +1 coin, +100 score, 1-up at 100
    rts
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
.proc find_block
    ldx #0
@loop:
    lda block_tab,x
    cmp feet_col
    bne @next
    lda block_tab+1,x
    cmp feet_col+1
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
    cmp #$F4                     ; coins are walk-through (collectible), not floor
    beq @no
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
    lda mario_big                ; SMALL Mario is a 12px box: an overhang at his head row
    beq @low                     ; doesn't block him (original: he walks under 1-gap ledges)
    jsr read_solid
    bne @yes
@low:
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
    jsr read_solid
    beq @unsup                    ; A==0 -> not supported -> fall
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
    beq @apex
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
    cmp #$60
    bcc @noceil                   ; < $60 -> not solid -> keep rising
    cmp #$F4
    beq @noceil                   ; coin -> walk-through (grabbed by coin_collect), not a ceiling
    cmp #$80                      ; $80/$81 = ?-block (content decided by the block table)
    beq @qblock
    cmp #$81
    beq @qblock
    cmp #$82                      ; $82 = breakable brick
    beq @brick
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
    lda mario_big                 ; small Mario can't break bricks -> the brick just hops
    bne @smash
    lda #$82
    jsr spawn_bounce
    lda #SFX_DFE0_07              ; small Mario bonking a brick: the same thud
    jsr sfx_play
    bra @bonk
@smash:
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
    lda #MUS_LEVEL               ; level restart -> the music restarts from the top
    jsr mus_start
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
    dec goal_tmr                 ; phase 4: end hold -> next level (or the bonus game)
    bne @done
    lda goal_top                 ; top door -> the ladder bonus game first
    beq @next
    stz goal_phase
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
    jsr bonus_start
    lda #2
    sta bonus_phase
    rts
@next:
    jmp next_level
@ring: .byte $00,$01,$02,$E5,$03,$01,$02,$E5
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

; ---------------------------------------------------------------------------
; BONUS GAME (top-door exit). RE: docs/14 "Bonus game RE" — screen drawn by code
; (states $12/$13), prizes = tiles $01/$02/$03 (1/2/3-UP) + $E5 (flower) in a random
; rotation; Mario on a random floor; every-3-frames tick: the ladder blinks around the
; 3 inter-floor gaps while Mario cycles down a floor; A registers only while a ladder
; is visible; then Mario walks right to the pedestal and the prize is awarded.
; (Port simplification: Mario takes his own floor's prize — the traced run also went
; walk->award with no climb. Climb states $18/$19 not modeled.)

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
    lda mus_lt_lo,x
    clc
    adc #<music_data
    sta mus_lt
    lda mus_lt_hi,x
    adc #>music_data
    sta mus_lt+1
    lda mus_l1_lo,x
    clc
    adc #<music_data
    sta mus_list
    lda mus_l1_hi,x
    adc #>music_data
    sta mus_list+1
    lda mus_l2_lo,x
    clc
    adc #<music_data
    sta mus_list+12
    lda mus_l2_hi,x
    adc #>music_data
    sta mus_list+1+12
    lda mus_l3_lo,x
    clc
    adc #<music_data
    sta mus_list+24
    lda mus_l3_hi,x
    adc #>music_data
    sta mus_list+1+24
    lda mus_l4_lo,x
    clc
    adc #<music_data
    sta mus_list+36
    lda mus_l4_hi,x
    adc #>music_data
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
    adc #<music_data
    sta mus_pos,x
    pla
    adc #>music_data
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
    adc #<music_data
    sta mus_list,x
    pla
    adc #>music_data
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
    adc #<music_data
    sta mus_pos,x
    pla
    adc #>music_data
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
    adc #<music_data
    sta mus_list,x
    pla
    adc #>music_data
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
    adc #<(music_data+MUS_DRUMS)
    sta tmpL
    lda #0
    adc #>(music_data+MUS_DRUMS)
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
    adc #<music_data
    sta mus_pos,x
    pla
    adc #>music_data
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
    adc #<music_data
    sta mus_list,x
    pla
    adc #>music_data
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
.endproc

mus_zero: .byte 0                ; mus_start seeds phrase ptrs here ("fetch next phrase")

.segment "LEVELS"
.include "../build/audio/sfx.inc"
sfx_data:
    .incbin "../build/audio/sfx.bin"
.include "../build/audio/music.inc"
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
.endproc

; next_level: level complete — advance to the next level (GB State_08: $ffe4+1) and
; start it FRESH from column 0. Score, coins, lives and Mario's power-ups
; (big/superball) PERSIST; everything level-local resets. Levels shipped so far:
; 1-1 and 1-2 — the wrap constant grows as more of World 1 comes online.
NUM_LEVELS = 2
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
    lda #MUS_LEVEL               ; fresh level -> the tune from the top
    jsr mus_start
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
    lda #MUS_LEVEL
    jsr mus_start
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
    ldx cur_level                ; "W-S" under WORLD (row 1 cols 12/14; the '-' is
    lda world_tab,x              ; static in the template)
    ldx #12
    jsr put_hud
    ldx cur_level
    lda stage_tab,x
    ldx #14
    jsr put_hud
    stz hud_dirty
    rts
world_tab: .byte 1,1,1,2,2,2,3,3,3,4,4,4   ; level id -> displayed world digit
stage_tab: .byte 1,2,3,1,2,3,1,2,3,1,2,3   ; level id -> displayed stage digit
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
    txa                          ; dbcol = 40 + x*2
    asl
    clc
    adc #40
    sta dbcol
    jmp draw_column
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
PLATV_X    = 2280                ; vertical platform: fixed world x (dedicated trace: OAM x 48)
PLATV_YT   = 56 + 8              ; o_y bounds (o_y = world top + 8); patrol top..bottom exact
PLATV_YB   = 116 + 8             ;   from the standing-still trace: OAM y 72..132, 120f half-period
PLATH_Y    = 32 + 8              ; horizontal platform: fixed o_y (OAM y 48)
PLATH_X0   = 2291                ; patrol left..right world x, exact (trace: OAM x 59..112,
PLATH_X1   = 2344                ;   106-frame half-period; both at 0.5px/frame)
PLATS_AT   = 2120                ; spawn both once the camera reaches this (they enter view)
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
                                 ; the screen (GB type $0D; slot capture: rise 7px, fall to
                                 ; +2px/f, 1px/f sideways drift away from the killer)
FLY_TL     = $A0                 ; 16x16 metasprite, frame A: A0 A1 / B0 B1
FLY_BL     = $B0
FLY_TL2    = $A2                 ; frame B
FLY_BL2    = $B2
FLY_SQ     = $A8                 ; flattened corpse pair $A8+$A9 (param $2C)
FLY_SIT    = 55                  ; trace: ~55 grounded frames between hops
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
    stz plats_on                 ; they respawn when the camera re-enters the end area
    ldx #7
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
    cpx #8
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
    jsr find_free_obj
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
    jsr find_free_obj
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
    jsr find_free_obj
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
    ldx #7                       ; the original keeps debris in 4 FIXED slots ($c218/28/38/48):
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
.proc spawn_popup                ; A = left glyph tile, Y = right glyph tile
    sta tmpL
    sty tmpH
    jsr find_free_obj
    bcs @full
    lda #OBJ_POPUP
    sta o_type,x
    lda cam_x                    ; x = Mario world X - 4 (original: $ffeb = $c202 + $fc)
    clc
    adc spr_x
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda o_xl,x
    sec
    sbc #4
    sta o_xl,x
    lda o_xh,x
    sbc #0
    sta o_xh,x
    lda spr_y                    ; y = Mario Y - 16 (original: $ffec = $c201 - $10)
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

.proc upd_popup
    lda frame_count              ; 1px up every 2nd frame
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
    jsr find_free_obj
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

; --- end-area moving platforms (SML types $0A/$0B: script-driven ping-pong, 1px per
; object-update = 0.5px/frame, no gravity; goal-trace-verified patrol bounds) ---
.proc plats_check
    lda plats_on
    bne @done
    lda cam_x+1                  ; camera reached the end area?
    cmp #>PLATS_AT
    bcc @done
    bne @go
    lda cam_x
    cmp #<PLATS_AT
    bcc @done
@go:
    inc plats_on
    jsr find_free_obj            ; vertical platform (rides Mario up to the high route)
    bcs @h
    lda #OBJ_PLATV
    sta o_type,x
    lda #<PLATV_X
    sta o_xl,x
    lda #>PLATV_X
    sta o_xh,x
    lda #PLATV_YB                ; start at the bottom of its patrol
    sta o_y,x
    lda #1                       ; moving up first (toward the high route)
    sta o_st,x
@h:
    jsr find_free_obj            ; horizontal platform (carries Mario to the top door)
    bcs @done
    lda #OBJ_PLATH
    sta o_type,x
    lda #<PLATH_X0
    sta o_xl,x
    lda #>PLATH_X0
    sta o_xh,x
    lda #PLATH_Y
    sta o_y,x
    stz o_st,x                   ; moving right first
@done:
    rts
.endproc

; upd_platv: ping-pong o_y between PLATV_YT..PLATV_YB; carry Mario when riding this slot.
.proc upd_platv
    lda frame_count
    lsr
    bcc :+
    rts
:   ldx oi
    lda o_st,x
    bne @up
    inc o_y,x                    ; down
    jsr carry_y_dn
    ldx oi
    lda o_y,x
    cmp #PLATV_YB
    bcc @done
    lda #1
    sta o_st,x
@done:
    rts
@up:
    dec o_y,x
    jsr carry_y_up
    ldx oi
    lda o_y,x
    cmp #PLATV_YT+1              ; turn exactly AT the traced top endpoint (inclusive)
    bcs @done
    stz o_st,x
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

; upd_plath: ping-pong o_x between PLATH_X0..PLATH_X1; carry Mario horizontally.
.proc upd_plath
    lda frame_count
    lsr
    bcc :+
    rts
:   ldx oi
    lda o_st,x
    bne @left
    inc o_xl,x                   ; right
    bne :+
    inc o_xh,x
:   jsr riding_this
    bne :+
    inc spr_x
:   ldx oi
    lda o_xh,x                   ; reached the right bound?
    cmp #>PLATH_X1
    bne @done
    lda o_xl,x
    cmp #<PLATH_X1
    bcc @done
    lda #1
    sta o_st,x
@done:
    rts
@left:
    lda o_xl,x
    bne :+
    dec o_xh,x
:   dec o_xl,x
    jsr riding_this
    bne :+
    dec spr_x
:   ldx oi
    lda o_xh,x                   ; back at the left bound?
    cmp #>PLATH_X0
    bne @done
    lda o_xl,x
    cmp #<PLATH_X0
    bne @done
    stz o_st,x
@done2:
    rts
.endproc

; plat_land: called while FALLING (tmpL = this frame's fall delta). If Mario's feet crossed
; a platform's top this frame and he x-overlaps it, land + ride. Returns A=1 if landed.
.proc plat_land
    stz oi2
@loop:
    ldx oi2
    lda o_type,x
    cmp #OBJ_PLATV
    beq @try
    cmp #OBJ_PLATH
    beq @try
@next:
    inc oi2
    lda oi2
    cmp #8
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
    cmp tmpH
    bcc :+
    bne @next                    ; was already below the top -> no landing
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
:   lda o_xl,x                   ; platform centre = o_x + 12
    clc
    adc #12
    sta tmpL3
    lda o_xh,x
    adc #0
    sta tmpH3
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
    lda tmpL3
    cmp #16
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
    lda spawn_tab+3,y          ; type: Chibibo $00, Nokobon $04, Fly $0E
    beq @chib
    cmp #$04
    bne :+
    jsr spawn_noko
    bra @skip
:   cmp #$0E
    bne @skip
    jsr spawn_fly
    bra @skip
@chib:
    jsr spawn_chib
@skip:
    inc spawn_idx
    bra spawn_check              ; several entries can share a fire column
@done:
    rts
.endproc

.proc spawn_chib                 ; Y = table byte offset (preserved by find_free_obj? no ->
    phy                          ; save it)
    jsr find_free_obj
    ply
    bcs @full
    lda #OBJ_CHIB
    sta o_type,x
    lda cam_x                    ; world x = cam + 180 (original enters at OAM x 188)
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
@full:
    rts
.endproc

.proc spawn_noko
    phy
    jsr find_free_obj
    ply
    bcs @full
    lda #OBJ_NOKO
    sta o_type,x
    lda cam_x
    clc
    adc #180
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda spawn_tab+2,y
    sta o_y,x
    lda #$FF                     ; walks left, same measured speed engine as the Chibibo
    sta o_vx,x
    stz o_st,x
    stz o_tmr,x
@full:
    rts
.endproc

.proc spawn_fly
    phy
    jsr find_free_obj
    ply
    bcs @full
    lda #OBJ_FLY
    sta o_type,x
    lda cam_x                    ; trace: enters at OAM 199 = world cam+191
    clc
    adc #191
    sta o_xl,x
    lda cam_x+1
    adc #0
    sta o_xh,x
    lda spawn_tab+2,y
    sta o_y,x
    lda #$FF                     ; faces/hops left initially
    sta o_vx,x
    stz o_st,x                   ; state: 0 = sitting
    lda #FLY_SIT
    sta o_tmr,x
@full:
    rts
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
.proc enemy_contact
    ldx oi
    lda o_y,x                    ; cull once fallen off the bottom
    cmp #160
    bcc :+
    cmp #240
    bcs :+
    stz o_type,x
    rts
:   lda cam_x                    ; |mario_center - enemy_center| < 10 ?
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
    bcs @done
    lda mario_starT              ; star -> instant kill
    bne @kill
    lda spr_y                    ; STOMP TEST (RE $08C7): Mario at least 4px above
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
    lda #OBJ_SQUASH              ; Chibibo -> squashed corpse ($91)
    sta o_type,x
    lda #CHIB_TB
    sta o_vx,x
    lda #32
    sta o_tmr,x
    stz o_st,x
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
    lda tmpH2
    cmp #4
    bne @done
    lda #SFX_DFF8_03             ; the fly's death sound (user-ID'd) overrides the thud
    jsr sfx_play
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
:   lda #1                       ; thrown away from Mario: he walks into it, so the
    ldy mario_facing             ; drift follows his facing (right -> thrown right)
    beq :+
    lda #$FF
:   jsr kill_flip
    lda tmpH2                    ; base value code, no chain on kills
    jmp award_kill
.endproc

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
.proc award_kill
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
:   ldx #$59                     ; left tile by code: $01->$59 .. $08->$5D
    cmp #$02
    bcc @have
    ldx #$5A
    cmp #$04
    bcc @have
    ldx #$5B
    cmp #$05
    bcc @have
    ldx #$5C
    cmp #$08
    bcc @have
    ldx #$5D
@have:
    txa
    jmp spawn_popup              ; A = left tile, Y = right tile
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
    stz o_type,x
:   rts
.endproc

; title_screen: the original's title, dumped at build time by tools/extract_title.py
; (PyBoy boots the user's ROM and captures the rendered tilemap + tiles). 18 GB rows
; centered on the SV's 20 (rows 1-18). Static; exits on Start.
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
    lda tmpH3                    ; dst: dcol = col*2, dy = (row+1)*8
    asl
    sta dcol
    lda tmpL3
    ina
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
@wait:
    lda frame_flag               ; hold until Start is pressed
    beq @wait
    stz frame_flag
    jsr sfx_tick                 ; the sound test needs the player running
    jsr read_input
    lda pad_pressed              ; SOUND TEST: Select cycles the SFX id, A replays it.
    and #GB_SELECT               ; The id shows as two digits in the top-left corner.
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

.segment "LEVELS"
title_map:                       ; 20x18 remapped indices (build artifact, rule 5)
    .incbin "build/levels/title_map.bin"
title_tiles:                     ; the used tiles, SV-packed
    .incbin "build/gfx/title_tiles.svt"
.segment "CODE"

; ball_active: C=1 if a superball is already live (only one at a time, per the original).
.proc ball_active
    ldx #7
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
    beq @next
@dxok:
    lda tmpL3
    cmp #10
    bcs @next
    ldy oi                       ; dy
    lda o_y,y
    ldx oi2
    sec
    sbc o_y,x
    bpl :+
    eor #$FF
    ina
:   cmp #10
    bcs @next
    lda #$01                     ; value code: walkers 100
    sta tmpH2
    lda o_type,x
    cmp #OBJ_FLY
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
@bnext:
    jmp @next
@next:
    inc oi2
    lda oi2
    cmp #8
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
:   tya
    sta o_tmr,x
    lda #OBJ_CORPSE
    sta o_type,x
    stz o_st,x
    rts
.endproc

; upd_corpse: the captured arc -- corpse_dy for 23 ticks, then +2/frame; x += o_vx
; every frame; despawns off the bottom. No collision with anything.
.proc upd_corpse
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
@next:
    inc oi
    lda oi
    cmp #8
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
    ; ---------- pass 1: classify slots ----------
    stz oi
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
    lda shift_px
    bne @p1dirty
    lda o_pdr,x
    beq @p1dirty
    lda o_nvx,x
    cmp o_pvx,x
    bne @p1dirty
    lda o_ndy,x
    cmp o_pvy,x
    bne @p1dirty
    lda frame_count
    and #8
    cmp o_pfr,x
    beq @p1next
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
    inc oi
    lda oi
    cmp #8
    beq :+
    jmp @p1
:
    ; ---------- Mario: classify ----------
    lda spr_x
    clc
    adc scroll_s
    sta mario_vx
    lda #1
    sta m_dirty
    lda shift_px
    bne @mclassd
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
    lda o_pvx,x                  ; shift-compensated erase at the old drawn spot
    cmp shift_px
    bcs :+
    lda shift_px
:   sec
    sbc shift_px
    sta rb_vx
    lda o_pvy,x
    sta rb_y
    lda o_pw,x
    bpl @short
    and #$7F                     ; TALL (16px) sprite: erase from 8px above, one extra row
    sta rb_cols
    lda o_pvy,x
    sec
    sbc #8
    sta rb_y
    ldy #2
    bra @rows
@short:
    sta rb_cols
    ldy #1
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
    cmp #8
    bne @p3
    lda m_dirty                  ; Mario's erase
    beq @p4s
    lda prev_vx
    cmp shift_px
    bcs :+
    lda shift_px
:   sec
    sbc shift_px
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
    cmp #3                       ; dirty AND visible
    bne @p4n
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
    lda #3
:   cpy #OBJ_NOKO
    bne :+
    lda #$82
:   cpy #OBJ_FLY
    bne :+
    lda #$83                     ; 16 wide + tall
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
:   sta o_pw,x
    lda frame_count
    and #8
    sta o_pfr,x
    lda #1
    sta o_pdr,x
@p4n:
    inc oi
    lda oi
    cmp #8
    bne @p4
    lda m_dirty
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
    lda o_pvx,x
    sec
    sbc o_pvx,y
    bpl :+
    eor #$FF
    ina
:   cmp #32
    bcs @sp_jn
    lda o_pvy,x
    sec
    sbc o_pvy,y
    bpl :+
    eor #$FF
    ina
:   cmp #28
    bcs @sp_jn
    lda o_nfl,y                  ; overlap: j joins the dirty set
    ora #1
    sta o_nfl,y
@sp_jn:
    inc tmpL3
    lda tmpL3
    cmp #8
    bne @sp_j
@sp_in:
    inc oi2
    lda oi2
    cmp #8
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
    lda o_nfl,y
    ora #1
    sta o_nfl,y
@sp_mn:
    inc tmpL3
    lda tmpL3
    cmp #8
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
    cmp #OBJ_COIN
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
    lda o_y,x
    clc
    adc #8
    sta dy
    lda o_tmr,x
    and #4
    php
    ldx #BOOM_TA
    plp
    beq :+
    ldx #BOOM_TB
:   phx
    stz do_flip
    jsr draw_quad                ; left half
    ldx oi
    lda o_y,x
    clc
    adc #8
    sta dy
    lda spr_col
    ina
    ina
    sta dcol                     ; right half = the same tile X-mirrored, 8px right
    lda #1
    sta do_flip
    plx
    jsr draw_quad
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
    lda cur_level                ; map the level's ROM bank at $8000 (level N = bank N).
    asl                          ; Safe mid-proc: load_level sits in the common prefix,
    asl                          ; byte-identical at this address in every bank.
    asl
    asl
    asl
    ora #(SYSCTRL_NMI_EN | SYSCTRL_TIMER_IRQ)
    sta SYS_CTRL
    lda level_hdr+0              ; surface map
    sta surf_map
    lda level_hdr+1
    sta surf_map+1
    lda level_hdr+2              ; width in columns
    sta lvl_cols
    lda level_hdr+3
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
:   lda level_hdr+4,x
    sta room_tbl,x
    dex
    bpl :-
    lda level_hdr+10             ; pipes -> RAM (pipe_cnt * 5 bytes)
    sta lvl_ptr
    lda level_hdr+11
    sta lvl_ptr+1
    lda level_hdr+12
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
    lda level_hdr+13             ; ?-blocks -> RAM (count * 4 bytes)
    sta lvl_ptr
    lda level_hdr+14
    sta lvl_ptr+1
    lda level_hdr+15
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
    lda level_hdr+16             ; spawn list -> RAM (256 bytes; the $FFFF sentinel
    sta lvl_ptr                  ; inside the data ends the live part)
    lda level_hdr+17
    sta lvl_ptr+1
    ldy #0
:   lda (lvl_ptr),y
    sta spawn_tab,y
    iny
    bne :-
    rts
.endproc

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

.segment "LEVELS"            ; bank 0 ($8000, always mapped) -- FIXED is full
row48_lo: .repeat 160, i
          .byte <(i*48)
          .endrepeat
row48_hi: .repeat 160, i
          .byte >(i*48)
          .endrepeat
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
.segment "VECTORS"
    .addr nmi                ; $FFFA
    .addr reset              ; $FFFC
    .addr irq                ; $FFFE
