;
; eeprom.asm - ELF-DOS utility for the 1802/Mini's AT28C256 EEPROM
;
; Usage: EEPROM SAVE   [-a <addr>] [-l <len>] [-u|-b]
;        EEPROM UPDATE [-a <addr>] [-l <len>] [-u|-b]
;
; SAVE sends the EEPROM's contents up the serial line to a host running
; "mem-xfr -r"; UPDATE takes a memory image back down from a host running
; "mem-xfr -s" and programs it into the EEPROM. Both speak the wire
; protocol Elf-maxmon's savebin/loadbin already speak (see Elf-xfer's
; mem-xfr.c for the authoritative description of it), so the host side
; needs no new tool.
;
; -a defaults to $8000 and -l to 32768, i.e. the whole 32K chip. Numbers
; take a $ or 0x prefix, or an h suffix, for hex; bare digits are decimal.
; -u/-b force the transfer onto the 1854 UART or the bit-banged port,
; overriding what ee_iodet works out for itself.
;
; Build this with the TARGET that matches the configuration the machine's
; BIOS was built with, which is not always the name of the board: it is
; the BIOS's choice that fixes RTC_PORT, the serial polarity, and whether
; the bit-banged routines are the fixed-rate ones. An 1802/Mini running
; mBIOS built as "max" wants TARGET=1802MAX.
;
; SELF-CONTAINED BY NECESSITY
;
; The 32K RAM chip that normally overlays $8000-$FFFF has to be switched
; out before the EEPROM underneath it can be reached at all, and that
; switch takes away whatever was living up there: ELF-DOS's own non-
; volatile kernel image, and - on the UPDATE path - the ROM BIOS itself,
; which this program is in the middle of overwriting. So from the moment
; the overlay goes away until it comes back, this program calls nothing
; but itself:
;
;   - its own SCRT (ee_scall/ee_sret), because the BIOS's own lives at
;     $FFE0/$FFF1, squarely inside the region being written;
;   - its own stack (ee_stack), because the one ELF-DOS handed us is not
;     guaranteed to be below $8000;
;   - its own console routines (ee_utype/ee_uread for a CDP1854, or
;     ee_btype/ee_bread for a bit-banged port) -- copies of the BIOS's
;     own, not reimplementations of them: the variable-rate bit-bang
;     pair from Elf-eeprom's eeprog.asm, which had to solve exactly this
;     problem first, and the fixed-rate pair a FAST_UART machine needs
;     straight out of mBIOS (see include/fast_uart*.asm). Both are
;     cycle-counted against a baud rate, so matching the BIOS
;     instruction for instruction is the only way to be sure the wire
;     still works once the BIOS itself is gone;
;   - interrupts off, so a stray one cannot vector through an R1 pointing
;     into memory that is no longer there.
;
; Everything the program needs is inside its own image at PROG_BASE, and
; the only memory it touches above $8000 is the EEPROM itself. Kernel
; calls (banner, results, errors) happen strictly before the overlay goes
; away and strictly after it comes back.
;
; THE SOFTWARE DATA PROTECTION SEQUENCE
;
; The AT28C256's write lock is not a mode you enter and leave; it is a
; three-byte unlock that prefixes each page write, exactly as eeprog.asm
; does it: $AA to chip address $5555, $55 to $2AAA, $A0 to $5555, then up
; to 64 bytes of data, then a data-polling wait for the cycle to finish.
; With the chip selected by A15 those two addresses are $D555 and $AAAA
; as the CPU sees them. Writes outside that prefix are ignored by the
; chip, which is the point: protection is never actually off, not even
; between blocks, so a crash mid-transfer cannot scribble on the part.
; The alternative - the six-byte sequence that disables protection
; wholesale for the duration and re-enables it at the end - leaves the
; chip defenseless for the whole transfer AND leaves it that way for good
; if the program never reaches its own re-enable, since the setting is
; itself non-volatile. Per-page unlock gives the same result with neither
; exposure.
;

#include    elfdos-sdk/include/opcodes.def
#include    include/eeprom.def
#include    elfdos-sdk/include/kernel_api.inc
#include    include/sysconfig.inc

ROMBASE:    equ   08000h                ; where the EEPROM appears
EE_UNLOCKA: equ   ROMBASE+05555h        ; $D555 - SDP sequence address 1
EE_UNLOCKB: equ   ROMBASE+02aaah        ; $AAAA - SDP sequence address 2
EE_PAGE:    equ   0003fh                ; AT28C256 page size, less one
EE_BLOCK:   equ   512                   ; savebin's own block size

CMD_SAVE:   equ   0
CMD_UPD:    equ   1
CMD_NONE:   equ   0ffh

            ; Two things in the BIOS that ee_iodet READS (never calls) to
            ; find out what the console is. MBIOS_TYPE is mBIOS's own
            ; rewritable console-output vector, a three-byte LBR in low RAM
            ; that names the live routine; F_BTYPE/F_UTYPE are the extended
            ; BIOS table's entries for the two candidates, each likewise an
            ; LBR. Comparing what the first branches to against what the
            ; other two branch to says WHICH DEVICE the console is -- which
            ; is the answer we need, since the routine's own address is
            ; useless to us once the overlay is gone. Declared here rather
            ; than by including bios.inc, whose "ret" equate would collide
            ; with the 1802 RET mnemonic ee_run needs.

MBIOS_TYPE: equ   0003ch                ; mBIOS console output vector
LBR_OP:     equ   0c0h                  ; what a vector holds when it is set
EBIOS:      equ   0f800h                ; extended BIOS vector table
F_BTYPE:    equ   EBIOS+003h            ; lbr <bit-banged output routine>
F_UTYPE:    equ   EBIOS+009h            ; lbr <1854 output routine>

DEV_AUTO:   equ   0ffh                  ; neither -u nor -b was given
DEV_BBANG:  equ   0
DEV_UART:   equ   1

ERR_USAGE:  equ   1                     ; nothing was attempted
ERR_PROTO:  equ   2                     ; handshake or echo mismatch
ERR_COUNT:  equ   3                     ; block length the protocol forbids
ERR_RANGE:  equ   4                     ; block outside -a/-l
ERR_WRITE:  equ   5                     ; EEPROM never finished a write
ERR_VERIFY: equ   6                     ; EEPROM read back wrong

            org   PROG_BASE

            db    'E','D','F'           ; ELF-DOS program magic
            db    1                     ; program major version
            db    0                     ; program minor version
            db    0                     ; reserved

;------------------------------------------------------------------
; Entry - PROG_BASE + $06
;------------------------------------------------------------------
start:      mov   r8,ee_argc
            glo   rc
            str   r8                    ; argc (never more than
                                        ; ARGV_MAX_ARGS, one byte is
                                        ; plenty)
            mov   r8,ee_argv
            ghi   ra
            str   r8
            inc   r8
            glo   ra
            str   r8                    ; argv table address -- both
                                        ; stashed before the first call
                                        ; can clobber ra/rc

;------------------------------------------------------------------
; Command line
;------------------------------------------------------------------
            mov   r8,ee_argc
            ldn   r8
            plo   rb                    ; rb.0 = argc
            ldi   1
            plo   rc                    ; rc.0 = argument index

ee_arglp:   glo   rc
            str   r2
            glo   rb
            sm                          ; argc - i
            lbnf  ee_argend
            lbz   ee_argend

            call  ee_argv_i             ; rf = argv[i]

            ldn   rf
            xri   '-'
            lbnz  ee_argcmd

            inc   rf                    ; step over the '-'
            lda   rf                    ; and take the option letter
            ani   0dfh                  ; letters fold to upper case
            str   r2
            xri   'A'
            lbz   ee_opt_a
            ldn   r2
            xri   'L'
            lbz   ee_opt_l
            ldn   r2
            xri   'U'
            lbz   ee_opt_u
            ldn   r2
            xri   'B'
            lbz   ee_opt_b
            lbr   ee_badopt

ee_opt_u:   ldi   DEV_UART             ; -u: force the CDP1854
            lbr   ee_optdev
ee_opt_b:   ldi   DEV_BBANG            ; -b: force the bit-banged port
ee_optdev:  str   r2
            mov   r8,ee_uart
            ldn   r2
            str   r8
            lbr   ee_argnext

ee_opt_a:   call  ee_optval
            lbdf  ee_badopt
            call  ee_number
            lbdf  ee_badnum
            mov   r8,ee_addr
            lbr   ee_optput

ee_opt_l:   call  ee_optval
            lbdf  ee_badopt
            call  ee_number
            lbdf  ee_badnum
            mov   r8,ee_len

ee_optput:  ghi   rd
            str   r8
            inc   r8
            glo   rd
            str   r8
            lbr   ee_argnext

            ; The one bare argument is the command name.

ee_argcmd:  mov   r8,ee_cmd
            ldn   r8
            xri   CMD_NONE
            lbnz  ee_badarg             ; a second bare argument

            mov   r7,rf                 ; ee_cmpci walks rf, so keep the
                                        ; argument to try twice
            mov   rd,ee_s_save
            call  ee_cmpci
            lbnf  ee_cmd_s
            mov   rf,r7
            mov   rd,ee_s_update
            call  ee_cmpci
            lbnf  ee_cmd_u
            lbr   ee_badcmd

ee_cmd_s:   ldi   CMD_SAVE
            lbr   ee_cmdput
ee_cmd_u:   ldi   CMD_UPD
ee_cmdput:  str   r2
            mov   r8,ee_cmd
            ldn   r2
            str   r8

ee_argnext: inc   rc
            lbr   ee_arglp

ee_argend:  mov   r8,ee_cmd
            ldn   r8
            xri   CMD_NONE
            lbz   ee_usage              ; no command given at all

;------------------------------------------------------------------
; Range check. The EEPROM is the top half of the address space, so a
; start below $8000 is always wrong, and a length is only legal if it
; fits between the start and the top of memory -- which is why the
; limit is computed as 0-addr rather than addr+len, a sum that is
; exactly $10000 for the default whole-chip case and would wrap to
; zero in sixteen bits.
;------------------------------------------------------------------
            mov   r8,ee_addr
            lda   r8
            phi   r9
            ldn   r8
            plo   r9                    ; r9 = start address
            ghi   r9
            ani   080h
            lbz   ee_badaddr            ; below $8000

            mov   r8,ee_len
            lda   r8
            phi   rc
            ldn   r8
            plo   rc                    ; rc = length
            glo   rc
            lbnz  ee_lennz
            ghi   rc
            lbz   ee_badlen             ; a zero length transfers nothing
ee_lennz:
            mov   rd,0
            sub16 rd,r9                 ; rd = bytes from start to $10000
            mov   r8,rd
            sub16 r8,rc
            lbnf  ee_badlen             ; length runs off the top

;------------------------------------------------------------------
; Banner. Everything printed here goes out over the same serial line
; the transfer itself uses, so it all has to be on the wire before the
; host's mem-xfr starts listening.
;------------------------------------------------------------------
            call  ee_iodet              ; also points ee_type/ee_read at
                                        ; the console we actually have

            call  K_INMSG
            db    "EEPROM ",0
            mov   r8,ee_cmd
            ldn   r8
            lbnz  ee_bnr_u
            call  K_INMSG
            db    "save",0
            lbr   ee_bnr_r
ee_bnr_u:   call  K_INMSG
            db    "update",0
ee_bnr_r:   call  K_INMSG
            db    ": $",0

            mov   r8,ee_addr            ; start
            call  ee_pwset
            call  ee_pword
            call  K_INMSG
            db    "-$",0

            mov   r8,ee_addr            ; last address = start+len-1
            lda   r8
            phi   r9
            ldn   r8
            plo   r9
            mov   r8,ee_len
            lda   r8
            phi   rc
            ldn   r8
            plo   rc
            add16 r9,rc
            dec   r9
            mov   r8,ee_pw
            ghi   r9
            str   r8
            inc   r8
            glo   r9
            str   r8
            call  ee_pword

            call  K_INMSG
            db    ", $",0
            mov   r8,ee_len
            call  ee_pwset
            call  ee_pword
            call  K_INMSG
            db    " bytes",13,10,0

            call  K_INMSG
            db    "Console: ",0
            mov   r8,ee_uart
            ldn   r8
            lbz   ee_bnr_bb
            call  K_INMSG
            db    "1854 UART",13,10,0
            lbr   ee_bnr_go
ee_bnr_bb:  call  K_INMSG
#ifdef FAST_UART
            db    "bit-banged serial (fast)",13,10,0
#else
            db    "bit-banged serial",13,10,0
#endif

ee_bnr_go:  mov   r8,ee_cmd
            ldn   r8
            lbnz  ee_bnr_gu
            call  K_INMSG
            db    "Start the host receiver now (mem-xfr -r).",13,10,0
            lbr   ee_go
ee_bnr_gu:  call  K_INMSG
            db    "Start the host sender now (mem-xfr -s).",13,10,0

ee_go:      call  ee_run

;------------------------------------------------------------------
; Result. Back under the kernel, with the overlay restored.
;------------------------------------------------------------------
            mov   r8,ee_err
            ldn   r8
            lbnz  ee_failed

            mov   r8,ee_cmd
            ldn   r8
            lbnz  ee_ok_u
            call  K_INMSG
            db    13,10,"EEPROM saved.",13,10,0
            ldi   0
            rtn
ee_ok_u:    call  K_INMSG
            db    13,10,"EEPROM updated.",13,10,0
            ldi   0
            rtn

ee_failed:  call  K_INMSG
            db    13,10,0
            mov   r8,ee_err
            ldn   r8
            str   r2

            xri   ERR_PROTO
            lbnz  ee_f2
            call  K_INMSG
            db    "Transfer protocol error -- the host did not answer as",13,10
            db    "expected.",13,10,0
            lbr   ee_ftail
ee_f2:      ldn   r2
            xri   ERR_COUNT
            lbnz  ee_f3
            call  K_INMSG
            db    "The host sent a block length the protocol does not allow.",13,10,0
            lbr   ee_ftail
ee_f3:      ldn   r2
            xri   ERR_RANGE
            lbnz  ee_f4
            call  K_INMSG
            db    "The host sent a block outside the requested address range.",13,10
            db    "Widen -a/-l, or narrow what the host is sending.",13,10,0
            lbr   ee_ftail
ee_f4:      ldn   r2
            xri   ERR_WRITE
            lbnz  ee_f5
            call  K_INMSG
            db    "EEPROM write never completed at $",0
            lbr   ee_faddr
ee_f5:      call  K_INMSG
            db    "EEPROM read back wrong at $",0
ee_faddr:   mov   r8,ee_errad
            call  ee_pwset
            call  ee_pword
            call  K_INMSG
            db    13,10,0

            ; What the failure means for the part depends on which command
            ; it was. SAVE only ever reads, so nothing can have changed.
            ; UPDATE can fail at any point, including after blocks have
            ; already gone in -- saying otherwise would be a claim about
            ; the user's chip that this program cannot make.

ee_ftail:   mov   r8,ee_cmd
            ldn   r8
            lbnz  ee_fupd
            call  K_INMSG
            db    "The EEPROM was not changed.",13,10,0
            lbr   ee_fexit
ee_fupd:    call  K_INMSG
            db    "The EEPROM may be partly written -- run UPDATE again.",13,10,0

ee_fexit:   mov   r8,ee_err
            ldn   r8
            rtn                         ; exit code = the error code

;------------------------------------------------------------------
; Command line diagnostics
;------------------------------------------------------------------
ee_badopt:  call  K_INMSG
            db    "Unrecognized option.",13,10,0
            lbr   ee_usage
ee_badnum:  call  K_INMSG
            db    "Bad number.",13,10,0
            lbr   ee_usage
ee_badarg:  call  K_INMSG
            db    "Too many arguments.",13,10,0
            lbr   ee_usage
ee_badcmd:  call  K_INMSG
            db    "Unrecognized command.",13,10,0
            lbr   ee_usage
ee_badaddr: call  K_INMSG
            db    "The EEPROM starts at $8000; -a cannot be below that.",13,10,0
            lbr   ee_usage
ee_badlen:  call  K_INMSG
            db    "-l must be at least 1 and must not run past $FFFF.",13,10,0

ee_usage:   call  K_INMSG
            db    "Usage: EEPROM SAVE   [-a <addr>] [-l <len>]",13,10
            db    "       EEPROM UPDATE [-a <addr>] [-l <len>]",13,10,13,10
            db    "  SAVE    send the EEPROM to a host running mem-xfr -r",13,10
            db    "  UPDATE  program the EEPROM from a host running mem-xfr -s",13,10
            db    "  -a      start address (default $8000)",13,10
            db    "  -l      byte count (default 32768)",13,10
            db    "  -u      run the transfer on the 1854 UART",13,10
            db    "  -b      run the transfer on the bit-banged port",13,10,13,10
            db    "Numbers take a $ or 0x prefix or an h suffix for hex.",13,10,0
            ldi   ERR_USAGE
            rtn

;------------------------------------------------------------------
; ee_argv_i - rf = argv[rc.0]
;------------------------------------------------------------------
ee_argv_i:  mov   r8,ee_argv
            lda   r8
            phi   r9
            ldn   r8
            plo   r9                    ; r9 = the argv table
            glo   rc
            shl                         ; each entry is a 16-bit pointer
            str   r2
            glo   r9
            add
            plo   r9
            ghi   r9
            adci  0
            phi   r9
            lda   r9
            phi   rf
            ldn   r9
            plo   rf
            rtn

;------------------------------------------------------------------
; ee_optval - rf points just past an option letter. Leave rf on the
; option's value: the rest of this argument if there is any, otherwise
; the next argument entirely. DF = 1 if there is no value to be had.
;------------------------------------------------------------------
ee_optval:  ldn   rf
            lbnz  ee_ovok               ; "-a8000"

            inc   rc                    ; "-a 8000"
            glo   rc
            str   r2
            mov   r8,ee_argc
            ldn   r8
            sm                          ; argc - i
            lbnf  ee_ovbad
            lbz   ee_ovbad
            call  ee_argv_i
ee_ovok:    clc
            rtn
ee_ovbad:   stc
            rtn

;------------------------------------------------------------------
; ee_cmpci - compare the string at rf against the upper-case string at
; rd, ignoring case. DF = 0 if they match. rf is left past the point of
; difference either way.
;------------------------------------------------------------------
ee_cmpci:   lda   rf
            plo   r9
            smi   'a'
            lbnf  ee_cci1               ; below 'a', already folded
            glo   r9
            smi   07bh
            lbdf  ee_cci1               ; above 'z', not a letter
            glo   r9
            smi   020h
            plo   r9                    ; fold to upper case
ee_cci1:    lda   rd
            str   r2
            glo   r9
            xor
            lbnz  ee_ccibad
            glo   r9
            lbnz  ee_cmpci              ; matched, and not the terminator
            clc
            rtn
ee_ccibad:  stc
            rtn

;------------------------------------------------------------------
; ee_number - parse the asciiz number at rf into rd. DF = 1 if it is
; not one. Accepts $hhhh, 0xhhhh, hhhhh (h suffix), or plain decimal;
; anything that will not fit in sixteen bits is an error rather than a
; silent wrap, since an address or length that wrapped would aim the
; transfer somewhere the user did not ask for.
;------------------------------------------------------------------
ee_number:  ldn   rf
            lbz   ee_numerr             ; empty

            xri   '$'
            lbnz  ee_num_x
            inc   rf
            lbr   ee_hex

ee_num_x:   ldn   rf
            xri   '0'
            lbnz  ee_num_h
            inc   rf
            ldn   rf
            ani   0dfh
            xri   'X'
            lbz   ee_num_x2
            dec   rf                    ; just a decimal number that
            lbr   ee_num_h              ; happens to start with '0'
ee_num_x2:  inc   rf
            lbr   ee_hex

            ; No prefix: an 'h' or 'H' as the very last character makes
            ; it hex, and ee_hex stops on that character itself.

ee_num_h:   mov   r9,rf
ee_num_hl:  lda   r9
            lbnz  ee_num_hl
            dec   r9                    ; the terminator
            dec   r9                    ; the last real character
            ldn   r9
            ani   0dfh
            xri   'H'
            lbz   ee_hex

ee_dec:     mov   rd,0
ee_declp:   lda   rf
            lbz   ee_numok
            smi   '0'
            lbnf  ee_numerr
            plo   r8
            smi   10
            lbdf  ee_numerr
            mov   r9,rd                 ; n*10 = ((n*2)*2 + n)*2
            shl16 rd
            lbdf  ee_numerr
            shl16 rd
            lbdf  ee_numerr
            add16 rd,r9
            lbdf  ee_numerr
            shl16 rd
            lbdf  ee_numerr
            glo   r8
            str   r2
            glo   rd
            add
            plo   rd
            ghi   rd
            adci  0
            phi   rd
            lbdf  ee_numerr
            lbr   ee_declp

ee_hex:     mov   rd,0
            ldn   rf
            lbz   ee_numerr             ; a bare prefix is not a number
ee_hexlp:   lda   rf
            lbz   ee_numok
            str   r2
            smi   'a'
            lbnf  ee_hx1
            ldn   r2
            smi   07bh
            lbdf  ee_hx1
            ldn   r2
            smi   020h
            str   r2                    ; fold to upper case
ee_hx1:     ldn   r2
            xri   'H'
            lbz   ee_hexend
            ldn   r2
            smi   '0'
            lbnf  ee_numerr
            str   r2
            smi   10
            lbnf  ee_hxdig              ; '0'-'9'
            ldn   r2
            smi   'A'-'0'
            lbnf  ee_numerr             ; between '9' and 'A'
            adi   10
            str   r2
            smi   16
            lbdf  ee_numerr             ; past 'F'
ee_hxdig:   ghi   rd
            ani   0f0h
            lbnz  ee_numerr             ; a fifth digit will not fit
            shl16 rd
            shl16 rd
            shl16 rd
            shl16 rd
            glo   rd
            or
            plo   rd
            lbr   ee_hexlp

ee_hexend:  ldn   rf                    ; the h suffix must be last
            lbnz  ee_numerr
ee_numok:   clc
            rtn
ee_numerr:  stc
            rtn

;------------------------------------------------------------------
; ee_pwset - copy the word at r8 into ee_pw, ready for ee_pword.
; ee_pword - print ee_pw as four hex digits.
; ee_phex2 - print d as two hex digits.
;
; These go through a fixed memory word rather than a register because
; K_TYPE guarantees nothing about registers, so nothing a caller is
; holding can survive across the digits.
;------------------------------------------------------------------
ee_pwset:   lda   r8
            phi   r9
            ldn   r8
            plo   r9
            mov   r8,ee_pw
            ghi   r9
            str   r8
            inc   r8
            glo   r9
            str   r8
            rtn

ee_pword:   mov   r9,ee_pw
            ldn   r9
            call  ee_phex2
            mov   r9,ee_pw
            inc   r9
            ldn   r9
            call  ee_phex2
            rtn

ee_phex2:   str   r2
            mov   r9,ee_tmp
            ldn   r2
            str   r9                    ; the call below will overwrite
                                        ; m(r2), so park it somewhere the
                                        ; stack cannot reach
            shr
            shr
            shr
            shr
            call  ee_phexd
            mov   r9,ee_tmp
            ldn   r9
            ani   0fh
            call  ee_phexd
            rtn

ee_phexd:   adi   0f6h                  ; df set once d reaches ten
            lbnf  ee_phd1
            adi   'A'-'0'-10
ee_phd1:    adi   '0'+10
            call  K_TYPE
            rtn

;==================================================================
; The critical section
;==================================================================

;------------------------------------------------------------------
; ee_run - switch the machine over to this program's own SCRT, stack
; and console, take the RAM overlay away, run the command, and put
; everything back. Nothing between the two OUTs to RTC_PORT may touch
; memory above $8000 except the EEPROM itself.
;------------------------------------------------------------------
ee_run:     mov   r8,ee_save_r4
            ghi   r4
            str   r8
            inc   r8
            glo   r4
            str   r8
            inc   r8
            ghi   r5
            str   r8
            inc   r8
            glo   r5
            str   r8
            inc   r8
            ghi   r2
            str   r8
            inc   r8
            glo   r2
            str   r8                    ; r2 as it is now, i.e. with this
                                        ; call's own return already pushed
            inc   r8
            ghi   re
            str   r8                    ; baud rate and echo flag

            ani   0feh                  ; echo would put every byte of the
            phi   re                    ; transfer back on the wire

            inc   r8
            ldi   1                     ; lsie skips exactly the two bytes
            lsie                        ; of the ldi below
            ldi   0
            str   r8                    ; remember whether IE was set

            ldi   023h                  ; x=2, p=3
            str   r2
            dis                         ; and interrupts off
            dec   r2                    ; dis left r2 one past m(r(x))

            mov   r2,ee_stktop          ; our own stack, safely below
                                        ; $8000; the old one still holds
                                        ; this call's return
            mov   r4,ee_scall           ; and our own SCRT, out of the
            mov   r5,ee_sret            ; BIOS's doomed $FFE0/$FFF1

            sex   r3
          #if RTC_GROUP
            out   EXP_PORT
            db    RTC_GROUP
          #endif
            out   RTC_PORT              ; RAM overlay off: the EEPROM is
            db    080h                  ; now visible at $8000-$FFFF
          #if RTC_GROUP
            out   EXP_PORT
            db    NO_GROUP
          #endif
            sex   r2

            mov   r8,ee_cmd
            ldn   r8
            lbnz  ee_run_u
            call  ee_save
            lbr   ee_run_x
ee_run_u:   call  ee_update

ee_run_x:   sex   r3
          #if RTC_GROUP
            out   EXP_PORT
            db    RTC_GROUP
          #endif
            out   RTC_PORT              ; RAM overlay back on, and with it
            db    081h                  ; the kernel and the BIOS
          #if RTC_GROUP
            out   EXP_PORT
            db    NO_GROUP
          #endif
            sex   r2

            mov   r8,ee_save_r4
            lda   r8
            phi   r4
            lda   r8
            plo   r4
            lda   r8
            phi   r5
            lda   r8
            plo   r5
            lda   r8
            phi   r2                    ; nothing between these two may
            lda   r8                    ; touch the stack
            plo   r2
            lda   r8
            phi   re
            ldn   r8
            lbz   ee_run_r              ; IE was already clear, leave it
            ldi   023h
            str   r2
            ret                         ; the 1802 RET, not the macro:
            dec   r2                    ; x=2, p=3, interrupts back on
ee_run_r:   rtn                         ; via the BIOS's SCRT again, off
                                        ; the stack it was pushed on

;------------------------------------------------------------------
; ee_scall / ee_sret - a private copy of the standard SCRT.
;
; Each half is a coroutine: entry lands at ee_scall, the LBR hands
; control to ee_callbr, and ee_callbr's SEP R3 leaves R4 pointing at
; ee_scall again for next time - which is why ee_scall has to follow
; ee_callbr immediately in memory. Long branches, where Elf/OS uses
; short ones, so neither half carries a page constraint.
;------------------------------------------------------------------
ee_callbr:  glo   r3
            plo   r6
            lda   r6                    ; the call's inline target
            phi   r3
            lda   r6
            plo   r3
            glo   re
            sep   r3                    ; leaves r4 at ee_scall below
ee_scall:   plo   re                    ; save d
            sex   r2
            glo   r6
            stxd
            ghi   r6
            stxd
            ghi   r3
            phi   r6
            lbr   ee_callbr

ee_retbr:   irx
            ldxa
            phi   r6
            ldx
            plo   r6
            glo   re
            sep   r3                    ; leaves r5 at ee_sret below
ee_sret:    plo   re
            sex   r2
            ghi   r6
            phi   r3
            glo   r6
            plo   r3
            lbr   ee_retbr

;------------------------------------------------------------------
; ee_save - hand the EEPROM to the host, savebin's protocol.
;------------------------------------------------------------------
ee_save:    mov   r8,ee_addr
            lda   r8
            phi   ra
            ldn   r8
            plo   ra                    ; ra = read pointer
            mov   r8,ee_len
            lda   r8
            phi   rc
            ldn   r8
            plo   rc                    ; rc = bytes still to send

            call  ee_read
            xri   0aah
            lbnz  ee_e_proto
            ldi   055h
            call  ee_type

ee_sbnext:  mov   rb,rc
            sub16 rb,EE_BLOCK
            lbdf  ee_sb512
            mov   rb,rc                 ; a short final block
            lbr   ee_sbhdr
ee_sb512:   mov   rb,EE_BLOCK
ee_sbhdr:   sub16 rc,rb

            ldi   01h                   ; 'here comes a block'
            call  ee_sndchk
            lbdf  ee_e_proto
            ghi   rb
            call  ee_sndchk
            lbdf  ee_e_proto
            glo   rb
            call  ee_sndchk
            lbdf  ee_e_proto
            ghi   ra
            call  ee_sndchk
            lbdf  ee_e_proto
            glo   ra
            call  ee_sndchk
            lbdf  ee_e_proto

            dec   rb                    ; the data itself is unechoed,
ee_sblp:    lda   ra                    ; covered only by the ack below
            call  ee_type
            luntl rb,ee_sblp

            call  ee_read
            xri   0aah
            lbnz  ee_e_proto
            lbrnz rc,ee_sbnext

            ldi   00h                   ; end marker, never echoed
            call  ee_type
            call  ee_read               ; the host's closing 'x', which it
            xri   'x'                   ; sends only once its own file is
            lbnz  ee_e_proto            ; safely written
            ldi   0
            lbr   ee_seterr

;------------------------------------------------------------------
; ee_sndchk - send d, read the echo back, compare. DF = 1 if the far
; end did not say the same thing.
;------------------------------------------------------------------
ee_sndchk:  plo   r7                    ; r7 is free through every caller
            call  ee_type
            call  ee_read
            str   r2
            glo   r7
            xor
            lbnz  ee_scbad
            clc
            rtn
ee_scbad:   stc
            rtn

;------------------------------------------------------------------
; ee_update - take a memory image from the host, loadbin's protocol,
; and program each block into the EEPROM.
;
; Each block is read into ee_buf whole before any of it is written.
; That is not an optimization: a page write has to take its 64 bytes
; at better than 150us apart, and no serial line on this machine
; delivers them that fast, so the bytes have to already be in hand
; before the first one goes to the chip. The host is waiting on the
; block's ack meanwhile, so the write's own milliseconds cost nothing.
;------------------------------------------------------------------
ee_update:  call  ee_read
            xri   055h
            lbnz  ee_e_proto
            ldi   0aah
            call  ee_type

ee_ubnext:  call  ee_read
            lbz   ee_ubover             ; end marker, deliberately unechoed
            call  ee_type
            smi   1
            lbnz  ee_e_proto

            call  ee_read               ; count, high byte
            phi   r7
            call  ee_type
            call  ee_read               ; count, low byte
            plo   r7
            call  ee_type
            call  ee_read               ; address, high byte
            phi   rd
            call  ee_type
            call  ee_read               ; address, low byte
            plo   rd
            call  ee_type

            glo   r7                    ; a count of zero never appears in
            lbnz  ee_ucnt1              ; a header -- $00 there is the end
            ghi   r7                    ; marker -- and a count past the
            lbz   ee_e_count            ; block size means we have lost
ee_ucnt1:   mov   r9,r7                 ; sync with the far end
            sub16 r9,EE_BLOCK+1
            lbdf  ee_e_count

            mov   r8,ee_addr            ; the block has to land inside the
            lda   r8                    ; window -a/-l asked for
            phi   rb
            ldn   r8
            plo   rb
            mov   r9,rd
            sub16 r9,rb
            lbnf  ee_e_range            ; below the start
            add16 r9,r7
            lbdf  ee_e_range            ; past the top of memory
            mov   r8,ee_len
            lda   r8
            phi   rb
            ldn   r8
            plo   rb
            sub16 rb,r9
            lbnf  ee_e_range            ; past the end

            mov   r8,ee_vaddr           ; ee_prog consumes rd and r7, so
            ghi   rd                    ; keep a copy for the verify pass
            str   r8
            inc   r8
            glo   rd
            str   r8
            inc   r8
            ghi   r7
            str   r8
            inc   r8
            glo   r7
            str   r8

            mov   ra,ee_buf
            mov   rc,r7
            dec   rc

            ; The data bytes are not echoed, so nothing paces the host but
            ; its own delay, and a call to ee_read for each one costs more
            ; than a byte time at 57600 baud. When the device is the UART,
            ; read it right here instead; this loop keeps up with bytes
            ; sent back-to-back.

            mov   r8,ee_uart
            ldn   r8
            xri   DEV_UART
            lbnz  ee_urdlp

          #if UART_GROUP
            sex   r3
            out   EXP_PORT
            db    UART_GROUP
            sex   r2
          #endif
ee_urfast:  inp   UART_STATUS           ; wait for data available
            ani   1
            lbz   ee_urfast
            inp   UART_DATA
            str   ra
            inc   ra
            luntl rc,ee_urfast
          #if UART_GROUP
            sex   r3
            out   EXP_PORT
            db    NO_GROUP
            sex   r2
          #endif
            lbr   ee_urdone

ee_urdlp:   call  ee_read
            str   ra
            inc   ra
            luntl rc,ee_urdlp

ee_urdone:  mov   ra,ee_buf
            call  ee_prog
            lbdf  ee_e_write
            call  ee_vrfy
            lbdf  ee_e_verify

            ldi   0aah                  ; block done, ask for the next
            call  ee_type
            lbr   ee_ubnext

ee_ubover:  call  ee_read
            xri   'x'
            lbnz  ee_e_proto
            ldi   0
            lbr   ee_seterr

;------------------------------------------------------------------
; Error exits. Reached only from ee_save/ee_update themselves, so the
; RTN below lands back in ee_run, which still has the overlay to put
; back before any of this can be reported.
;------------------------------------------------------------------
ee_e_proto: ldi   ERR_PROTO
            lbr   ee_seterr
ee_e_count: ldi   ERR_COUNT
            lbr   ee_seterr
ee_e_range: ldi   ERR_RANGE
            lbr   ee_seterr
ee_e_write: ldi   ERR_WRITE
            lbr   ee_seterr
ee_e_verify:
            ldi   ERR_VERIFY
ee_seterr:  str   r2
            mov   r8,ee_err
            ldn   r2
            str   r8
            rtn

;------------------------------------------------------------------
; ee_prog - write r7 bytes from ra to the EEPROM at rd, splitting the
; run at 64-byte page boundaries because the chip will not take a page
; write that crosses one. DF = 1 if the part never finished a write.
;------------------------------------------------------------------
ee_prog:    mov   rc,rd                 ; last address in rd's own page
            glo   rc
            ori   EE_PAGE
            plo   rc
            sub16 rc,rd
            inc   rc                    ; rc = room left in this page
            mov   r9,rc
            sub16 rc,r7
            lbdf  ee_pgall              ; it all fits
            mov   rc,r9                 ; otherwise fill the page out
            lbr   ee_pgwr
ee_pgall:   mov   rc,r7
ee_pgwr:    sub16 r7,rc
            call  ee_wrblk
            lbdf  ee_prog_x
            lbrnz r7,ee_prog
            clc
ee_prog_x:  rtn

;------------------------------------------------------------------
; ee_wrblk - write rc bytes from ra to rd, all inside one page: the
; three-byte SDP unlock, the data, then data polling until the part
; reads back the same value twice running. DF = 1 on a timeout, which
; on a healthy chip cannot happen - the whole cycle is under 10ms and
; the count below is worth more than a second.
;------------------------------------------------------------------
ee_wrblk:   mov   r8,EE_UNLOCKB
            mov   r9,EE_UNLOCKA

            ldi   0aah
            str   r9
            ldi   055h
            str   r8
            ldi   0a0h
            str   r9

            dec   rc
ee_wrlp:    lda   ra
            str   rd
            inc   rd
            luntl rc,ee_wrlp

            dec   rd                    ; the last byte written is the one
            mov   r9,0                  ; to poll
ee_wrwait:  ldn   rd
            str   r2
            ldn   rd
            xor
            lbz   ee_wrok
            dec   r9
            lbrnz r9,ee_wrwait
            mov   r8,ee_errad           ; record where it gave up
            ghi   rd
            str   r8
            inc   r8
            glo   rd
            str   r8
            stc
            rtn
ee_wrok:    inc   rd
            clc
            rtn

;------------------------------------------------------------------
; ee_vrfy - read the block just written back off the part and compare
; it against ee_buf. DF = 1 on a mismatch, with ee_errad set to the
; first address that disagreed.
;------------------------------------------------------------------
ee_vrfy:    mov   r8,ee_vaddr
            lda   r8
            phi   rd
            lda   r8
            plo   rd
            lda   r8
            phi   rc
            ldn   r8
            plo   rc
            mov   ra,ee_buf
            dec   rc
ee_vlp:     lda   ra
            str   r2
            ldn   rd
            xor
            lbnz  ee_vbad
            inc   rd
            luntl rc,ee_vlp
            clc
            rtn
ee_vbad:    mov   r8,ee_errad
            ghi   rd
            str   r8
            inc   r8
            glo   rd
            str   r8
            stc
            rtn

;==================================================================
; Console
;==================================================================

;------------------------------------------------------------------
; ee_iodet - decide which console this machine has and point the two
; vectors below at our own copy of it.
;
; mBIOS publishes the live console routine as a three-byte LBR at $003C,
; and the extended BIOS table names both candidates the same way, so the
; device can be identified by resolving one against the others. That is
; the reliable answer on this hardware, and the reason it is worth the
; instructions: mBIOS sets RE.1 only on the bit-bang path (its own
; f_bread/f_btype comment says as much -- "there is probably not the
; correct baud rate in RE.1" when the UART is the console), so RE.1 can
; read as bit-bang on a machine whose console is the UART.
;
; RE.1 shifted right one -- dropping the local-echo flag in bit 0, which
; says nothing about the device -- stays as the fallback for a classic
; BIOS, which publishes no such vector and for which that test is
; exactly what its own type:/read: entry points do. ELF-DOS's boot code
; makes the same two checks in the same order.
;
; -u/-b override both, following MR's own precedent: they exist so a
; transfer can be driven over a port that is NOT the console, which is
; the one arrangement no detection can infer.
;
; Nothing here is ever CALLED once the overlay is gone -- this runs
; while the BIOS is still there, and only reads.
;------------------------------------------------------------------
ee_iodet:   mov   r8,ee_uart
            ldn   r8
            xri   DEV_AUTO
            lbnz  ee_iosel              ; -u or -b already decided it

            mov   r9,MBIOS_TYPE
            ldn   r9
            xri   LBR_OP
            lbnz  ee_iore               ; no vector there: classic BIOS

            inc   r9                    ; rb = the console's own routine
            lda   r9
            phi   rb
            ldn   r9
            plo   rb

            mov   r9,F_UTYPE+1          ; is it the one f_utype names?
            call  ee_iocmp
            lbdf  ee_iodb
            ldi   DEV_UART
            lbr   ee_iosave

ee_iodb:    mov   r9,F_BTYPE+1          ; or the one f_btype names?
            call  ee_iocmp
            lbdf  ee_iore
            ldi   DEV_BBANG
            lbr   ee_iosave

ee_iore:    ghi   re
            shr                         ; bit 0 is echo, not device
            lbnz  ee_iobb
            ldi   DEV_UART
            lbr   ee_iosave
ee_iobb:    ldi   DEV_BBANG
ee_iosave:  str   r2
            mov   r8,ee_uart
            ldn   r2
            str   r8

ee_iosel:   mov   r8,ee_uart
            ldn   r8
            lbz   ee_iovbb

            mov   r9,ee_type+1
            ldi   ee_utype.1
            str   r9
            inc   r9
            ldi   ee_utype.0
            str   r9
            mov   r9,ee_read+1
            ldi   ee_uread.1
            str   r9
            inc   r9
            ldi   ee_uread.0
            str   r9
            rtn

ee_iovbb:   mov   r9,ee_type+1
            ldi   ee_btype.1
            str   r9
            inc   r9
            ldi   ee_btype.0
            str   r9
            mov   r9,ee_read+1
            ldi   ee_bread.1
            str   r9
            inc   r9
            ldi   ee_bread.0
            str   r9
            rtn

;------------------------------------------------------------------
; ee_iocmp - compare rb against the 16-bit word at r9. DF = 0 if equal.
;------------------------------------------------------------------
ee_iocmp:   lda   r9
            str   r2
            ghi   rb
            xor
            lbnz  ee_iocne
            ldn   r9
            str   r2
            glo   rb
            xor
            lbnz  ee_iocne
            clc
            rtn
ee_iocne:   stc
            rtn

;------------------------------------------------------------------
; ee_type / ee_read - the console, as one long branch each, patched by
; ee_iodet. A branch rather than a register test because every caller
; in the transfer loops is already holding something in every register
; worth using, and the character itself is in RE.0 by the time a call
; gets here - which is exactly where both implementations want it.
;------------------------------------------------------------------
ee_type:    lbr   ee_btype              ; patched by ee_iodet
ee_read:    lbr   ee_bread              ; patched by ee_iodet

;------------------------------------------------------------------
; CDP1854 UART. ee_uread falls into ee_utype to echo when RE.1 bit 0
; says to, which the transfer never does.
;------------------------------------------------------------------
ee_uread:   ghi   re
            shr
          #if UART_GROUP
            sex   r3
            out   EXP_PORT
            db    UART_GROUP
            sex   r2
          #endif
ee_urdlp2:  inp   UART_STATUS
            ani   1
            lbz   ee_urdlp2
            inp   UART_DATA
            lbnf  ee_utyprt
            plo   re

          #if UART_GROUP
            lbr   ee_uecho

ee_utype:   sex   r3
            out   EXP_PORT
            db    UART_GROUP
            sex   r2
ee_uecho:   inp   UART_STATUS
          #else
ee_utype:   inp   UART_STATUS
          #endif
            shl
            lbnf  ee_utype
            glo   re
            str   r2
            out   UART_DATA
            dec   r2                    ; out incremented r(x)

ee_utyprt:
          #if UART_GROUP
            sex   r3
            out   EXP_PORT
            db    NO_GROUP
            sex   r2
          #endif
            rtn

;------------------------------------------------------------------
; Bit-banged serial. Which routines these are depends on the machine,
; exactly as it does in the BIOS: a target that defines FAST_UART gets
; the fixed-rate ones for its clock speed, anything else gets the
; variable-rate pair that reads its timing out of RE.1.
;
; Both are cycle-counted, so each half gets a page of its own: every
; short branch inside them has to stay inside one 256-byte page, and
; not one of the delay loops can afford the extra cycle a long branch
; would cost. For the variable-rate pair the timing value comes from
; RE.1 as the BIOS measured it at boot - there is no re-measuring
; here, which would mean asking the user to type a character first.
;------------------------------------------------------------------

#ifdef FAST_UART
  #if FREQ_KHZ == 4000
    #include  include/fast_uart4000.asm
  #elif FREQ_KHZ == 1790 || FREQ_KHZ == 3686
    #include  include/fast_uart1790.asm
  #else
    #error Fast bit-banged serial is not supported at this clock speed.
  #endif
#else

            .align page

ee_bread:   ghi   re                    ; remove echo bit from delay, get
            shr                         ;  1's complement, save on stack
            sdi   0
            str   r2

            smi   192                   ; if higher than 192, leave as is
            bdf   breprep

            shl                         ; multiply excess by two and add
            add                         ;  back to value, update on stack
            str   r2

breprep:    ldi   0ffh
            plo   re

            ldn   r2                    ; half a bit time, to sample in
            shrc                        ;  the middle of the start bit

brewait:    BRMK  brewait               ; wait here for the start bit

bredely:    adi   4
            bnf   bredely               ;  jump based on first subtract

            shr                         ; split bits 1 and 0 into d and
            bnf   breoddc               ;  df, handle each separately

            bnz   bretest               ; even counts: 2 cycles if bit 1
            br    bretest               ;  is set, 4 otherwise

breoddc:    lsnz                        ; odd counts: 3 cycles if bit 1
            br    bretest               ;  is set, 5 otherwise

bretest:    BRMK  bremark               ; ef2 asserted is a space

            glo   re
            shr
            br    bresave

bremark:    glo   re
            shr
            ori   128                   ; a mark shifts in a one

bresave:    plo   re

            ldn   r2
            bdf   bredely

brestop:    BRSP  brestop               ; wait for the stop bit

            ghi   re                    ; echo the character back if the
            shr                         ;  echo flag is set
            lbdf  ee_btype

            glo   re
            rtn

            .align page

            ; ee_btype sends the character in RE.0, which is where the
            ; SCRT's own "save d" left it.

ee_btype:   glo   re
            stxd

            ghi   re                    ; remove echo bit from delay, get
            shr                         ;  1's complement, save on stack
            sdi   0
            str   r2

            smi   192                   ; if higher than 192, leave as is
            bdf   btywait

            shl                         ; multiply excess by two and add
            add                         ;  back to value, update on stack
            str   r2

btywait:    ldn   r2                    ; delay one bit time before the
            adi   40                    ;  start bit, so back-to-back
            bdf   btystrt               ;  calls cannot violate one

btydly1:    adi   4
            bnf   btydly1

btystrt:    SESP

            ldn   r2
btydly2:    adi   4
            bnf   btydly2

            shr                         ; split bits 1 and 0 into d and
            bnf   btyodds               ;  df, handle each separately

            bnz   btyinit               ; even counts: 2 cycles if bit 1
            br    btyinit               ;  is set, 4 otherwise

btyodds:    lsnz                        ; odd counts: 3 cycles if bit 1
            br    btyinit               ;  is set, 5 otherwise

            ; Shift a one into the register to mark the end

btyinit:    glo   re
            smi   0
            shrc
            plo   re

            bdf   btymark

btyspac:    SESP
            SESP

btyloop:    ldn   r2
btydly3:    adi   4
            bnf   btydly3

            shr                         ; split bits 1 and 0 into d and
            bnf   btyoddc               ;  df, handle each separately

            bnz   btyshft               ; even counts: 2 cycles if bit 1
            br    btyshft               ;  is set, 4 otherwise

btyoddc:    lsnz                        ; odd counts: 3 cycles if bit 1
            br    btyshft               ;  is set, 5 otherwise

btyshft:    glo   re
            shr
            plo   re

            bnf   btyspac

btymark:    SEMK
            bnz   btyloop

            inc   r2                    ; recover the character and return
            ldn   r2
            rtn

#endif

;==================================================================
; Data
;==================================================================

ee_argc:    db    0
ee_argv:    db    0,0
ee_cmd:     db    CMD_NONE
ee_addr:    db    080h,000h             ; -a, default $8000
ee_len:     db    080h,000h             ; -l, default 32768
ee_uart:    db    DEV_AUTO              ; 1 = CDP1854, 0 = bit-banged
ee_err:     db    0
ee_errad:   db    0,0
ee_vaddr:   db    0,0,0,0               ; address and count of the block
                                        ; ee_prog is about to consume
ee_pw:      db    0,0                   ; ee_pword's operand
ee_tmp:     db    0

ee_save_r4: db    0,0                   ; the machine state ee_run puts
ee_save_r5: db    0,0                   ; back on its way out
ee_save_r2: db    0,0
ee_save_re: db    0
ee_save_ie: db    0

ee_s_save:  db    "SAVE",0
ee_s_update:
            db    "UPDATE",0

            ; The stack the critical section runs on. It only ever holds
            ; SCRT return addresses, a handful deep, plus ee_btype's one
            ; pushed character and the scratch byte at m(r2).

ee_stack:   ds    96
ee_stktop:  db    0

            ; Where a block lands between arriving off the wire and going
            ; into the part.

ee_buf:     ds    EE_BLOCK
            db    0                     ; keeps the buffer inside the file
                                        ; image, so the kernel's mem_base
                                        ; lands past it
