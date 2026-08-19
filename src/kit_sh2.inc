.proc l3_hurt                    ; the $3186 touch column ($FF) hurts, but the GB
.ifdef MAR23                     ; stomp-side path (+0 = 0) exits with NO effect:
    jsr sub_off                  ; VEHICLE LEVEL (law B1): nothing is stompable
    jmp hurt_mario               ; here, so contact always hurts whatever the
.else                            ; vertical relation -- and the hull dies with
    jsr l3_above                 ; the hit, or Mario's corpse plays beside a
    bcc @no                      ; submarine that is still on screen.
    jmp hurt_mario               ; "stomping" passes harmlessly through the head
@no:                             ; zone -- Mario lands on whatever is beneath
    rts
.endif
.endproc
