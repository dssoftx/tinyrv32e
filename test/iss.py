"""
Instruction-set simulator for tinyrv32e.

Golden model for the RTL: it implements RV32E with exactly the same
implementation-defined behaviour as the hardware, so the two can be compared
write-for-write:

  * 25-bit, word-aligned PC (targets are truncated, never trap)
  * register fields use only their low 4 bits (rd = ir[10:7], ...)
  * funct7 is ignored except bit 30 (sub / sra)
  * FENCE / SYSTEM / unknown opcodes are NOPs
  * misaligned loads and stores just work, byte by byte
  * flash is read-only (writes are dropped), PSRAM is read/write
  * 0x8000_0000 GPIO out (r/w, 8 bit), 0x8000_0004 GPIO in (r/o)

It records the same trace the testbench writes:
  ("R", rd, value)             register write (rd != 0)
  ("W", addr, size, data)      store (size 0/1/2/3 as on mem_size)
"""

MASK32 = 0xFFFFFFFF
PC_MASK = 0x01FFFFFC   # PC_BITS = 25, word aligned


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class ISS:
    def __init__(self, flash: bytes, ram: bytes = b"", ui_in: int = 0):
        self.flash = bytearray(1 << 24)
        self.flash[:len(flash)] = flash
        self.ram = bytearray(1 << 24)
        self.ram[:len(ram)] = ram
        self.ram_written = set()
        self.ui_in = ui_in & 0xFF
        self.gpio_out = 0
        self.x = [0] * 16
        self.pc = 0
        self.trace = []
        self.halted = False
        self.steps = 0

    # ------------------------------------------------------------------
    # Memory
    # ------------------------------------------------------------------
    def _nbytes(self, size):
        return 4 if size & 2 else (2 if size & 1 else 1)

    def read(self, addr, size):
        addr &= MASK32
        if addr & 0x80000000:
            return self.ui_in if addr & 4 else self.gpio_out
        mem = self.ram if addr & 0x01000000 else self.flash
        v = 0
        for i in range(self._nbytes(size)):
            v |= mem[(addr + i) & 0xFFFFFF] << (8 * i)
        return v

    def write(self, addr, size, data):
        addr &= MASK32
        self.trace.append(("W", addr, size, data & MASK32))
        if addr & 0x80000000:
            if not addr & 4:
                self.gpio_out = data & 0xFF
            return
        if not addr & 0x01000000:
            return   # flash: read-only, write dropped
        for i in range(self._nbytes(size)):
            a = (addr + i) & 0xFFFFFF
            self.ram[a] = (data >> (8 * i)) & 0xFF
            self.ram_written.add(a)

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------
    def wr(self, rd, v):
        if rd:
            v &= MASK32
            self.x[rd] = v
            self.trace.append(("R", rd, v))

    def step(self):
        pc = self.pc
        ir = self.read(pc, 2)
        opcode = (ir >> 2) & 0x1F
        rd = (ir >> 7) & 0xF
        f3 = (ir >> 12) & 0x7
        rs1 = (ir >> 15) & 0xF
        rs2 = (ir >> 20) & 0xF
        f7b5 = (ir >> 30) & 1
        a = self.x[rs1]
        b = self.x[rs2]

        imm_i = sext(ir >> 20, 12)
        imm_s = sext(((ir >> 25) << 5) | ((ir >> 7) & 0x1F), 12)
        imm_b = sext((((ir >> 31) & 1) << 12) | (((ir >> 7) & 1) << 11) |
                     (((ir >> 25) & 0x3F) << 5) | (((ir >> 8) & 0xF) << 1), 13)
        imm_u = ir & 0xFFFFF000
        imm_j = sext((((ir >> 31) & 1) << 20) | (((ir >> 12) & 0xFF) << 12) |
                     (((ir >> 20) & 1) << 11) | (((ir >> 21) & 0x3FF) << 1), 21)

        nxt = (pc + 4) & PC_MASK
        link = nxt

        if opcode == 0b01101:                      # LUI
            self.wr(rd, imm_u)
        elif opcode == 0b00101:                    # AUIPC
            self.wr(rd, pc + imm_u)
        elif opcode == 0b11011:                    # JAL
            self.wr(rd, link)
            nxt = (pc + imm_j) & PC_MASK
        elif opcode == 0b11001:                    # JALR
            t = (a + imm_i) & PC_MASK
            self.wr(rd, link)
            nxt = t
        elif opcode == 0b11000:                    # BRANCH
            ua, ub = a, b
            sa, sb = sext(a, 32), sext(b, 32)
            if f3 & 4:
                base = (ua < ub) if f3 & 2 else (sa < sb)
            else:
                base = (ua == ub)
            if base ^ (f3 & 1):
                nxt = (pc + imm_b) & PC_MASK
        elif opcode == 0b00000:                    # LOAD
            v = self.read(a + imm_i, f3 & 3)
            if f3 & 2:
                pass
            elif f3 & 1:
                v = sext(v, 16) if not f3 & 4 else v & 0xFFFF
            else:
                v = sext(v, 8) if not f3 & 4 else v & 0xFF
            self.wr(rd, v)
        elif opcode == 0b01000:                    # STORE
            self.write(a + imm_s, f3 & 3, b)
        elif opcode in (0b00100, 0b01100):         # OP-IMM / OP
            op2 = b if opcode == 0b01100 else imm_i & MASK32
            if f3 == 0:
                v = a - op2 if (opcode == 0b01100 and f7b5) else a + op2
            elif f3 == 1:
                v = a << (op2 & 31)
            elif f3 == 2:
                v = int(sext(a, 32) < sext(op2, 32))
            elif f3 == 3:
                v = int(a < op2)
            elif f3 == 4:
                v = a ^ op2
            elif f3 == 5:
                v = (sext(a, 32) if f7b5 else a) >> (op2 & 31)
            elif f3 == 6:
                v = a | op2
            else:
                v = a & op2
            self.wr(rd, v)
        # everything else: NOP

        self.halted = (nxt == pc)
        self.pc = nxt
        self.steps += 1

    def run(self, max_steps=1_000_000):
        while not self.halted and self.steps < max_steps:
            self.step()
        return self.halted
