# EDOS-eeprom

`EEPROM` — an ELF-DOS utility for reading and programming the AT28C256 on an
1802/Mini, over the serial port, using the host-side `mem-xfr` tool from
[Elf-xfer](../Elf-xfer).

```
EEPROM SAVE   [-a <addr>] [-l <len>] [-u|-b]
EEPROM UPDATE [-a <addr>] [-l <len>] [-u|-b]
```

| | |
|---|---|
| `SAVE` | send the EEPROM's contents to a host running `mem-xfr -r` |
| `UPDATE` | program the EEPROM from a host running `mem-xfr -s` |
| `-a` | start address, default `$8000` |
| `-l` | byte count, default 32768 |
| `-u` | run the transfer on the CDP1854 UART |
| `-b` | run the transfer on the bit-banged port |

Numbers take a `$` or `0x` prefix, or an `h` suffix, for hex; bare digits are
decimal. `-a` and `-l` accept their value attached (`-a$C000`) or separate
(`-a $C000`). The exit code is 0 on success, 1 for a usage error, and
otherwise the error number printed with the message.

## Using it

The EEPROM lives at `$8000`–`$FFFF` behind a 32K RAM overlay, so nothing can
see it until the overlay is switched out — and switching it out takes the
kernel and the BIOS with it. `EEPROM` therefore prints everything it has to
say *before* the transfer starts and stays silent until it is over. Read its
banner, confirm it says what you expect, then start the host side.

Save the whole chip to a binary file:

```
A:\> EEPROM SAVE
EEPROM save: $8000-$FFFF, $8000 bytes
Console: 1854 UART
Start the host receiver now (mem-xfr -r).
```
```
$ mem-xfr -r -a 0x8000 -l 32768 rom.bin
```

Program a new image in:

```
A:\> EEPROM UPDATE
```
```
$ mem-xfr -s -a 0x8000 rom.bin          # or -x for an Intel hex file
```

`mem-xfr`'s `-d` sets a per-byte delay in microseconds. The default suits a
hardware UART; a bit-banged port on the 1802 side usually needs 500–1000,
and this is not optional there. A bit-banged receive has no holding
register: the 1802 must already be back inside its own polling loop when the
next start bit arrives, and the loop overhead between characters is longer
than the stop bit the sender gives it. Without `-d`, bytes are lost outright
rather than queued.

### What `-a` and `-l` mean on each side

For `SAVE` they say what to send: `-a $C000 -l 1000` reads 1000 bytes from
`$C000`. Give `mem-xfr -r` the same `-a` and `-l` and it will verify them
against what actually arrives.

For `UPDATE` they are a **guard window**, not a destination. The addresses
come from the host — `mem-xfr -s` sends the address each block belongs at,
which for an Intel hex file is whatever the records say — and `EEPROM` writes
each block exactly where the host asked. `-a` and `-l` bound where that is
allowed to be: a block outside the window stops the transfer before that
block is written (blocks the host already sent, and that were inside the
window, are already in the part). The default window is the whole chip, so a
straightforward whole-image update needs neither option; narrowing it is how
you say "this update must only touch the monitor, not the BIOS" and have it
enforced.

### Picking the port

By default the transfer follows the console. mBIOS publishes the live
console routine as a three-byte `LBR` at `$003C`, and the extended BIOS
table names both candidates the same way at `$F803` (bit-bang) and `$F809`
(UART), so `EEPROM` resolves the first against the other two and learns
*which device* the console is — not just an address, which would be useless
to it once the overlay is gone.

That indirection is worth the instructions. mBIOS sets `RE.1` only on its
bit-bang path; its own `f_bread`/`f_btype` comment says "there is probably
not the correct baud rate in RE.1" when the UART is the console. So on an
mBIOS machine whose console *is* the UART, `RE.1` can read as bit-bang, and
a program that trusted it would route a whole EEPROM write out of the wrong
port.

A classic BIOS publishes no such vector, and there the fallback is the test
its own `type:`/`read:` entry points make: `RE.1` shifted right one (bit 0
is the local-echo flag, not a device bit) is zero for the UART. ELF-DOS's
own boot code makes the same two checks in the same order.

The banner says which it picked — check it. `-u` and `-b` override both,
following `MR`'s own precedent, and exist mainly so a transfer can run on a
port that is *not* the console.

On a `FAST_UART` machine the banner says `bit-banged serial (fast)`: the
fixed-rate routines and the variable-rate ones are not interchangeable, and
which one you have is worth seeing.

## How it works, and why it is written this way

**The overlay.** Writing `$80` to `RTC_PORT` switches the RAM overlay out and
the EEPROM in; `$81` puts it back. Between those two writes, everything above
`$8000` that the rest of the system depends on is simply gone — the
non-volatile kernel image, and (on `UPDATE`) the BIOS this program is in the
middle of overwriting.

So for that whole window `EEPROM` calls nothing but itself. It carries its
own SCRT, because the BIOS's own lives at `$FFE0`/`$FFF1`; its own stack,
because ELF-DOS's is not guaranteed to be below `$8000`; its own console
routines; and it turns interrupts off, so a stray one cannot vector through
an `R1` pointing at memory that is no longer there. Everything it touches is
inside its own image at `PROG_BASE`, except the EEPROM itself.

The console routines are copies of the BIOS's, not reimplementations. The
variable-rate bit-bang pair comes from [Elf-eeprom](../Elf-eeprom)'s
`eeprog.asm`; the fixed-rate pair, used on a `FAST_UART` machine, comes
straight out of [mBIOS](../Elfos-mbios) (`include/fast_uart4000.asm` and
`include/fast_uart1790.asm`, whose headers list the three renames applied to
them and nothing else). They are cycle-counted against a baud rate, so
matching the BIOS instruction for instruction is the only way to be sure the
wire still works once the BIOS itself is gone.

**The write lock.** The AT28C256's software data protection is not a mode you
enter and leave. It is a three-byte unlock that prefixes each page write —
`$AA` to chip address `$5555`, `$55` to `$2AAA`, `$A0` to `$5555` (`$D555` and
`$AAAA` as the CPU sees them, with the chip selected by A15) — followed by up
to 64 bytes and a data-polling wait. Protection is never actually off, not
even between blocks, so a crash mid-transfer cannot scribble on the part.

The alternative — the six-byte sequence that disables protection wholesale
for the duration and re-enables it at the end — leaves the chip defenceless
for the whole transfer, *and* leaves it that way permanently if the program
never reaches its own re-enable, since the setting is itself non-volatile.
Per-page unlock gets the same result with neither exposure, and is what
`eeprog.asm` already does on this hardware.

**Buffering.** A page write has to take its 64 bytes less than 150 µs apart,
and no serial line on this machine delivers them that fast, so each block is
read into RAM whole before any of it goes to the chip. The host is waiting on
the block's ack meanwhile, so the write's own milliseconds cost nothing.
Every block is read back and compared after it is written.

**The wire.** The protocol is the one Elf-maxmon's `savebin`/`loadbin`
already speak, byte for byte, which is why the host side needs no new tool.
`mem-xfr.c`'s header comment is the authoritative description of it.

## Errors

| Code | Meaning |
|---|---|
| 1 | usage or command-line error; nothing was attempted |
| 2 | transfer protocol error — the host did not answer as expected |
| 3 | the host sent a block length the protocol does not allow |
| 4 | the host sent a block outside the `-a`/`-l` window |
| 5 | an EEPROM write never completed (address printed) |
| 6 | an EEPROM block read back wrong (address printed) |

A `SAVE` only ever reads, so a failure there leaves the part untouched and
says so. An `UPDATE` can fail at any point, including after blocks have
already gone in, so every failure there reports the part as possibly partly
written — run `UPDATE` again. Either way the overlay is switched back on
before anything is reported, so the system is usable afterwards.

There is no timeout on the wire itself. If the host goes away mid-transfer
the program waits forever, with the overlay still out — press reset; nothing
is lost but the transfer.

## Building

Needs [Asm/02 and Link/02](../Asm-02). `make` assembles and links `eeprom`,
ready to copy onto an ELF-DOS volume.

```
make                    # build for the 1802/Mini
make TARGET=1802MAX     # any machine in include/sysconfig.inc
make test               # run the test suite
make clean
```

`TARGET` must match the configuration **your BIOS was built with**, not the
name of the board — they are not always the same thing, and it is the BIOS's
choice that decides the overlay port, the serial polarity and whether the
bit-banged routines are the fixed-rate ones. An 1802/Mini running mBIOS
built as `max`, for instance, wants `TARGET=1802MAX`: that moves the overlay
from port 5 to port 1 and switches in `fast_uart4000.asm`. Building with the
wrong one will not fail — it will write `$80` to the wrong port and go on to
do the transfer against whatever that did.

All seven machines in `include/sysconfig.inc` build.

`elfdos-sdk/` is a vendored snapshot of the ELF-DOS SDK; see its
`DEVELOPER_GUIDE.md` for the program ABI and kernel API.

## Tests

`tests/` runs the real assembled binary on a CDP1802 emulator
(`tests/emu1802.py`) against the real `mem-xfr` over a pty. The emulator
models the RAM overlay and an AT28C256 that actually enforces its own write
protection, which is what lets the tests assert the things that matter:

- nothing above `$8000` is *executed* while the overlay is out;
- every write to the part is preceded by the unlock sequence, and none
  crosses a 64-byte page boundary;
- the bytes on the wire are the ones `savebin`/`loadbin` put there — checked
  by having the real `mem-xfr` on the far end rather than a mock of it.

The suite builds `1802MINI` and `1802MAX` itself and runs the whole thing
against each, so the overlay-port difference and the fast/standard bit-bang
split are both covered. Console detection is tested against an mBIOS-shaped
machine and a classic-BIOS-shaped one, including the case that motivates the
vector lookup: an mBIOS UART console with a stale, bit-bang-looking `RE.1`.

Two things are deliberately out of reach here, because the emulator does not
model time: the bit-banged serial routines themselves, which are pure cycle
counting against a baud rate, and the AT28C256's own 150 µs page-load
window. Both stay hardware questions — which is why those routines are
copied from the BIOS verbatim rather than written here.
