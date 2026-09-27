# EDOS-eeprom - an ELF-DOS utility for the 1802/Mini's AT28C256 EEPROM.
#
# TARGET picks the machine out of include/sysconfig.inc. The default is
# the 1802/Mini, which is what this was written and tested against;
# SUPERELF, RC1802 and TEST reach their RAM overlay through RTC_PORT the
# same way and should build. The machines that define FAST_UART (1802MAX,
# ELFII, 1802MC) will not: their BIOS uses the fast bit-banged serial
# routines, and eeprom.asm carries a copy of the standard ones only, so a
# build for one of those stops at an #error rather than producing a
# program that would garble the wire.

ASM     ?= /opt/elfc/asm02
LINK    ?= /opt/elfc/link02
TARGET  ?= 1802MINI

ASMFLAGS ?= -r -D$(TARGET)
LFLAGS   ?= -b -be -r

HEADERS = include/sysconfig.inc include/eeprom.def \
	include/fast_uart4000.asm include/fast_uart1790.asm \
	elfdos-sdk/include/opcodes.def elfdos-sdk/include/kernel_api.inc

.PHONY: all test clean

all: eeprom

eeprom: eeprom.prg
	$(LINK) $(LFLAGS) -o eeprom eeprom.prg
	rm -f eeprom.lkb

eeprom.prg: eeprom.asm $(HEADERS)
	$(ASM) $(ASMFLAGS) eeprom.asm

# The suite builds every machine in its own TARGETS list into a scratch
# tree of its own and runs each linked binary on tests/emu1802.py, against
# the real mem-xfr from the sibling Elf-xfer tree -- so it deliberately
# does not depend on the default build here. Without mem-xfr present it
# still runs everything that needs no host, and says so.
test:
	python3 tests/test_eeprom.py

clean:
	rm -f eeprom eeprom.prg eeprom.build eeprom.lst eeprom.lkb
	rm -rf tests/__pycache__
	rm -f include/*.prg include/*.build include/*.lst
