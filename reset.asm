;
; reset.asm - ELF-DOS utility: restart the machine as a processor reset
;             would
;
; Usage: RESET [addr]
;
; Puts the machine in the state a hardware reset leaves it in -- RAM
; overlay off, Q off, P = 0, X = 0, interrupts enabled, R0 = the start
; address -- and so starts executing at <addr>. The default is $8000,
; the ROM's cold start. A real reset starts at $0000; this starts at the
; ROM instead, since $0000 is RAM once the system is running.
;
; <addr> is always hex, 1-4 digits, with an optional $ or 0x prefix or h
; suffix. (The shell expands $NAME as a variable, so a $ prefix has to be
; quoted: '$8000'.)
;
; THE RAM OVERLAY
;
; The ROM's own startup switches a 32K RAM chip in over $8000-$FFFF by
; writing $81 to RTC_PORT (Elf-maxmon's raminit), so while ELF-DOS runs,
; $8000 is RAM. A hardware reset clears that latch; this program does the
; same by writing $80, exactly as eeprom.asm does, and the ROM's startup
; switches the overlay back on itself. This is why RESET lives here and
; not in ELF-DOS: the port depends on the machine (TARGET, from
; include/sysconfig.inc), and writing $80 to the wrong one would go to
; some other device.
;
; Everything after the overlay goes away runs from this image in low RAM
; and calls nothing: the kernel, the BIOS and the stack ELF-DOS handed us
; may all be above $8000. Interrupts are switched off first, so none can
; vector through an R1 into memory that is about to change.
;
; Every other register is undefined after a real reset, so nothing else
; is set. What this cannot do: devices on the bus never see the reset
; signal. The ROM's startup reinitialises what it can; a hung device
; still needs the button.
;

#include    elfdos-sdk/include/opcodes.def
#include    elfdos-sdk/include/kernel_api.inc
#include    include/sysconfig.inc

DEFAULT_ADDR: equ  08000h

            org   PROG_BASE

            db    'E','D','F'           ; ELF-DOS program magic
            db    1                     ; program major version
            db    0                     ; program minor version
            db    0                     ; reserved

;------------------------------------------------------------------
; Entry - PROG_BASE + $06. RA = argv table, RC = argc
;------------------------------------------------------------------
start:      glo   rc
            smi   2
            lbnf  go                    ; no argument: the default
            glo   rc
            smi   3
            lbdf  usage                 ; more than one
            inc   ra                    ; RA -> argv[1]
            inc   ra
            lda   ra
            phi   rf
            ldn   ra
            plo   rf

            ldn   rf                    ; optional $ or 0x prefix
            xri   '$'
            lbz   skip1
            ldn   rf
            xri   '0'
            lbnz  parse
            inc   rf
            ldn   rf
            ani   0dfh
            xri   'X'
            lbz   skip1
            dec   rf                    ; just a leading 0
            lbr   parse
skip1:      inc   rf

            ; 1-4 hex digits into R9, optional h suffix (no calls here)
parse:      ldi   0
            phi   r9
            plo   r9
            phi   r8
            plo   r8                    ; R8 = digit count
hexloop:    lda   rf
            lbz   hexend
            plo   rb                    ; RB.0 = the character
            ani   0dfh                  ; h suffix, if it is the last
            xri   'H'
            lbnz  hexdigit
            ldn   rf
            lbz   hexend
            lbr   usage
hexdigit:   glo   rb
            smi   '0'
            lbnf  usage
            plo   r7
            smi   10
            lbnf  hexnib                ; 0-9
            glo   rb
            ani   0dfh                  ; fold a-f to A-F
            smi   'A'
            lbnf  usage
            plo   r7
            smi   6
            lbdf  usage
            glo   r7
            adi   10
            plo   r7
hexnib:     glo   r8
            smi   4
            lbdf  usage                 ; more than 4 digits
            inc   r8
            shl16 r9
            shl16 r9
            shl16 r9
            shl16 r9
            glo   r7
            str   r2
            glo   r9
            or
            plo   r9
            lbr   hexloop
hexend:     glo   r8
            lbz   usage                 ; no digits
            mov   rf,rs_addr
            ghi   r9
            str   rf
            inc   rf
            glo   r9
            str   rf

            ; ---- say where, as four hex digits ----
go:         mov   rf,rs_addr
            lda   rf
            phi   r9
            ldn   rf
            plo   r9
            mov   rf,rs_hex
            ldi   4
            plo   r8
hexout:     ghi   r9                    ; top nibble
            shr
            shr
            shr
            shr
            adi   '0'
            plo   r7
            smi   '9'+1
            lbnf  hexout2
            glo   r7
            adi   7                     ; 'A'-'F'
            plo   r7
hexout2:    glo   r7
            str   rf
            inc   rf
            shl16 r9
            shl16 r9
            shl16 r9
            shl16 r9
            dec   r8
            glo   r8
            lbnz  hexout

            call  K_INMSG
            db    "Resetting to $",0
            mov   rf,rs_hex
            call  K_MSG
            call  K_INMSG
            db    "...",13,10,0

            ; let the last characters leave the UART before the ROM
            ; reinitialises it (about 0.1 s at 4 MHz)
            mov   rc,01000h
settle:     dec   rc
            glo   rc
            lbnz  settle
            ghi   rc
            lbnz  settle

            ; ---- no calls from here on ----
            ldi   023h                  ; x=2, p=3
            str   r2
            dis                         ; interrupts off
            dec   r2                    ; dis left r2 one past m(r(x))

            mov   rf,rs_addr
            lda   rf
            phi   r0
            ldn   rf
            plo   r0                    ; R0 = start address
            req                         ; Q off

            sex   r3
          #if RTC_GROUP
            out   EXP_PORT
            db    RTC_GROUP
          #endif
            out   RTC_PORT              ; RAM overlay off, as at reset
            db    080h
          #if RTC_GROUP
            out   EXP_PORT
            db    NO_GROUP
          #endif

            mov   r2,rs_xp
            sex   r2
            ret                         ; X = 0, P = 0, IE = 1: run at R0

usage:      call  K_INMSG
            db    "Usage: RESET [addr]  (hex, default 8000)",13,10,0
            ldi   1
            rtn

rs_addr:    dw    DEFAULT_ADDR
rs_xp:      db    000h                  ; X,P loaded by RET
rs_hex:     db    "0000",0

            end   start
