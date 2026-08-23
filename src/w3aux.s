; W3AUX -- the composite renderer's home (docs/42). Lives at $A620 in PAGE 8:
; make_512k lays that page out as [bank-1 prefix copy][THIS BLOB][$FF...], so
; while it is mapped (a plain $2021=8, the same switch w3_draw uses for bank
; 6), the code here sees: the W3-flavour common prefix (bg_chardata included)
; at its normal addresses, everything FIXED, all RAM. It must NOT touch the
; level region (its page-8 copy is dead bytes) or bank-6 pins.
;
; RULE: reached ONLY via the $2021 dance; never via SYS_CTRL bit5 (every
; SYS_CTRL write restarts the LCD scan -- docs/42).

.include "w2abi.inc"

.segment "AUX"

; aux_ping: the infrastructure proof -- called by the harness/battery to show
; page 8 maps and executes on both the model and the real core.
.proc aux_ping
    lda #$77
    sta $0135
    rts
.endproc
