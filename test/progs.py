"""Build test programs for tinyrv32e: C, riscv-tests and random instruction streams."""

import os
import random
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SW = HERE.parent / "sw"
RISCV_TESTS = Path(os.environ.get("RISCV_TESTS", HERE / "riscv-tests"))
BUILD = HERE / "sw_build"

CROSS = os.environ.get("CROSS", "riscv64-unknown-elf-")
ARCH = ["-march=rv32e_zicsr_zifencei", "-mabi=ilp32e"]


def _run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"{' '.join(map(str, cmd))}\n{r.stdout}{r.stderr}")
    return r.stdout


def _image(elf: Path) -> bytes:
    """Flash image: every loadable section at its load address (LMA)."""
    out = elf.with_suffix(".bin")
    _run([CROSS + "objcopy", "-O", "binary", str(elf), str(out)])
    return out.read_bytes()


def _link(objs_or_srcs, name, cflags=(), ldflags=()):
    BUILD.mkdir(exist_ok=True)
    elf = BUILD / f"{name}.elf"
    _run([CROSS + "gcc", *ARCH, "-nostdlib", "-ffreestanding",
          "-T", str(SW / "link.ld"), *cflags, *map(str, objs_or_srcs),
          "-o", str(elf), *ldflags, "-lgcc"])
    _run([CROSS + "objdump", "-d", str(elf)])  # sanity: must disassemble
    (BUILD / f"{name}.dis").write_text(_run([CROSS + "objdump", "-d", str(elf)]))
    return _image(elf)


def symbols(name: str) -> dict:
    """Symbol addresses of a built program (by its ELF stem)."""
    syms = {}
    for line in _run([CROSS + "nm", str(BUILD / f"{name}.elf")]).splitlines():
        f = line.split()
        if len(f) == 3:
            syms[f[2]] = int(f[0], 16)
    return syms


def build_c(src: Path, opt="-O2") -> bytes:
    return _link([SW / "crt0.S", src], Path(src).stem,
                 cflags=[opt, "-Wall", "-I", str(SW)])


def build_riscv_test(name: str) -> bytes:
    src = RISCV_TESTS / "isa" / "rv32ui" / f"{name}.S"
    return _link([src], f"rv32ui-{name}",
                 cflags=["-I", str(SW / "env"),
                         "-I", str(RISCV_TESTS / "isa" / "macros" / "scalar")],
                 ldflags=["-Wl,--no-relax"])


def build_asm(text: str, name: str) -> bytes:
    BUILD.mkdir(exist_ok=True)
    src = BUILD / f"{name}.S"
    src.write_text(text)
    return _link([src], name, ldflags=["-Wl,--no-relax"])


def riscv_test_names():
    d = RISCV_TESTS / "isa" / "rv32ui"
    return sorted(p.stem for p in d.glob("*.S")) if d.exists() else []


# ----------------------------------------------------------------------
# Random instruction streams
# ----------------------------------------------------------------------
# Register use:  x1..x13 random,  x14 = GPIO base,  x15 = PSRAM scratch base.
RREGS = [f"x{i}" for i in range(1, 14)]
SRCS = ["x0"] + RREGS + ["x14", "x15"]


def random_program(seed: int, length: int = 300) -> str:
    rng = random.Random(seed)
    r = lambda: rng.choice(RREGS)
    s = lambda: rng.choice(SRCS)
    interesting = [0, 1, -1, 2, 31, 32, 0x7FFFFFFF, -0x80000000, 0x80000000, 0x55555555,
                   -2048, 2047, 0xFFF, 0x800, 0x7FF]

    lines = [".section .text.init", ".globl _start", "_start:",
             "  li x14, 0x80000000", "  li x15, 0x01000400"]
    for reg in RREGS:
        v = rng.choice(interesting) if rng.random() < 0.3 else rng.getrandbits(32)
        lines.append(f"  li {reg}, {v & 0xFFFFFFFF}")

    label = 0
    for _ in range(length):
        k = rng.random()
        if k < 0.30:
            op = rng.choice(["add", "sub", "and", "or", "xor", "slt", "sltu", "sll", "srl", "sra"])
            lines.append(f"  {op} {r()}, {s()}, {s()}")
        elif k < 0.50:
            op = rng.choice(["addi", "andi", "ori", "xori", "slti", "sltiu"])
            imm = rng.choice([rng.randint(-2048, 2047), rng.choice([-2048, -1, 0, 1, 2047])])
            lines.append(f"  {op} {r()}, {s()}, {imm}")
        elif k < 0.58:
            op = rng.choice(["slli", "srli", "srai"])
            lines.append(f"  {op} {r()}, {s()}, {rng.randint(0, 31)}")
        elif k < 0.62:
            lines.append(f"  lui {r()}, {rng.getrandbits(20)}")
        elif k < 0.64:
            lines.append(f"  auipc {r()}, {rng.getrandbits(20)}")
        elif k < 0.74:
            op = rng.choice(["sb", "sh", "sw"])
            lines.append(f"  {op} {s()}, {rng.randint(-1024, 1023)}(x15)")
        elif k < 0.84:
            op = rng.choice(["lb", "lbu", "lh", "lhu", "lw"])
            base, off = rng.choice([("x15", rng.randint(-1024, 1023)),
                                    ("x0", rng.randint(0, 2047)),      # read code from flash
                                    ("x14", rng.choice([0, 4]))])      # GPIO
            lines.append(f"  {op} {r()}, {off}({base})")
        elif k < 0.87:
            lines.append(f"  sw {s()}, 0(x14)")                        # GPIO out
        elif k < 0.95:
            op = rng.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            label += 1
            lines.append(f"  {op} {s()}, {s()}, L{label}")
            for _ in range(rng.randint(0, 3)):
                lines.append(f"  addi {r()}, {s()}, {rng.randint(-2048, 2047)}")
            lines.append(f"L{label}:")
        elif k < 0.98:
            label += 1
            rd = rng.choice(["x0", r()])
            lines.append(f"  jal {rd}, L{label}")
            lines.append(f"  addi {r()}, {s()}, 1")
            lines.append(f"L{label}:")
        else:
            label += 1
            rd, t = r(), r()
            lines.append(f"  la {t}, L{label}")
            if rng.random() < 0.5:   # exercise the odd-target / offset path
                lines.append(f"  addi {t}, {t}, -3")
                lines.append(f"  jalr {rd}, 3({t})")
            else:
                lines.append(f"  jalr {rd}, 0({t})")
            lines.append(f"  addi {r()}, {s()}, 1")
            lines.append(f"L{label}:")
        if rng.random() < 0.02:
            lines.append(rng.choice(["  fence", "  ecall", "  ebreak", "  fence.i"]))

    lines += ["halt:", "  j halt", ""]
    return "\n".join(lines)
