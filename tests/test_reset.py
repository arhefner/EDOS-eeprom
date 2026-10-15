#!/usr/bin/env python3
"""
RESET's tests: the real assembled binary, run on emu1802.py.

    python3 tests/test_reset.py [-v]

What is checked is the state the program hands over at the moment it
reaches the start address: the RAM overlay switched off through the
machine's own port (and nothing else written above $8000 on the way),
Q off, X = 0, P = 0, interrupts enabled, R0 = the address. The harness
stops at the start address before executing anything there, so the ROM
itself is not involved.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import emu1802                                          # noqa: E402

ASM = os.environ.get("ASM", "/opt/elfc/asm02")
LINK = os.environ.get("LINK", "/opt/elfc/link02")

# Same machines, and the same overlay ports, as test_eeprom.py.
TARGETS = {
    "1802MINI": dict(exp_port=5, rtc_group=1, rtc_port=3),
    "1802MAX": dict(exp_port=5, rtc_group=0, rtc_port=1),
}

passes, failures = [], []
TMP = tempfile.mkdtemp(prefix="reset-test.")
BINARIES = {}


def build_target(target):
    out = os.path.join(TMP, target)
    os.makedirs(out, exist_ok=True)
    for item in ("reset.asm", "include", "elfdos-sdk"):
        src = os.path.join(REPO, item)
        dst = os.path.join(out, item)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy(src, dst)
    r = subprocess.run([ASM, "-r", "-D" + target, "-q", "reset.asm"],
                       cwd=out, capture_output=True, text=True)
    if r.returncode or "ERROR" in (r.stdout + r.stderr):
        return None, (r.stdout + r.stderr)[-400:]
    r = subprocess.run([LINK, "-b", "-be", "-r", "-o", "reset", "reset.prg"],
                       cwd=out, capture_output=True, text=True)
    binary = os.path.join(out, "reset")
    if r.returncode or not os.path.exists(binary):
        return None, (r.stdout + r.stderr)[-400:]
    return binary, ""


def check(name, cond, detail=""):
    if cond:
        passes.append(name)
    else:
        failures.append("%s%s" % (name, (": " + detail) if detail else ""))


def run(args, target, stop_at=None):
    """Run RESET; stop at `stop_at` (the expected start address) or at
    the normal program exit."""
    with open(BINARIES[target], "rb") as f:
        image = f.read()
    m, c = emu1802.build(image, ["RESET"] + list(args), **TARGETS[target])
    rom_before = bytes(m.rom.data)
    c.Q = 1                             # so turning it off is visible
    if stop_at is not None:
        c.halt_at = stop_at
    c.run(seconds=10.0)
    return m, c, bytes(m.console).decode("latin-1"), rom_before


def test_resets(target):
    for args, addr in (([], 0x8000), (["8000"], 0x8000), (["a1B"], 0x0A1B),
                       (["$C0DE"], 0xC0DE), (["0xc0de"], 0xC0DE),
                       (["C0DEh"], 0xC0DE), (["7"], 0x0007),
                       (["0"], 0x0000), (["FFFF"], 0xFFFF)):
        name = "RESET %s [%s]" % (" ".join(args) or "(default)", target)
        try:
            m, c, out, rom_before = run(args, target, stop_at=addr)
        except RuntimeError as exc:
            failures.append("%s: %s" % (name, exc))
            continue
        check(name + " reaches the address", c.halted and
              c.R[c.P] == addr, "PC=$%04X" % c.R[c.P])
        check(name + " says so",
              out == "Resetting to $%04X...\r\n" % addr, repr(out))
        check(name + " P=0 X=0", c.P == 0 and c.X == 0,
              "P=%X X=%X" % (c.P, c.X))
        check(name + " R0", c.R[0] == addr, "R0=$%04X" % c.R[0])
        check(name + " Q off", c.Q == 0)
        check(name + " interrupts on", c.IE == 1)
        check(name + " overlay off", m.overlay is False and
              m.overlay_off_count == 1)
        check(name + " leaves the expander group at 0", m.group == 0,
              "group=%d" % m.group)
        check(name + " writes nothing to the ROM",
              not m.rom.blocked and bytes(m.rom.data) == rom_before,
              str(m.rom.blocked[:4]))


def test_usage(target):
    for args in (["12345"], ["g1"], [""], ["$"], ["0x"], ["h"],
                 ["1h2"], ["80 00"], ["1", "2"]):
        name = "RESET %r refused [%s]" % (args, target)
        m, c, out, _ = run(args, target)
        check(name, "Usage: RESET" in out and c.D == 1,
              "code=%d %r" % (c.D, out[:80]))
        check(name + ", overlay untouched",
              m.overlay is True and m.overlay_off_count == 0)


def main():
    for target in TARGETS:
        binary, err = build_target(target)
        if binary is None:
            failures.append("build for %s failed: %s" % (target, err))
        else:
            BINARIES[target] = binary
            passes.append("builds for %s" % target)
    if len(BINARIES) == len(TARGETS):
        for target in TARGETS:
            for t in (test_resets, test_usage):
                try:
                    t(target)
                except Exception as exc:                # noqa: BLE001
                    failures.append("%s(%s) raised %r" %
                                    (t.__name__, target, exc))

    if "-v" in sys.argv:
        for name in passes:
            print("ok    %s" % name)
    for f in failures:
        print("FAIL  %s" % f)
    print("\n%d passed, %d failed" % (len(passes), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
