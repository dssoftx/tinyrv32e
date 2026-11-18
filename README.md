# tinyrv32e

A multi-cycle **RV32E** RISC-V CPU for **Tiny Tapeout on GF180MCU**. It runs
C code straight out of SPI flash, keeps its data in SPI PSRAM (both on the
Tiny Tapeout QSPI Pmod) and talks to the world through 8 GPIO inputs and 8
GPIO outputs.

```
            ┌───────────── tt_um_dssoftx_tinyrv32e (2x2 tiles) ──────────────┐
 ui_in[7:0] │──► GPIO in   ┌──────────────┐  mem port  ┌──────────┐   │ uio[0] flash CS
            │              │  rv32e_core  │◄──────────►│ spi_mem  │◄─►│ uio[1] MOSI / [2] MISO
uo_out[7:0] │◄── GPIO out  │ 15x32 regs,  │            │ mode 0,  │   │ uio[3] SCK
            │              │ 1 read port, │            │ clk/2    │   │ uio[6] PSRAM CS
            │              │ serial shift │            └──────────┘   │
            └──────────────┴──────────────┴───────────────────────────┘
```

| | |
|---|---|
| ISA | RV32E (all 37 base instructions; FENCE/ECALL/EBREAK/CSR = NOP) |
| Memory | 16 MB SPI flash at `0x0000_0000`, 16 MB window of SPI PSRAM at `0x0100_0000` |
| I/O | `0x8000_0000` GPIO out, `0x8000_0004` GPIO in |
| Speed | 69 clocks per straight-line ALU instruction, ~118 on average for real C code (SPI-bound): ~210k instr/s at the 25 MHz timing target |
| Area | ~108k µm² of GF180 7-track 3.3 V cells, 661 flip-flops → 2x2 tiles (~47% of the slot) |
| Toolchain | stock `riscv64-unknown-elf-gcc -march=rv32e -mabi=ilp32e` + libgcc |

Details for the datasheet are in [docs/info.md](docs/info.md).

## Layout

```
src/            RTL: project.v (TT wrapper + bus), rv32e_core.v, spi_mem.v
sw/             crt0.S, link.ld, tinyrv32e.h, examples/, tests/, env/ (riscv-tests env)
test/           cocotb testbench, SPI flash/PSRAM models, ISS (golden model)
synth/run.sh    quick Yosys synthesis: area, logic delay, gate-level netlist
```

## Verification

Every test program runs on both the RTL and `test/iss.py`, an instruction-set
simulator that reproduces the hardware's implementation-defined behaviour.
In RTL simulation **every register write and every store** is compared in
order; in gate-level simulation the final GPIO value and every PSRAM byte the
program wrote are compared.

* the official **riscv-tests rv32ui** suite (`test/riscv-tests` submodule),
  with a small environment (`sw/env/riscv_test.h`) that reports pass/fail on GPIO
* random instruction streams (ALU, shifts, branches, jumps, misaligned and
  sub-word loads/stores, flash/PSRAM/GPIO accesses)
* a C self-test (recursion, `.data`/`.bss`, CRC32, sort, sieve, libgcc
  multiply/divide), checked against independently computed answers
* GPIO input/output and the reset-time pin release
* SPI bus protocol checks in the flash/PSRAM models on every transaction:
  SCK low at both CS edges, CS high for at least 30 ns between transactions

```sh
git submodule update --init           # riscv-tests
cd test
make                                  # RTL (Icarus + cocotb), ~8 min
../synth/run.sh && make GATES=yes     # gate-level, needs PDK_ROOT or LIB
make WAVES=1 COCOTB_TEST_FILTER=test_c_selftest   # with waveforms
make COCOTB_TEST_MODULES=bench        # clocks per instruction class
```

Requirements: `iverilog`, `yosys`, `riscv64-unknown-elf-gcc` (with picolibc
multilibs for rv32e), Python with `cocotb`.

## Writing software

```c
#include "tinyrv32e.h"
int main(void) { for (;;) GPIO_OUT = GPIO_IN + 1; }
```

```sh
riscv64-unknown-elf-gcc -march=rv32e -mabi=ilp32e -O2 -nostdlib -ffreestanding \
  -T sw/link.ld -Isw sw/crt0.S main.c -lgcc -o main.elf
riscv64-unknown-elf-objcopy -O binary main.elf main.bin   # write to flash offset 0
```

`crt0.S` clears the register file (it has no reset, to save area), copies
`.data` from flash to PSRAM, clears `.bss`, sets the stack to the top of the
8 MB PSRAM and calls `main`.

## Getting it onto silicon

1. Rename the top module to `tt_um_<your_github_username>_tinyrv32e`:
   `./rename_top.sh <your_github_username>` (edits `src/project.v`,
   `info.yaml`, `test/tb.v` and the synth scripts).
2. Push to GitHub. The `gds` workflow runs LibreLane (synthesis, place and
   route, DRC/LVS, timing) and the `test` workflow runs the cocotb suite; the
   GDS workflow also runs the gate-level test on the real post-layout netlist.
3. Check the timing and utilisation reports in the workflow summary, then
   submit at app.tinytapeout.com. The workflows are pinned to the
   **TTGF26c** shuttle (`tt-gds-action@ttgf26c`); for a later shuttle, update
   those tags from the current `ttgf-verilog-template`.

## Things worth knowing

* **Pinout**: follows the Tiny Tapeout QSPI Pmod; double-check against the
  revision of the Pmod you will use.
* **Fetch streaming**: after an instruction fetch the flash CS stays low, and
  a sequential fetch clocks only the 32 data bits (~64 instead of ~128 clocks).
  Taken branches, jumps, and any PSRAM or flash data access end the stream;
  CS then goes high for 2 clocks before the next transaction. The flash
  therefore sees one long read for each straight-line run of code.
* **PSRAM chip-select time**: an access holds CS low for 128 clocks. Keep the
  clock ≥ 20 MHz so it stays within the PSRAM's maximum CS-low time. (The
  PSRAM never streams; only the flash, which has no CS-low limit.)
* **No traps**: illegal instructions are NOPs, so a bad jump runs off into
  garbage instead of stopping.
* **Faster versions** would use quad SPI, or prefetch the next instruction
  while the current one executes.
