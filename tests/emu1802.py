"""
A CDP1802 good enough to run EEPROM on, plus the parts of an 1802/Mini it
cares about: the RAM overlay at $8000-$FFFF, an AT28C256 underneath it with
its software data protection actually enforced, a CDP1854 on ports 6/7, and
the small corner of ELF-DOS a program sees at entry.

Why a whole emulator rather than a mock of the protocol: the thing most
worth checking here cannot be seen from the wire at all. EEPROM is only
correct if, from the moment it switches the overlay out, it never touches
anything above $8000 except the part itself -- no BIOS, no kernel, not even
the stack ELF-DOS handed it. That is a statement about which addresses the
real, assembled instructions reach, so the test has to execute them and
watch. Machine.overlay_pc_faults and Rom.blocked below are where it shows.

Timing is NOT modeled: instructions take no time, so this says nothing
about the bit-banged serial routines (which are pure cycle counting) or
about the AT28C256's 150us page-load window. Those stay hardware questions.
"""

import os
import select
import time


class Rom:
    """An AT28C256, with software data protection switched on.

    The chip ignores a write unless it is preceded by the three-byte unlock
    ($AA to $5555, $55 to $2AAA, $A0 to $5555); everything else lands in
    .blocked instead of in the array, which is what makes "the program never
    writes unprotected" an assertion rather than a hope. A page load is held
    until the first read, since a read is exactly what the data-polling loop
    that ends every write cycle does, and is then committed and followed by a
    few reads' worth of busy behaviour for that loop to see.
    """

    PAGE = 64
    BUSY_READS = 5

    def __init__(self, size=0x8000, fill=0xFF):
        self.data = bytearray([fill]) * size
        self.state = 0                  # 0 idle, 1 saw $AA, 2 saw $55, 3 load
        self.page = None
        self.pending = {}
        self.busy = 0
        self.busy_addr = None
        self.toggle = 0
        self.blocked = []               # writes SDP refused
        self.straddled = []             # page loads that crossed a boundary
        self.commits = []               # (page base, byte count)

    def read(self, addr):
        if self.pending:
            self._commit()
        if self.busy:
            self.busy -= 1
            self.toggle ^= 0x40
            return (self.data[addr] ^ 0x80) ^ self.toggle
        return self.data[addr]

    def write(self, addr, value):
        if self.state == 3:
            base = addr & ~(self.PAGE - 1)
            if self.page is None:
                self.page = base
            if base != self.page:
                self.straddled.append((self.page, addr))
                return
            self.pending[addr] = value
            return

        if addr == 0x5555 and value == 0xAA:
            self.state = 1
            return
        if addr == 0x2AAA and value == 0x55 and self.state == 1:
            self.state = 2
            return
        if addr == 0x5555 and value == 0xA0 and self.state == 2:
            self.state = 3
            self.page = None
            self.pending = {}
            return

        self.state = 0
        self.blocked.append((addr, value))

    def _commit(self):
        for addr, value in self.pending.items():
            self.data[addr] = value
        self.commits.append((self.page, len(self.pending)))
        self.busy = self.BUSY_READS
        self.pending = {}
        self.page = None
        self.state = 0


class Uart:
    """A CDP1854 on ports 6 (data) and 7 (status/control), wired to an fd.

    The receive side is a list, not the single holding register the real
    part has, so this cannot show an overrun. What it is here for is the
    protocol, not the pacing.
    """

    def __init__(self, fd=None):
        self.fd = fd
        self.rx = bytearray()
        self.tx = bytearray()
        self.control = None

    def _pump(self, timeout=0.002):
        if self.fd is None or self.rx:
            return
        r, _, _ = select.select([self.fd], [], [], timeout)
        if r:
            try:
                chunk = os.read(self.fd, 4096)
            except OSError:
                return
            self.rx += chunk

    def status(self):
        self._pump()
        return 0x80 | (0x01 if self.rx else 0)

    def read_data(self):
        self._pump()
        if not self.rx:
            return 0
        return self.rx.pop(0)

    def write_data(self, value):
        self.tx.append(value)
        if self.fd is not None:
            os.write(self.fd, bytes([value]))


class Machine:
    LOW_TOP = 0x8000

    def __init__(self, uart=None, rom=None, rtc_port=1, rtc_group=0,
                 exp_port=5):
        self.low = bytearray(self.LOW_TOP)
        self.ovl = bytearray(0x8000)
        self.rom = rom if rom is not None else Rom()
        self.rtc_port = rtc_port        # sysconfig.inc's RTC_PORT, and the
        self.rtc_group = rtc_group      # RTC_GROUP it is reached in: the
        self.exp_port = exp_port        # overlay control only answers while
        self.group = 0                  # EXP_PORT has that group selected
        self.overlay = True
        self.uart = uart if uart is not None else Uart()
        self.console = bytearray()
        self.overlay_pc_faults = []
        self.overlay_off_count = 0

    def read(self, addr):
        addr &= 0xFFFF
        if addr < self.LOW_TOP:
            return self.low[addr]
        if self.overlay:
            return self.ovl[addr - 0x8000]
        return self.rom.read(addr - 0x8000)

    def write(self, addr, value):
        addr &= 0xFFFF
        value &= 0xFF
        if addr < self.LOW_TOP:
            self.low[addr] = value
        elif self.overlay:
            self.ovl[addr - 0x8000] = value
        else:
            self.rom.write(addr - 0x8000, value)

    def load(self, addr, data):
        for i, b in enumerate(bytearray(data)):
            self.write(addr + i, b)

    def out(self, port, value):
        if port == self.exp_port:
            self.group = value
        elif port == self.rtc_port and self.group == self.rtc_group:
            if value == 0x80:
                self.overlay = False
                self.overlay_off_count += 1
            elif value == 0x81:
                self.overlay = True
        elif port == 4:
            self.console.append(value)
        elif port == 6:
            self.uart.write_data(value)
        elif port == 7:
            self.uart.control = value

    def inp(self, port):
        if port == 6:
            return self.uart.read_data()
        if port == 7:
            return self.uart.status()
        return 0


class Cpu:
    def __init__(self, machine):
        self.m = machine
        self.R = [0] * 16
        self.D = 0
        self.DF = 0
        self.P = 0
        self.X = 0
        self.T = 0
        self.Q = 0
        self.IE = 1
        self.EF = [0, 0, 0, 0]          # 1 = asserted; serial idles unasserted
        self.halt_at = None
        self.halted = False
        self.cycles = 0

    # -- helpers ---------------------------------------------------

    def _fetch(self):
        pc = self.R[self.P]
        b = self.m.read(pc)
        self.R[self.P] = (pc + 1) & 0xFFFF
        return b

    def _sbr(self, taken):
        addr = self._fetch()
        if taken:
            self.R[self.P] = (self.R[self.P] & 0xFF00) | addr

    def _lbr(self, taken):
        hi = self._fetch()
        lo = self._fetch()
        if taken:
            self.R[self.P] = (hi << 8) | lo

    def _lskp(self, taken):
        if taken:
            self.R[self.P] = (self.R[self.P] + 2) & 0xFFFF

    def _res(self, t):
        self.DF = 1 if t & 0x100 else 0
        self.D = t & 0xFF

    # -- one instruction -------------------------------------------

    def step(self):
        pc = self.R[self.P]
        if self.halt_at is not None and pc == self.halt_at:
            self.halted = True
            return
        if not self.m.overlay and pc >= 0x8000:
            self.m.overlay_pc_faults.append(pc)
            raise RuntimeError(
                "executed $%04X with the RAM overlay off -- that is BIOS or "
                "kernel territory, and is exactly what must never happen" % pc)

        self.cycles += 1
        op = self._fetch()
        hi, n = op >> 4, op & 0x0F
        m, R, X = self.m, self.R, self.X

        if hi == 0x0:
            if n == 0:
                self.halted = True      # IDL
            else:
                self.D = m.read(R[n])
        elif hi == 0x1:
            R[n] = (R[n] + 1) & 0xFFFF
        elif hi == 0x2:
            R[n] = (R[n] - 1) & 0xFFFF
        elif hi == 0x3:
            cond = {0x0: True,
                    0x1: self.Q == 1,
                    0x2: self.D == 0,
                    0x3: self.DF == 1,
                    0x4: self.EF[0] == 1,
                    0x5: self.EF[1] == 1,
                    0x6: self.EF[2] == 1,
                    0x7: self.EF[3] == 1,
                    0x8: False,
                    0x9: self.Q == 0,
                    0xA: self.D != 0,
                    0xB: self.DF == 0,
                    0xC: self.EF[0] == 0,
                    0xD: self.EF[1] == 0,
                    0xE: self.EF[2] == 0,
                    0xF: self.EF[3] == 0}[n]
            self._sbr(cond)
        elif hi == 0x4:
            self.D = m.read(R[n])
            R[n] = (R[n] + 1) & 0xFFFF
        elif hi == 0x5:
            m.write(R[n], self.D)
        elif hi == 0x6:
            if n == 0:
                R[X] = (R[X] + 1) & 0xFFFF
            elif n < 8:
                m.out(n, m.read(R[X]))
                R[X] = (R[X] + 1) & 0xFFFF
            else:
                value = m.inp(n & 7)
                self.D = value
                m.write(R[X], value)
        elif hi == 0x7:
            if n == 0x0 or n == 0x1:            # RET / DIS
                byte = m.read(R[X])
                R[X] = (R[X] + 1) & 0xFFFF
                self.X = byte >> 4
                self.P = byte & 0x0F
                self.IE = 1 if n == 0 else 0
            elif n == 0x2:                      # LDXA
                self.D = m.read(R[X])
                R[X] = (R[X] + 1) & 0xFFFF
            elif n == 0x3:                      # STXD
                m.write(R[X], self.D)
                R[X] = (R[X] - 1) & 0xFFFF
            elif n == 0x4:                      # ADC
                self._res(m.read(R[X]) + self.D + self.DF)
            elif n == 0x5:                      # SDB
                self._res(m.read(R[X]) + (self.D ^ 0xFF) + self.DF)
            elif n == 0x6:                      # SHRC
                df = self.D & 1
                self.D = (self.D >> 1) | (self.DF << 7)
                self.DF = df
            elif n == 0x7:                      # SMB
                self._res(self.D + (m.read(R[X]) ^ 0xFF) + self.DF)
            elif n == 0x8:                      # SAV
                m.write(R[X], self.T)
            elif n == 0x9:                      # MARK
                self.T = (self.X << 4) | self.P
                m.write(R[2], self.T)
                self.X = self.P
                R[2] = (R[2] - 1) & 0xFFFF
            elif n == 0xA:
                self.Q = 0
            elif n == 0xB:
                self.Q = 1
            elif n == 0xC:                      # ADCI
                self._res(self.D + self._fetch() + self.DF)
            elif n == 0xD:                      # SDBI
                self._res(self._fetch() + (self.D ^ 0xFF) + self.DF)
            elif n == 0xE:                      # SHLC
                df = (self.D >> 7) & 1
                self.D = ((self.D << 1) | self.DF) & 0xFF
                self.DF = df
            elif n == 0xF:                      # SMBI
                self._res(self.D + (self._fetch() ^ 0xFF) + self.DF)
        elif hi == 0x8:
            self.D = R[n] & 0xFF
        elif hi == 0x9:
            self.D = (R[n] >> 8) & 0xFF
        elif hi == 0xA:
            R[n] = (R[n] & 0xFF00) | self.D
        elif hi == 0xB:
            R[n] = (R[n] & 0x00FF) | (self.D << 8)
        elif hi == 0xC:
            if n == 0x0:
                self._lbr(True)
            elif n == 0x1:
                self._lbr(self.Q == 1)
            elif n == 0x2:
                self._lbr(self.D == 0)
            elif n == 0x3:
                self._lbr(self.DF == 1)
            elif n == 0x4:
                pass                            # NOP
            elif n == 0x5:
                self._lskp(self.Q == 0)
            elif n == 0x6:
                self._lskp(self.D != 0)
            elif n == 0x7:
                self._lskp(self.DF == 0)
            elif n == 0x8:
                self._lskp(True)
            elif n == 0x9:
                self._lbr(self.Q == 0)
            elif n == 0xA:
                self._lbr(self.D != 0)
            elif n == 0xB:
                self._lbr(self.DF == 0)
            elif n == 0xC:
                self._lskp(self.IE == 1)
            elif n == 0xD:
                self._lskp(self.Q == 1)
            elif n == 0xE:
                self._lskp(self.D == 0)
            elif n == 0xF:
                self._lskp(self.DF == 1)
        elif hi == 0xD:
            self.P = n
        elif hi == 0xE:
            self.X = n
        else:
            if n == 0x0:
                self.D = m.read(R[X])
            elif n == 0x1:
                self.D |= m.read(R[X])
            elif n == 0x2:
                self.D &= m.read(R[X])
            elif n == 0x3:
                self.D ^= m.read(R[X])
            elif n == 0x4:
                self._res(m.read(R[X]) + self.D)
            elif n == 0x5:
                self._res(m.read(R[X]) + (self.D ^ 0xFF) + 1)
            elif n == 0x6:
                self.DF = self.D & 1
                self.D >>= 1
            elif n == 0x7:
                self._res(self.D + (m.read(R[X]) ^ 0xFF) + 1)
            elif n == 0x8:
                self.D = self._fetch()
            elif n == 0x9:
                self.D |= self._fetch()
            elif n == 0xA:
                self.D &= self._fetch()
            elif n == 0xB:
                self.D ^= self._fetch()
            elif n == 0xC:
                self._res(self.D + self._fetch())
            elif n == 0xD:
                self._res(self._fetch() + (self.D ^ 0xFF) + 1)
            elif n == 0xE:
                self.DF = (self.D >> 7) & 1
                self.D = (self.D << 1) & 0xFF
            elif n == 0xF:
                self._res(self.D + (self._fetch() ^ 0xFF) + 1)

    def run(self, limit=80_000_000, seconds=60.0):
        deadline = time.time() + seconds
        while not self.halted:
            self.step()
            if self.cycles > limit:
                raise RuntimeError("instruction limit reached at $%04X" %
                                   self.R[self.P])
            if not self.cycles % 4096 and time.time() > deadline:
                raise RuntimeError("wall-clock timeout at $%04X" %
                                   self.R[self.P])
        return self.D


# ------------------------------------------------------------------
# The ELF-DOS-shaped environment a program is entered into.
# ------------------------------------------------------------------

PROG_BASE = 0x0D00
EXIT_MAGIC = 0x0004

# What ee_iodet reads to work out what the console is. MBIOS_TYPE is the
# rewritable three-byte LBR mBIOS keeps in low RAM; F_BTYPE/F_UTYPE are
# the extended BIOS table's own LBRs to the two candidates. The routine
# addresses are the ones a real mBIOS build lands on -- nothing here ever
# executes them, they only have to be distinct and findable.
MBIOS_TYPE = 0x003C
F_BTYPE = 0xF803
F_UTYPE = 0xF809
MBIOS_BTYPE_ROUTINE = 0xFD29
MBIOS_UTYPE_ROUTINE = 0xFB29
STACK_TOP = 0xBFFC                      # deliberately ABOVE $8000: if the
                                        # program keeps using it once the
                                        # overlay is gone, it is writing to
                                        # the EEPROM instead, and Rom.blocked
                                        # will say so
K_TYPE = 0x011E
K_MSG = 0x0121
K_INMSG = 0x0124
K_READ = 0x0151

STUB_TYPE = 0x0200
STUB_INMSG = 0x0210

# Elf/OS's own SCRT, laid out so R4/R5 cycle back to their entry points:
# each half's SEP R3 has to fall immediately before the entry it returns to.
SCRT = {
    0xFFD8: [0x83, 0xA6, 0x46, 0xB3, 0x46, 0xA3, 0x8E, 0xD3],   # callbr
    0xFFE0: [0xAE, 0xE2, 0x86, 0x73, 0x96, 0x73, 0x93, 0xB6,
             0x30, 0xD8],                                        # call
    0xFFEA: [0x60, 0x72, 0xB6, 0xF0, 0xA6, 0x8E, 0xD3],          # retbr
    0xFFF1: [0xAE, 0xE2, 0x96, 0xB3, 0x86, 0xA3, 0x30, 0xEA],    # ret
}


def lbr(addr):
    return bytes([0xC0, (addr >> 8) & 0xFF, addr & 0xFF])


def build(program, args, uart=None, re_hi=0x00, rtc_port=1, rtc_group=0,
          exp_port=5, bios="mbios", console="uart"):
    """Load `program` at PROG_BASE with `args` as its argv, ready to run.

    bios="mbios" publishes the $003C console vector the real thing does,
    pointing at whichever routine `console` names; bios="classic" leaves
    that vector clear, so only re_hi is left to go on.
    """
    m = Machine(uart=uart, rtc_port=rtc_port, rtc_group=rtc_group,
                exp_port=exp_port)
    m.load(PROG_BASE, program)

    m.load(F_BTYPE, lbr(MBIOS_BTYPE_ROUTINE))
    m.load(F_UTYPE, lbr(MBIOS_UTYPE_ROUTINE))
    if bios == "mbios":
        m.load(MBIOS_TYPE, lbr(MBIOS_UTYPE_ROUTINE if console == "uart"
                               else MBIOS_BTYPE_ROUTINE))
    else:
        m.load(MBIOS_TYPE, bytes([0x00, 0x00, 0x00]))

    for addr, code in SCRT.items():
        m.load(addr, bytes(code))

    # K_TYPE / K_INMSG: the jump-table slots ELF-DOS publishes, pointing at
    # stubs that put each character on port 4 (this harness's console, kept
    # separate from the UART the transfer itself uses).
    m.load(K_TYPE, bytes([0xC0, STUB_TYPE >> 8, STUB_TYPE & 0xFF]))
    m.load(K_MSG, bytes([0xC0, 0x00, 0x00]))
    m.load(K_INMSG, bytes([0xC0, STUB_INMSG >> 8, STUB_INMSG & 0xFF]))
    m.load(K_READ, bytes([0xC0, 0x00, 0x00]))

    m.load(STUB_TYPE, bytes([0x52, 0x64, 0x22, 0xD5]))          # str r2/out 4/
                                                                # dec r2/sep r5
    m.load(STUB_INMSG, bytes([
        0x46,                                                   # lda r6
        0xC2, STUB_INMSG >> 8, (STUB_INMSG + 8) & 0xFF,         # lbz done
        0x52, 0x64, 0x22,                                       # str r2/out 4/
                                                                # dec r2
        0x30, STUB_INMSG & 0xFF,                                # br inmsg
    ]))
    m.write(STUB_INMSG + 9, 0xD5)                               # done: sep r5

    # argv[]: the pointer table first, then the strings after it.
    argv_table = 0x0400
    strings = 0x0420
    ptr = strings
    for i, arg in enumerate(args):
        m.write(argv_table + i * 2, (ptr >> 8) & 0xFF)
        m.write(argv_table + i * 2 + 1, ptr & 0xFF)
        m.load(ptr, arg.encode() + b"\0")
        ptr += len(arg) + 1

    c = Cpu(m)
    c.P = 3
    c.X = 2
    c.R[3] = PROG_BASE + 6
    c.R[2] = STACK_TOP
    c.R[4] = 0xFFE0
    c.R[5] = 0xFFF1
    c.R[6] = EXIT_MAGIC
    c.R[10] = argv_table                # RA = argv
    c.R[12] = len(args)                 # RC = argc
    c.R[14] = re_hi << 8
    m.write(STACK_TOP + 1, 0x00)        # what the top-level RTN pops
    m.write(STACK_TOP + 2, 0x00)
    c.halt_at = EXIT_MAGIC
    return m, c
