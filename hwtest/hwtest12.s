; hwtest12: VRAM DMA dissection (the fb_shift8 garble hunt).
; Canvas: gray HUD band (rows 0-15, never touched by any test), playfield =
; 8px vertical stripes with a fat black bar mid-screen. A correct left-shift
; moves everything 32px left (bar included) with no noise.
; Buttons (one action per press):
;   RIGHT = game-exact fb_shift8 (two DMAs back-to-back, no wait)
;   LEFT  = chunk 1 only (single overlapping DMA, lines 16-95)
;   UP    = chunk 1, ~50k-cycle delay, chunk 2 (completion-wait probe)
;   DOWN  = non-overlapping DMA: copy lines 16-31 over lines 128-143
;   A     = CPU-copy shift of lines 16-95 (the correct reference look)
;   B     = redraw the canvas (reset between trials)
.segment "ZEROPAGE"
ptr:  .res 2
ptr2: .res 2
lin:  .res 1
prev: .res 1
cur:  .res 1

DMA_SRC_LO = $2008
DMA_SRC_HI = $2009
DMA_DST_LO = $200A
DMA_DST_HI = $200B
DMA_LEN    = $200C
DMA_CTRL   = $200D

.segment "CODE"

; --- draw the canvas ---
canvas:
    stz ptr                      ; HUD band rows 0..15 = $55 gray
    lda #$40
    sta ptr+1
    ldx #3                       ; 3 pages = 768 = 16*48
    ldy #0
    lda #$55
@h: sta (ptr),y
    iny
    bne @h
    inc ptr+1
    dex
    bne @h
    lda #<$4300                  ; playfield rows 16..159
    sta ptr
    lda #>$4300
    sta ptr+1
    lda #144
    sta lin
@line:
    ldy #0
@col:
    cpy #40
    bcs @margin
    cpy #20
    bcc @stripe
    cpy #28
    bcs @stripe
    lda #$FF                     ; bytes 20..27: the fat black bar
    bra @put
@margin:
    lda #$AA                     ; off-screen margin: checker
    bra @put
@stripe:
    tya
    lsr
    and #1
    beq @white
    lda #$FF
    bra @put
@white:
    lda #$00
@put:
    sta (ptr),y
    iny
    cpy #48
    bne @col
    lda ptr
    clc
    adc #48
    sta ptr
    bcc :+
    inc ptr+1
:   dec lin
    bne @line
    rts

; --- DMA helpers ---
dma_chunk1:                      ; $4308 -> $4300, 3840 bytes (lines 16..95)
    lda #$08
    sta DMA_SRC_LO
    lda #$43
    sta DMA_SRC_HI
    stz DMA_DST_LO
    lda #$43
    sta DMA_DST_HI
    lda #240
    sta DMA_LEN
    lda #$80
    sta DMA_CTRL
    rts
dma_chunk2:                      ; $5208 -> $5200, 3072 bytes (lines 96..159)
    lda #$08
    sta DMA_SRC_LO
    lda #$52
    sta DMA_SRC_HI
    stz DMA_DST_LO
    lda #$52
    sta DMA_DST_HI
    lda #192
    sta DMA_LEN
    lda #$80
    sta DMA_CTRL
    rts
longdelay:                       ; ~50k cycles
    ldx #40
@o: ldy #0
@i: dey
    bne @i
    dex
    bne @o
    rts

; --- the trials ---
t_game:                          ; RIGHT: exactly what the game does
    jsr dma_chunk1
    jmp dma_chunk2
t_one:                           ; LEFT: single overlapping DMA
    jmp dma_chunk1
t_wait:                          ; UP: chunk1 .. long delay .. chunk2
    jsr dma_chunk1
    jsr longdelay
    jmp dma_chunk2
t_copy:                          ; DOWN: non-overlap, lines 16-31 -> 128-143
    lda #<$4300
    sta DMA_SRC_LO
    lda #>$4300
    sta DMA_SRC_HI
    lda #<$5800
    sta DMA_DST_LO
    lda #>$5800
    sta DMA_DST_HI
    lda #48                      ; 768 bytes
    sta DMA_LEN
    lda #$80
    sta DMA_CTRL
    rts
t_cpu:                           ; A: CPU-copy shift, lines 16..95 (reference)
    lda #<$4300
    sta ptr
    lda #>$4300
    sta ptr+1
    lda #80
    sta lin
@line:
    lda ptr
    clc
    adc #8
    sta ptr2
    lda ptr+1
    adc #0
    sta ptr2+1
    ldy #0
@b: lda (ptr2),y
    sta (ptr),y
    iny
    cpy #40
    bne @b
    lda ptr
    clc
    adc #48
    sta ptr
    bcc :+
    inc ptr+1
:   dec lin
    bne @line
    rts

reset:
    ldx #$FF
    txs
    cld
    sei
    lda #$A0
    sta $2000
    lda #$A0
    sta $2001
    stz $2002
    stz $2003
    lda #$DF
    sta $2026
    lda #$0F
    sta $2022
    lda #$00
    sta $2010
    sta $2011
    sta $2012
    sta $2013
    sta $2014
    sta $2015
    sta $2016
    sta $2017
    sta $201C
    sta $201B
    sta $2028
    sta $2029
    sta $202A
    jsr canvas
    stz prev
main:
    lda $2020                    ; active low -> active high
    eor #$FF
    sta cur
    eor #$FF                     ; new presses = cur & ~prev
    ora prev
    eor #$FF
    tax                          ; X = newly pressed bits
    lda cur
    sta prev
    txa
    and #$01                     ; RIGHT
    beq :+
    jsr t_game
:   txa
    and #$02                     ; LEFT
    beq :+
    jsr t_one
:   txa
    and #$08                     ; UP
    beq :+
    jsr t_wait
:   txa
    and #$04                     ; DOWN
    beq :+
    jsr t_copy
:   txa
    and #$20                     ; A
    beq :+
    jsr t_cpu
:   txa
    and #$10                     ; B
    beq :+
    jsr canvas
:   ldy #0                       ; small debounce breath
@d: dey
    bne @d
    jmp main

nmi:
irq:
    rti

.segment "VECTORS"
    .addr nmi, reset, irq
