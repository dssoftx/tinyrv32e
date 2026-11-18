# Clocks per instruction class, exact (cycle_count in tb.v):
#   make COCOTB_TEST_MODULES=bench
import cocotb
import progs
from test import run_program

N = 200
CASES = {
    "addi":            "addi x1, x1, 1",
    "add":             "add x1, x1, x2",
    "slli 1":          "slli x1, x2, 1",
    "slli 31":         "slli x1, x2, 31",
    "lui":             "lui x1, 0x12345",
    "beq not taken":   "beq x0, x2, 0f\n0:",
    "beq taken":       "beq x0, x0, 0f\n0:",
    "jal (+4)":        "jal x0, 0f\n0:",
    "auipc":           "auipc x1, 1",
    "lh PSRAM":        "lh x1, 0(x15)",
    "lw PSRAM":        "lw x1, 0(x15)",
    "lb PSRAM":        "lb x1, 0(x15)",
    "sw PSRAM":        "sw x1, 0(x15)",
    "sb PSRAM":        "sb x1, 0(x15)",
    "lw flash":        "lw x1, 0(x0)",
    "lw GPIO":         "lw x1, 4(x14)",
    "sw GPIO":         "sw x1, 0(x14)",
}

def prog(body, n):
    lines = [".section .text.init", ".globl _start", "_start:",
             "  li x14, 0x80000000", "  li x15, 0x01000400", "  li x2, 5", "  li x1, 0"]
    lines += ["  " + body] * n
    lines += ["1: j 1b"]
    return "\n".join(lines) + "\n"

@cocotb.test()
async def bench(dut):
    _, c0 = await run_program(dut, progs.build_asm(prog("nop", 0), "b0"), "base")
    for name, body in CASES.items():
        _, c = await run_program(dut, progs.build_asm(prog(body, N), "b_" + name.replace(" ", "_").replace("(", "").replace(")", "").replace("+", "")), name)
        dut._log.info(f"BENCH {name:16s} {(c - c0) / N:7.1f} clocks/instr")
