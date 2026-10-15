# EDOS-eeprom - ELF-DOS utilities for an 1802 machine with an AT28C256
# EEPROM behind a RAM overlay: EEPROM (read/program the chip) and RESET
# (restart as a processor reset would).
#
# TARGET picks the machine out of include/sysconfig.inc, and must match
# the configuration the machine's BIOS was built with: it fixes the
# overlay port and, for EEPROM, which bit-banged serial routines are
# carried (the fixed-rate ones on FAST_UART machines such as 1802MAX).
# The default is the 1802/Mini. Every machine in sysconfig.inc builds.

ASM     ?= /opt/elfc/asm02
LINK    ?= /opt/elfc/link02
TARGET  ?= 1802MINI

ASMFLAGS ?= -r -D$(TARGET)
LFLAGS   ?= -b -be -r

HEADERS = include/sysconfig.inc include/eeprom.def \
	include/fast_uart4000.asm include/fast_uart1790.asm \
	elfdos-sdk/include/opcodes.def elfdos-sdk/include/kernel_api.inc

.PHONY: all test clean

all: eeprom reset

eeprom: eeprom.prg
	$(LINK) $(LFLAGS) -o eeprom eeprom.prg
	rm -f eeprom.lkb

eeprom.prg: eeprom.asm $(HEADERS)
	$(ASM) $(ASMFLAGS) eeprom.asm

reset: reset.prg
	$(LINK) $(LFLAGS) -o reset reset.prg
	rm -f reset.lkb

reset.prg: reset.asm include/sysconfig.inc \
		elfdos-sdk/include/opcodes.def elfdos-sdk/include/kernel_api.inc
	$(ASM) $(ASMFLAGS) reset.asm

# The suite builds every machine in its own TARGETS list into a scratch
# tree of its own and runs each linked binary on tests/emu1802.py, against
# the real mem-xfr from the sibling Elf-xfer tree -- so it deliberately
# does not depend on the default build here. Without mem-xfr present it
# still runs everything that needs no host, and says so.
test:
	python3 tests/test_eeprom.py
	python3 tests/test_reset.py

clean:
	rm -f eeprom eeprom.prg eeprom.build eeprom.lst eeprom.lkb
	rm -f reset reset.prg reset.build reset.lst reset.lkb
	rm -rf tests/__pycache__
	rm -f include/*.prg include/*.build include/*.lst
