;
; fast_uart4000.asm -- the fast bit-banged serial routines, taken
; from mBIOS (~/projects/elf/Elfos-mbios/fast_uart4000.asm) so that a
; machine whose console is the fast bit-banged port is driven by exactly
; the code its own BIOS drives it with.
;
; Changed from the original, and only this:
;
;   bread/btype      -> ee_bread/ee_btype, to sit alongside eeprom.asm's
;                       own names.
;   sep sret         -> rtn, which assembles to the same $D5; eeprom.asm
;                       does not define Elf/OS's sret symbol.
;   .align page      -> added before each half. Both are full of short
;                       branches, every one of which has to land in the
;                       assembler's current 256-byte page, and together
;                       they are wider than one page.
;   bdf btype        -> lbdf ee_btype, a consequence of that alignment:
;                       the two halves no longer share a page. This is
;                       the echo path, reached after the stop bit has
;                       already been seen and before a start bit that is
;                       timed from nothing, so the extra machine cycle
;                       changes no bit timing -- and transfers clear the
;                       echo flag anyway.
;
; Nothing else is touched. Every instruction below is cycle-counted
; against the baud rate, including the SEX R2 and NOP padding, which is
; there to take time and nothing else.
;

            ; The bread call receives a character through the serial port
            ; waiting indefinitely. This is the core of the normal read call
            ; and is only callable via SEP.

            .align page

ee_bread:   BRMK  ee_bread              ; wait for start bit
            nop
            nop
            nop
            nop
            nop
            sex   r2
si_b0:      BRMK  si_b0_1
            ani   $7f
            lbr   si_b1
si_b0_1:    ori   080h
            lbr   si_b1
si_b1:      shr
            sex   r2
            sex   r2
            BRMK  si_b1_1
            ani   07fh
            lbr   si_b2
si_b1_1:    ori   080h
            lbr   si_b2
si_b2:      shr
            sex   r2
            sex   r2
            BRMK  si_b2_1
            ani   07fh
            lbr   si_b3
si_b2_1:    ori   080h
            lbr   si_b3
si_b3:      shr
            sex   r2
            sex   r2
            BRMK  si_b3_1
            ani   07fh
            lbr   si_b4
si_b3_1:    ori   080h
            lbr   si_b4
si_b4:      shr
            sex   r2
            sex   r2
            BRMK  si_b4_1
            ani   07fh
            lbr   si_b5
si_b4_1:    ori   080h
            lbr   si_b5
si_b5:      shr
            sex   r2
            sex   r2
            BRMK  si_b5_1
            ani   07fh
            lbr   si_b6
si_b5_1:    ori   080h
            lbr   si_b6
si_b6:      shr
            sex   r2
            sex   r2
            BRMK  si_b6_1
            ani   07fh
            lbr   si_b7
si_b6_1:    ori   080h
            lbr   si_b7
si_b7:      shr
            sex   r2
            sex   r2
            BRMK  si_b7_1
            ani   07fh
            lbr   si_stop
si_b7_1:    ori   080h
            lbr   si_stop
si_stop:    nop
            nop
si_wait:    BRSP  si_wait

            plo   re
            ghi   re                    ; if echo flag clear, just return it
            shr
            lbdf  ee_btype

            glo   re
            rtn


            ; For FAST_UART on a 4MHz system, bit-bang serial output is
            ; fixed at 38400 baud. No delay timer value is required.
            ; This is inlined into nbread but can also be called
            ; separately using SEP.

            .align page

ee_btype:   glo   re
            SESP                        ; start bit
            sex   r2
            sex   r2
so_b0:      shrc
            sex   r2
            sex   r2
            bdf   so_b0_1
            SESP
            lbr   so_b1
so_b0_1:    SEMK
            lbr   so_b1
so_b1:      shrc
            sex   r2
            sex   r2
            bdf   so_b1_1
            SESP
            lbr   so_b2
so_b1_1:    SEMK
            lbr   so_b2
so_b2:      shrc
            sex   r2
            sex   r2
            bdf   so_b2_1
            SESP
            lbr   so_b3
so_b2_1:    SEMK
            lbr   so_b3
so_b3:      shrc
            sex   r2
            sex   r2
            bdf   so_b3_1
            SESP
            lbr   so_b4
so_b3_1:    SEMK
            lbr   so_b4
so_b4:      shrc
            sex   r2
            sex   r2
            bdf   so_b4_1
            SESP
            lbr   so_b5
so_b4_1:    SEMK
            lbr   so_b5
so_b5:      shrc
            sex   r2
            sex   r2
            bdf   so_b5_1
            SESP
            lbr   so_b6
so_b5_1:    SEMK
            lbr   so_b6
so_b6:      shrc
            sex   r2
            sex   r2
            bdf   so_b6_1
            SESP
            lbr   so_b7
so_b6_1:    SEMK
            lbr   so_b7
so_b7:      shrc
            sex   r2
            sex   r2
            bdf   so_b7_1
            SESP
            lbr   so_stop
so_b7_1:    SEMK
            lbr   so_stop
so_stop:    nop
            nop
            sex   r2
            SEMK                        ; stop bit
            shrc                        ; restore D

            rtn
