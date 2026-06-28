; Watara Supervision hardware register definitions.
; Source: docs/20-supervision-hardware.md (kevtris tech doc + GrenderG RE notes).

; ---- Memory regions ----
WRAM      = $0000        ; $0000-$1FFF (8K)  work RAM (zp + stack + general)
VRAM      = $4000        ; $4000-$5FFF (8K)  LCD framebuffer (160x160 2bpp linear)
ROM_BANK  = $8000        ; $8000-$BFFF       switchable 16K cart bank
ROM_FIXED = $C000        ; $C000-$FFFF       fixed (last) 16K cart bank

VRAM_VISIBLE_BYTES  = 40 ; 160 px / 4 px-per-byte (visible part of each line)
VRAM_STRIDE         = $30 ; 48 bytes per scanline in VRAM (Y_Scroll * $30); 8 off-screen
VRAM_LINES          = 160
VRAM_FRAME_BYTES    = VRAM_STRIDE * VRAM_LINES   ; 7680 ($1E00) = 30 pages

; ---- I/O registers ($2000-$202F) ----
LCD_XSIZE   = $2000      ; horizontal pixels (upper bits, 4-px align)
LCD_YSIZE   = $2001      ; scanlines per frame
XSCROLL     = $2002      ; bits7:2 byte offset/line, bits1:0 pixel delay
YSCROLL     = $2003      ; * $30 added to VRAM start

DMA_SRC_LO  = $2008
DMA_SRC_HI  = $2009
DMA_DST_LO  = $200A
DMA_DST_HI  = $200B
DMA_LEN     = $200C      ; length in units of 16 bytes
DMA_CTRL    = $200D      ; bit7 = start

; Sound — square 1 (right), square 2 (left)
CH1_FLO     = $2010
CH1_FHI     = $2011
CH1_VOLDUTY = $2012      ; bit6 enable, bits5:4 duty, bits3:0 volume
CH1_LEN     = $2013
CH2_FLO     = $2014
CH2_FHI     = $2015
CH2_VOLDUTY = $2016
CH2_LEN     = $2017
; DMA audio
DMA_AUD_ADRLO = $2018
DMA_AUD_ADRHI = $2019
DMA_AUD_LEN   = $201A
DMA_AUD_CTRL  = $201B
DMA_AUD_TRIG  = $201C
; Noise
CH4_FREQVOL = $2028      ; bits7:4 freq, bits3:0 vol
CH4_LEN     = $2029
CH4_CTRL    = $202A      ; bit3 enable, bit2 left, bit1 right, bit0 lfsr len

CONTROLLER  = $2020      ; active-LOW: 7Start 6Sel 5A 4B 3Up 2Down 1Left 0Right
LINK_DDR    = $2021
LINK_DATA   = $2022
IRQ_TIMER   = $2023
IRQ_TIMER_RST = $2024    ; read to clear timer IRQ
IRQ_DMA_RST   = $2025    ; read to clear DMA-audio IRQ
SYS_CTRL    = $2026      ; bits7:5 bank, bit4 timer-prescaler, bit2 DMA-IRQ en, bit1 timer-IRQ en, bit0 NMI en
IRQ_STATUS  = $2027      ; bit1 DMA-audio done, bit0 timer expired

; ---- SYS_CTRL bits (VERIFIED from Potator source common/{watara,memorymap,timer}.c) ----
SYSCTRL_NMI_EN    = $01  ; bit0: per-frame NMI enable
SYSCTRL_TIMER_IRQ = $02  ; bit1: timer IRQ enable
SYSCTRL_DMA_IRQ   = $04  ; bit2: DMA-audio IRQ enable
SYSCTRL_PRESCALE  = $10  ; bit4: timer prescaler (period x0x4000 vs x0x100)
SYSCTRL_BANK0     = $00  ; bits7:5 = bank << 5

; ---- Controller bit masks (active-low on $2020, SV layout) ----
PAD_START  = $80
PAD_SELECT = $40
PAD_A      = $20
PAD_B      = $10
PAD_UP     = $08
PAD_DOWN   = $04
PAD_LEFT   = $02
PAD_RIGHT  = $01

; ---- GB-layout button masks (as produced by read_input into pad_held/pad_pressed) ----
GB_A      = $01
GB_B      = $02
GB_SELECT = $04
GB_START  = $08
GB_RIGHT  = $10
GB_LEFT   = $20
GB_UP     = $40
GB_DOWN   = $80
