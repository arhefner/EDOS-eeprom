#!/usr/bin/env python3
"""
EEPROM's own tests: the real assembled binary, executed on the emulator in
emu1802.py, talking to the real mem-xfr over a pty.

Run with "make test", or directly:

    python3 tests/test_eeprom.py

The point of running the actual binary rather than a model of it is the set
of claims that only the instructions can settle:

  - nothing above $8000 is executed while the overlay is out (the whole
    reason this program carries its own SCRT, stack and console);
  - every write to the part is preceded by the SDP unlock, and none crosses
    a 64-byte page boundary;
  - the bytes on the wire are the ones savebin/loadbin put there, which is
    checked by having the real mem-xfr on the far end rather than a mock.

Not covered, and not coverable here: the bit-banged serial routines, which
are cycle-counted against a baud rate this emulator does not model, and the
AT28C256's own 150us page-load window, likewise.
"""

import os
import pty
import sys
import shutil
import subprocess
import tempfile
import threading
import time
import tty

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import emu1802                                          # noqa: E402

MEMXFR = os.path.join(os.path.dirname(REPO), "Elf-xfer", "mem-xfr", "mem-xfr")
ASM = os.environ.get("ASM", "/opt/elfc/asm02")
LINK = os.environ.get("LINK", "/opt/elfc/link02")

# The machines worth running the whole suite against, and the port each
# reaches its RAM overlay through (sysconfig.inc's own RTC_PORT). 1802MAX
# is not a different board here -- it is the configuration an 1802/Mini
# running mBIOS built as "max" actually uses, which moves the overlay to
# port 1 and switches the bit-banged routines to the fixed-rate ones.
TARGETS = {"1802MINI": 5, "1802MAX": 1}

passes, failures = [], []
TMP = tempfile.mkdtemp(prefix="eeprom-test.")
BINARIES = {}


def build_target(target):
    """Assemble and link for `target` in a scratch tree of its own."""
    out = os.path.join(TMP, target)
    os.makedirs(out, exist_ok=True)
    for item in ("eeprom.asm", "include", "elfdos-sdk"):
        src = os.path.join(REPO, item)
        dst = os.path.join(out, item)
        if os.path.isdir(src):
            if not os.path.exists(dst):
                shutil.copytree(src, dst)
        else:
            shutil.copy(src, dst)
    r = subprocess.run([ASM, "-r", "-D" + target, "-q", "eeprom.asm"],
                       cwd=out, capture_output=True, text=True)
    if r.returncode or "ERROR" in (r.stdout + r.stderr):
        return None, (r.stdout + r.stderr)[-400:]
    r = subprocess.run([LINK, "-b", "-be", "-r", "-o", "eeprom",
                        "eeprom.prg"], cwd=out, capture_output=True,
                       text=True)
    binary = os.path.join(out, "eeprom")
    if r.returncode or not os.path.exists(binary):
        return None, (r.stdout + r.stderr)[-400:]
    return binary, ""


def check(name, cond, detail=""):
    if cond:
        passes.append(name)
    else:
        failures.append("%s%s" % (name, (": " + detail) if detail else ""))


def run(args, rom=None, uart_fd=None, re_hi=0x00, seconds=90.0,
        allow_stall=False, target="1802MINI", bios="mbios", console="uart"):
    """Run EEPROM with `args` (argv[1:]) and hand back the machine.

    allow_stall is for the banner checks: with no host on the far end the
    program parks in its own read loop waiting for a handshake that will
    never come, which is correct behaviour and not something to fail on.
    Everything printed before that point is already on the console.
    """
    with open(BINARIES[target], "rb") as f:
        image = f.read()
    uart = emu1802.Uart(uart_fd)
    m, c = emu1802.build(image, ["EEPROM"] + list(args), uart=uart,
                         re_hi=re_hi, rtc_port=TARGETS[target], bios=bios,
                         console=console)
    if rom is not None:
        m.rom = rom
    try:
        code = c.run(seconds=seconds)
    except RuntimeError:
        if not allow_stall:
            raise
        code = None
    return m, c, code


def banner(args, re_hi=0x00, target="1802MINI", bios="mbios",
           console_dev="uart"):
    """Everything EEPROM prints before it starts listening to the host."""
    m, c, code = run(args, re_hi=re_hi, seconds=4.0, allow_stall=True,
                     target=target, bios=bios, console=console_dev)
    return m, console(m)


def console(m):
    return bytes(m.console).decode("latin-1")


# ------------------------------------------------------------------
# Argument handling -- no host needed, the program never gets as far as
# the handshake.
# ------------------------------------------------------------------

def test_usage():
    m, c, code = run([])
    out = console(m)
    check("no command prints usage", "Usage: EEPROM" in out, out[:120])
    check("no command exits nonzero", code == 1, "code=%d" % code)


def test_banner_defaults():
    # A bad option stops it before the transfer, but after the defaults have
    # been parsed -- so instead drive the banner with a command we abort by
    # giving the UART nothing to say. Simplest is to check the parse through
    # the error paths, and the banner through a real transfer below.
    for args, want in (
        (["frobnicate"], "Unrecognized command"),
        (["save", "-z"], "Unrecognized option"),
        (["save", "-a", "zzz"], "Bad number"),
        (["save", "-a", "0"], "EEPROM starts at $8000"),
        (["save", "-l", "0"], "-l must be at least 1"),
        (["save", "-a", "$C000", "-l", "$4001"], "-l must be at least 1"),
        (["save", "extra"], "Too many arguments"),
    ):
        m, c, code = run(args)
        out = console(m)
        check("rejects %r" % (args,), want in out, out[:160])
        check("rejects %r with code 1" % (args,), code == 1, "code=%d" % code)


def test_number_forms():
    """Every accepted spelling of the same number reaches the banner."""
    for spelling in ("$9000", "0x9000", "9000h", "9000H", "36864"):
        m, out = banner(["save", "-a", spelling, "-l", "1"])
        check("parses %s" % spelling, "$9000-$9000" in out, out[:200])


def test_attached_option_value():
    m, out = banner(["save", "-a$A000", "-l$10"])
    check("-a$A000 attaches", "$A000-$A00F" in out, out[:200])


def test_banner_whole_chip():
    m, out = banner(["save"])
    check("default range is the whole chip",
          "EEPROM save: $8000-$FFFF, $8000 bytes" in out, out[:200])
    check("save prompts for the receiver", "mem-xfr -r" in out,
          out[:300])
    m, out = banner(["update"])
    check("update prompts for the sender", "mem-xfr -s" in out,
          out[:300])


def test_device_report():
    """Which console EEPROM picks, and from what.

    The mBIOS case is the one that matters on real hardware: mBIOS only
    ever sets RE.1 on its bit-bang path -- its own f_bread/f_btype comment
    says "there is probably not the correct baud rate in RE.1" when the
    UART is the console -- so a machine whose console IS the UART can be
    sitting there with a bit-bang-looking RE.1. Resolving the $003C vector
    against the extended BIOS table gets it right anyway; trusting RE.1
    alone would route a whole EEPROM write out of the wrong port.
    """
    for label, kw, want in (
        ("mBIOS, UART console",
         dict(bios="mbios", console_dev="uart", re_hi=0x00), "1854 UART"),
        ("mBIOS, UART console, stale RE.1",
         dict(bios="mbios", console_dev="uart", re_hi=0x40), "1854 UART"),
        ("mBIOS, bit-bang console",
         dict(bios="mbios", console_dev="bbang", re_hi=0x40),
         "bit-banged serial"),
        ("mBIOS, bit-bang console, RE.1 clear",
         dict(bios="mbios", console_dev="bbang", re_hi=0x00),
         "bit-banged serial"),
        ("classic BIOS, RE.1 clear",
         dict(bios="classic", re_hi=0x00), "1854 UART"),
        ("classic BIOS, RE.1 set",
         dict(bios="classic", re_hi=0x40), "bit-banged serial"),
        ("classic BIOS, RE.1 echo bit only",
         dict(bios="classic", re_hi=0x01), "1854 UART"),
    ):
        for target in TARGETS:
            m, out = banner(["save"], target=target, **kw)
            check("%s [%s]" % (label, target), want in out, out[:220])


def test_device_override():
    for target in TARGETS:
        m, out = banner(["save", "-b"], target=target, bios="mbios",
                        console_dev="uart", re_hi=0x00)
        check("-b overrides the vector [%s]" % target,
              "bit-banged serial" in out, out[:220])
        m, out = banner(["save", "-u"], target=target, bios="mbios",
                        console_dev="bbang", re_hi=0x40)
        check("-u overrides the vector [%s]" % target,
              "1854 UART" in out, out[:220])


def test_fast_bitbang_named():
    """A FAST_UART build says so, since the two are not interchangeable."""
    m, out = banner(["save"], target="1802MAX", bios="mbios",
                    console_dev="bbang")
    check("1802MAX names the fast bit-bang", "(fast)" in out, out[:220])
    m, out = banner(["save"], target="1802MINI", bios="mbios",
                    console_dev="bbang")
    check("1802MINI does not", "(fast)" not in out, out[:220])


# ------------------------------------------------------------------
# Real transfers, against the real mem-xfr.
# ------------------------------------------------------------------

def with_memxfr(args, eeprom_args, rom=None, re_hi=0x00, timeout=120,
                target="1802MINI"):
    """Run mem-xfr on one end of a pty and EEPROM on the other."""
    master, slave = pty.openpty()
    tty.setraw(slave)
    tty.setraw(master)

    proc = subprocess.Popen([MEMXFR] + args, stdin=slave, stdout=slave,
                            stderr=subprocess.PIPE)
    os.close(slave)

    result = {}

    def guest():
        try:
            result["m"], result["c"], result["code"] = run(
                eeprom_args, rom=rom, uart_fd=master, re_hi=re_hi,
                seconds=timeout, target=target)
        except Exception as exc:                        # noqa: BLE001
            result["error"] = exc

    # mem-xfr's own tty_raw() flushes its input queue, so nothing may go up
    # the wire until it is certainly past that. It speaks first in both
    # directions anyway; this only guards the emulator's own start-up.
    t = threading.Thread(target=guest)
    time.sleep(0.4)
    t.start()
    t.join(timeout + 30)

    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        result.setdefault("error", RuntimeError("mem-xfr did not exit"))

    result["stderr"] = proc.stderr.read().decode(errors="replace")
    proc.stderr.close()
    os.close(master)
    result["rc"] = proc.returncode
    return result


def pattern(n, seed=0):
    return bytes(((i * 7 + (i >> 8) * 31 + seed) & 0xFF) for i in range(n))


def test_save_whole_chip(target="1802MINI"):
    rom = emu1802.Rom()
    body = pattern(0x8000)
    rom.data[:] = body

    out = os.path.join(TMP, target + "-save.bin")
    r = with_memxfr(["-r", "-d", "0", "-a", "0x8000", "-l", "32768", out],
                    ["save"], rom=rom,
                    target=target)

    check("save: emulator ran clean [%s]" % target, "error" not in r, repr(r.get("error")))
    check("save: mem-xfr exited 0 [%s]" % target, r.get("rc") == 0, r.get("stderr", "")[:300])
    if "m" in r:
        check("save: program reported success [%s]" % target, r["code"] == 0,
              "code=%r / %s" % (r["code"], console(r["m"])[-200:]))
        check("save: says saved [%s]" % target, "EEPROM saved." in console(r["m"]),
              console(r["m"])[-200:])
        check("save: never ran above $8000 with the overlay off [%s]" % target,
              not r["m"].overlay_pc_faults, str(r["m"].overlay_pc_faults[:4]))
        check("save: overlay restored [%s]" % target, r["m"].overlay is True)
        check("save: nothing was written to the part [%s]" % target,
              not rom.blocked and not rom.commits,
              "blocked=%s commits=%s" % (rom.blocked[:4], rom.commits[:4]))
    if os.path.exists(out):
        got = open(out, "rb").read()
        check("save: file matches the part [%s]" % target, got == body,
              "%d bytes, first diff at %s" %
              (len(got), next((i for i in range(min(len(got), len(body)))
                               if got[i] != body[i]), None)))
    else:
        check("save: file written [%s]" % target, False, "no output file")


def test_save_window(target="1802MINI"):
    rom = emu1802.Rom()
    rom.data[:] = pattern(0x8000, seed=9)
    out = os.path.join(TMP, target + "-window.bin")
    r = with_memxfr(["-r", "-d", "0", "-a", "0xC000", "-l", "1000", out],
                    ["save", "-a", "$C000", "-l", "1000"], rom=rom,
                    target=target)
    check("save -a/-l: mem-xfr exited 0 [%s]" % target, r.get("rc") == 0,
          r.get("stderr", "")[:300])
    if os.path.exists(out):
        got = open(out, "rb").read()
        want = bytes(rom.data[0x4000:0x4000 + 1000])
        check("save -a/-l: right slice [%s]" % target, got == want,
              "%d bytes" % len(got))


def test_update_whole_chip(target="1802MINI"):
    rom = emu1802.Rom()
    body = pattern(0x8000, seed=3)
    src = os.path.join(TMP, target + "-update.bin")
    with open(src, "wb") as f:
        f.write(body)

    r = with_memxfr(["-s", "-d", "0", "-a", "0x8000", src], ["update"],
                    rom=rom)

    check("update: emulator ran clean [%s]" % target, "error" not in r,
          repr(r.get("error")))
    check("update: mem-xfr exited 0 [%s]" % target, r.get("rc") == 0,
          r.get("stderr", "")[:300])
    if "m" in r:
        check("update: program reported success [%s]" % target, r["code"] == 0,
              "code=%r / %s" % (r["code"], console(r["m"])[-300:]))
        check("update: says updated [%s]" % target, "EEPROM updated." in console(r["m"]),
              console(r["m"])[-200:])
        check("update: never ran above $8000 with the overlay off [%s]" % target,
              not r["m"].overlay_pc_faults, str(r["m"].overlay_pc_faults[:4]))
        check("update: overlay restored [%s]" % target, r["m"].overlay is True)
    check("update: part now holds the image [%s]" % target, bytes(rom.data) == body,
          "first diff at %s" % next((i for i in range(0x8000)
                                     if rom.data[i] != body[i]), None))
    check("update: SDP refused nothing, because nothing bypassed it [%s]" % target,
          not rom.blocked, str(rom.blocked[:6]))
    check("update: no page load crossed a page boundary [%s]" % target,
          not rom.straddled, str(rom.straddled[:6]))
    check("update: wrote exactly 512 pages of 64 [%s]" % target,
          len(rom.commits) == 512 and all(n == 64 for _, n in rom.commits),
          "%d commits, sizes %s" %
          (len(rom.commits), sorted({n for _, n in rom.commits})))


def test_update_unaligned_window(target="1802MINI"):
    """A run that starts and ends mid-page is the case page splitting is for."""
    rom = emu1802.Rom()
    before = pattern(0x8000, seed=11)
    rom.data[:] = before

    body = bytes(range(200))
    src = os.path.join(TMP, target + "-unaligned.bin")
    with open(src, "wb") as f:
        f.write(body)

    r = with_memxfr(["-s", "-d", "0", "-a", "0x9015", src],
                    ["update", "-a", "$9000", "-l", "$1000"], rom=rom,
                    target=target)

    check("update unaligned: mem-xfr exited 0 [%s]" % target, r.get("rc") == 0,
          r.get("stderr", "")[:300])
    if "m" in r:
        check("update unaligned: success [%s]" % target, r["code"] == 0,
              "code=%r / %s" % (r["code"], console(r["m"])[-300:]))
    off = 0x1015
    check("update unaligned: payload landed [%s]" % target,
          bytes(rom.data[off:off + len(body)]) == body)
    check("update unaligned: nothing either side was touched [%s]" % target,
          bytes(rom.data[:off]) == before[:off] and
          bytes(rom.data[off + len(body):]) == before[off + len(body):])
    check("update unaligned: still no straddled page [%s]" % target, not rom.straddled,
          str(rom.straddled[:6]))
    check("update unaligned: split into 4 page writes [%s]" % target,
          len(rom.commits) == 4,
          "%s" % (rom.commits,))


def test_update_outside_window(target="1802MINI"):
    """A block the host sends outside -a/-l has to be refused, not written."""
    rom = emu1802.Rom()
    before = pattern(0x8000, seed=5)
    rom.data[:] = before

    src = os.path.join(TMP, target + "-outside.bin")
    with open(src, "wb") as f:
        f.write(bytes(64))

    r = with_memxfr(["-s", "-d", "0", "-a", "0xE000", src],
                    ["update", "-a", "$9000", "-l", "$100"], rom=rom,
                    target=target)

    if "m" in r:
        check("out-of-window: refused [%s]" % target, r["code"] == 4,
              "code=%r / %s" % (r["code"], console(r["m"])[-300:]))
        check("out-of-window: says so [%s]" % target,
              "outside the requested address range" in console(r["m"]),
              console(r["m"])[-300:])
        check("out-of-window: overlay restored anyway [%s]" % target,
              r["m"].overlay is True)
    check("out-of-window: part untouched [%s]" % target, bytes(rom.data) == before)


def main():
    for target in TARGETS:
        binary, err = build_target(target)
        if binary is None:
            failures.append("build for %s failed: %s" % (target, err))
        else:
            BINARIES[target] = binary
            passes.append("builds for %s" % target)
    if len(BINARIES) != len(TARGETS):
        for f in failures:
            print("FAIL  %s" % f)
        return 1

    tests = [test_usage, test_banner_defaults, test_number_forms,
             test_attached_option_value, test_banner_whole_chip,
             test_device_report, test_device_override,
             test_fast_bitbang_named]
    wire = [test_save_whole_chip, test_save_window, test_update_whole_chip,
            test_update_unaligned_window, test_update_outside_window]

    if os.path.exists(MEMXFR):
        for target in TARGETS:
            tests += [(t, target) for t in wire]
    else:
        print("mem-xfr not found at %s -- wire tests skipped" % MEMXFR)

    for t in tests:
        t, args = t if isinstance(t, tuple) else (t, None)
        try:
            t(args) if args else t()
        except Exception as exc:                        # noqa: BLE001
            failures.append("%s(%s) raised %r" % (t.__name__, args, exc))

    if "-v" in sys.argv:
        for name in passes:
            print("ok    %s" % name)
    for f in failures:
        print("FAIL  %s" % f)
    print("\n%d passed, %d failed" % (len(passes), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
