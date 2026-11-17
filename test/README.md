# Testbench

* `tb.v`: the design plus two `spi_dev.v` models (flash on CS0, PSRAM on CS1),
  with a halt detector (the CPU spinning on `j .`) and an RTL trace of every
  register write and store.
* `iss.py`: golden instruction-set simulator with the same
  implementation-defined behaviour as the hardware.
* `progs.py`: builds C programs, riscv-tests and random instruction streams.
* `test.py`: cocotb tests; each program runs on the ISS and the design and
  the results are compared.

```sh
git submodule update --init       # riscv-tests
make                              # all RTL tests
make COCOTB_TEST_FILTER=test_c_selftest WAVES=1   # one test, with tb.fst
RANDOM_SEEDS=200 make COCOTB_TEST_FILTER=test_random_programs
RV_TESTS=add,lw make COCOTB_TEST_FILTER=test_riscv_tests
../synth/run.sh && make GATES=yes # gate-level (Yosys netlist or the one from CI)
```
