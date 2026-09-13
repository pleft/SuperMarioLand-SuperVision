; ---------------------------------------------------------------------------
; INTRO -- the port's own pre-title boot splash (docs/48), in the spirit of the
; Watara Supervision / Travellmate boot logo but ORIGINAL: on a white screen,
; "ELEFAS-" slides in from the left and "RETRODEV" from the right, both on the
; screen's middle row, and meet in the centre; then a rising C-E-G-C major
; arpeggio chimes on square 1; it holds, then the title runs.
;
; It is stored in a free 512K page (13). reset maps that page and JSRs its
; $8000; the stub below (running there) copies the whole blob into the $1500 RAM
; overlay window, jumps into that copy, maps bank 0 back (so the HUD font at
; bg_chardata is readable and the title is reachable) and runs. It calls the
; always-mapped FIXED primitives (set_dst/get_tile_src/blit_tile/blit_blank/
; bank_set) via the engine ABI, exactly like the W2/W3/E43 overlays. Keeping the
; relocation here (not in reset) keeps the FIXED bank within budget. The blob
; must stay <= 256 bytes (the stub copies one page) -- asserted at the end.
; ---------------------------------------------------------------------------
.setcpu "65C02"
.include "w2abi.inc"             ; engine addresses (dcol, dy, set_dst, blit_tile,
                                 ; get_tile_src, blit_blank, frame_flag, bank_set, tmpL..)

CH1_FLO     = $2010              ; square 1 (supervision.inc); the jingle owns it,
CH1_FHI     = $2011              ; then silences it before returning
CH1_VOLDUTY = $2012              ; bit6 enable | bits5:4 duty | bits3:0 volume
CH1_LEN     = $2013

ROW_Y       = 72                ; the words' scanline (screen middle: row 9)
NLETTERS    = 15                ; "ELEFAS-" (7) + "RETRODEV" (8)
NLEFT       = 7
LEFT_END    = 4                 ; final dcol of the left word  (cols 2..8)
RIGHT_END   = 18                ; final dcol of the right word (cols 9..16)
STEPS       = 30                ; both words travel 30 dcol (4 px) steps
LEFT_START  = <(LEFT_END - STEPS)   ; 230: entirely off the left edge (wraps in)
RIGHT_START = RIGHT_END + STEPS     ; 48:  entirely in / past the off-screen margin

; zero-page scratch (engine ABI): tmpL = letter index, tmpH = op (0 draw / 1 blank),
; tmpL2 = left word dcol, tmpH2 = right word dcol, tmpH3 = jingle counter.

.segment "INTRO"                ; page 13 $8000 (run there first), then $1500

; --- self-relocation stub: entry at $8000 (page 13 mapped). Copy the blob into
;     the $1500 window (one page), then jump into that copy. ---
    ldx #0
@reloc:
    lda $8000,x
    sta $1500,x
    inx
    bne @reloc
    jmp run                      ; absolute $1500-region label (now populated)

run:
    lda #0
    jsr bank_set                 ; map bank 0: the HUD font + title live there
    jsr clear_vram               ; white screen for the splash
    lda #LEFT_START
    sta tmpL2
    lda #RIGHT_START
    sta tmpH2
@slide:
    jsr wait1                    ; one 4 px step every 2 frames: ~1.2 s for the slide
    jsr wait1
    lda #1
    sta tmpH
    jsr words                    ; erase both words at their old positions
    inc tmpL2                    ; left word moves right, right word moves left
    dec tmpH2
    stz tmpH
    jsr words                    ; draw both at the new positions
    lda tmpL2
    cmp #LEFT_END
    bne @slide                   ; (the right word arrives the same step)
    stz tmpH3                    ; NOW that they have met, play the chime, then hold
    ldx #64                      ; hold the settled tag while the chime rings out
@hold:
    jsr wait1
    phx                          ; jingle clobbers X (note index) -- keep the hold count
    jsr jingle
    plx
    dex
    bne @hold
    stz CH1_FLO                  ; return square 1 to its boot state (FLO/LEN/VOLDUTY
    stz CH1_LEN                  ; = 0) so the level starts exactly as before the splash
    stz CH1_VOLDUTY              ; existed -- a leftover CH1 state nudges a W3 object's
    jsr clear_vram               ; phase (E-gate). Then clear + run the SML title (waits
    jmp title_screen             ; for Start, sets cur_level) and return to reset

; --- words: draw (tmpH=0) or white-fill (tmpH=1) all 15 tiles at their current
;     positions. Tile i < NLEFT sits at tmpL2 + 2i, the rest at tmpH2 + 2(i-7).
;     A tile whose dcol is >= 47 (off the left edge, wrapped, or past the ring
;     margin) is skipped: it would land on another line. ---
.proc words
    stz tmpL
@l:
    lda tmpL
    cmp #NLEFT
    bcc @left
    sbc #NLEFT                   ; C set: i - 7
    asl                          ; (<= 14, C clear)
    adc tmpH2
    bra @have
@left:
    asl                          ; (<= 12, C clear)
    adc tmpL2
@have:
    cmp #47                      ; a tile is 2 bytes: dcol 47 would wrap its 2nd byte
    bcs @skip                    ; onto the NEXT line's byte 0 (a 4 px ghost at x=0)
    sta dcol
    lda #ROW_Y
    sta dy
    jsr set_dst
    lda tmpH
    bne @blank
    ldx tmpL
    lda letters,x
    jsr get_tile_src
    jsr blit_tile
    bra @skip
@blank:
    jsr blit_blank
@skip:
    inc tmpL
    lda tmpL
    cmp #NLETTERS
    bne @l
    rts
.endproc

; --- wait one displayed frame (the NMI drives frame_flag) ---
.proc wait1
    lda frame_flag
    beq wait1
    stz frame_flag
    rts
.endproc

; --- one rising note every 4 frames (C-E-G-C), sustained into the next ---
.proc jingle
    lda tmpH3
    cmp #24
    bcs @done
    inc tmpH3
    lda tmpH3
    and #3
    bne @done                    ; only on multiples of 4 (frames 4/8/12/16)
    lda tmpH3
    lsr
    lsr                          ; /4 -> 1,2,3,4,5
    sec
    sbc #1                       ; note index 0..
    cmp #4
    bcc @play                    ; 0..3 -> play a note
    lda #$40                     ; index 4 (frame 20) -> silence, crisp end
    sta CH1_VOLDUTY
    rts
@play:
    tax
    lda notes,x
    sta CH1_FLO
    stz CH1_FHI
    lda #$FF
    sta CH1_LEN
    lda #$6E                     ; enable | duty 2 | vol 14
    sta CH1_VOLDUTY
@done:
    rts
.endproc

letters: .byte $0E,$15,$0E,$0F,$0A,$1C,$29,$1B,$0E,$1D,$1B,$18,$0D,$0E,$1F
         ; E L E F A S - R E T R O D E V (HUD font, A=$0A..Z=$23, '-'=$29)
notes:   .byte 235,186,157,117           ; C5 E5 G5 C6 (period ~122900/Hz)

.assert * - $1500 <= 256, error, "intro blob exceeds the 256-byte page the stub copies"
