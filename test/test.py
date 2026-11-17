# SPDX-License-Identifier: Apache-2.0
"""
cocotb tests for tinyrv32e.

Every program runs twice: on the instruction-set simulator (iss.py) and on
the design. In RTL simulation the full sequence of register writes and
stores must match the ISS exactly; in gate-level simulation (GATES=yes) the
final GPIO value and every PSRAM byte the program wrote are compared.
"""

import os
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

import progs
from iss import ISS

GL = os.environ.get("GATES") == "yes"
RAM_AW = 18
CLK_NS = 20
SIM_DIR = Path.cwd()


# ----------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------
def _write_hex(path, data: bytes):
    path.write_text("\n".join(f"{b:02x}" for b in data) + "\n" if data else "00\n")


async def _load_and_reset(dut, flash: bytes, ui_in: int):
    dut.ena.value = 1
    dut.ui_in.value = ui_in
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    _write_hex(SIM_DIR / "flash.hex", flash)
    _write_hex(SIM_DIR / "ram.hex", b"")
    dut.reload.value = 1
    await Timer(1, unit="ns")
    dut.reload.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


def _read_trace():
    out = []
    for line in (SIM_DIR / "trace.txt").read_text().splitlines():
        f = line.split()
        h = lambda v: int(v, 16) if all(c in "0123456789abcdef" for c in v) else v  # keep X/Z visible
        if f[0] == "R":
            out.append(("R", int(f[1]), h(f[2])))
        else:
            out.append(("W", h(f[1]), int(f[2]), h(f[3])))
    return out


def _fmt(t):
    if t is None:
        return "<end of trace>"
    x = lambda v: f"0x{v:08x}" if isinstance(v, int) else v
    if t[0] == "R":
        return f"x{t[1]} <= {x(t[2])}"
    return f"store size={t[2]} [{x(t[1])}] <= {x(t[3])}"


async def run_program(dut, flash: bytes, name: str, ui_in=0):
    """Run on ISS and DUT, compare, return (instructions, cycles)."""
    iss = ISS(flash, ui_in=ui_in)
    assert iss.run(max_steps=200_000), f"{name}: ISS did not halt"
    max_cycles = iss.steps * 400 + 100_000   # SPI-bound: ~150-250 clocks per instruction

    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _load_and_reset(dut, flash, ui_in)
    perr0 = int(dut.flash.protocol_errors.value) + int(dut.ram.protocol_errors.value)

    # Poll with a plain timer: ClockCycles costs a Python callback per clock.
    cycles = 0
    step = 5000
    while not int(dut.halted.value):
        await Timer(step * CLK_NS, unit="ns")
        cycles += step
        assert cycles < max_cycles, f"{name}: design did not halt within {max_cycles} cycles"

    dut.flush.value = 1
    await Timer(1, unit="ns")
    dut.flush.value = 0

    errors = []

    perr = int(dut.flash.protocol_errors.value) + int(dut.ram.protocol_errors.value) - perr0
    if perr:
        errors.append(f"{perr} SPI protocol errors (see log)")

    gpio = int(dut.uo_out.value)
    if gpio != iss.gpio_out:
        errors.append(f"GPIO out: design 0x{gpio:02x}, ISS 0x{iss.gpio_out:02x}")

    for a in sorted(iss.ram_written):
        hw = int(dut.ram.mem[a & ((1 << RAM_AW) - 1)].value)
        if hw != iss.ram[a]:
            errors.append(f"PSRAM[0x{a:06x}]: design 0x{hw:02x}, ISS 0x{iss.ram[a]:02x}")
            if len(errors) > 8:
                break

    if not GL:
        hw_trace = _read_trace()
        for i in range(max(len(hw_trace), len(iss.trace))):
            h = hw_trace[i] if i < len(hw_trace) else None
            s = iss.trace[i] if i < len(iss.trace) else None
            if h != s:
                errors.append(f"trace diverges at event {i}: design {_fmt(h)}, ISS {_fmt(s)}")
                break

    assert not errors, f"{name}:\n  " + "\n  ".join(errors)
    dut._log.info(f"{name}: OK  {iss.steps} instr, ~{cycles} cycles "
                  f"(~{cycles / max(iss.steps, 1):.0f} cycles/instr)")
    return iss, cycles


# ----------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------
@cocotb.test()
async def test_pins_released_in_reset(dut):
    """While rst_n is low the SPI pins are inputs, so the flash can be programmed."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    assert int(dut.uio_oe.value) == 0x00
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)
    assert int(dut.uio_oe.value) == 0xFB


def _poly3(xs):
    acc = 0
    for x in xs:
        acc = acc * 3 + x
    return acc


@cocotb.test()
async def test_c_selftest(dut):
    flash = progs.build_c(progs.SW / "tests" / "selftest.c")
    iss, _ = await run_program(dut, flash, "selftest.c")
    # Independent check that the program computed the right answers, so a
    # bug shared by the ISS and the RTL can't slip through.
    base = progs.symbols("selftest")["results"] & 0xFFFFFF
    word = lambda i: int.from_bytes(iss.ram[base + 4 * i:base + 4 * i + 4], "little")
    assert word(0) == 144, "fib(12)"
    assert word(1) == zlib.crc32(b"tinyrv32e on gf180"), "crc32"
    assert word(2) == _poly3(sorted([-1, 2, -3, 4, -5, 6, -7, 8])) & 0xFFFFFFFF, "sort"
    assert word(4) == 54, "primes below 256"
    assert word(5) == (-123457 * 97) & 0xFFFFFFFF
    assert word(6) == (-(123457 // 97)) & 0xFFFFFFFF   # C division truncates toward 0
    assert word(7) == (-73) & 0xFFFFFFFF  # -123457 % 97 = -73


@cocotb.test()
async def test_c_gpio_echo(dut):
    flash = progs.build_c(progs.SW / "tests" / "gpio_echo.c")
    await run_program(dut, flash, "gpio_echo.c", ui_in=0x3C)


@cocotb.test()
async def test_riscv_tests(dut):
    """Official riscv-tests rv32ui suite, adapted to this board's environment."""
    names = progs.riscv_test_names()
    assert names, f"riscv-tests not found at {progs.RISCV_TESTS} (git submodule update --init)"
    # Gate-level simulation is ~10x slower: run a representative subset by default.
    default = "" if not GL else "simple,add,sub,sra,slt,lw,lb,lhu,sb,sh,sw,beq,bltu,jal,jalr,auipc"
    only = os.environ.get("RV_TESTS", default)
    if only:
        names = [n for n in names if n in only.split(",")]
    failures, skipped = [], []
    for name in names:
        try:
            flash = progs.build_riscv_test(name)
        except RuntimeError as e:
            # e.g. ma_data uses x28+, which do not exist in RV32E
            if "illegal operands" in str(e):
                skipped.append(name)
                continue
            raise
        try:
            iss, _ = await run_program(dut, flash, f"rv32ui-{name}")
            if iss.gpio_out != 0x01:
                failures.append(f"{name}: test {iss.gpio_out & 0x7F} failed (on ISS and design alike)")
        except AssertionError as e:
            failures.append(str(e))
    if skipped:
        dut._log.info(f"skipped (need registers x16-x31, not in RV32E): {', '.join(skipped)}")
    dut._log.info(f"riscv-tests: {len(names) - len(skipped) - len(failures)} passed, "
                  f"{len(failures)} failed, {len(skipped)} skipped")
    assert not failures, "\n".join(failures)


@cocotb.test()
async def test_random_programs(dut):
    """Random instruction streams with branches, jumps, loads/stores and GPIO."""
    seeds = int(os.environ.get("RANDOM_SEEDS", "6" if GL else "25"))
    for seed in range(1, seeds + 1):
        flash = progs.build_asm(progs.random_program(seed), f"random{seed}")
        await run_program(dut, flash, f"random seed {seed}")
