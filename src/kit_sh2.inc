.proc l3_hurt                    ; the $3186 touch column ($FF) hurts, but the GB
    jsr l3_above                 ; stomp-side path (+0 = 0) exits with NO effect:
    bcc @no                      ; "stomping" passes harmlessly through the head
    jmp hurt_mario               ; zone -- Mario lands on whatever is beneath
@no:
    rts
.endproc
