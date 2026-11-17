#!/bin/sh
# Quick synthesis to GF180 7-track 3.3V cells (as LibreLane uses for TT): area, cell counts, logic-only
# critical path, and a netlist for gate-level simulation.
#   PDK_ROOT must contain the GF180MCU PDK (ciel / volare layout), or set LIB
#   to a merged liberty file. The real place-and-route runs in the GitHub
#   Actions "gds" workflow (LibreLane).
set -e
cd "$(dirname "$0")"
LIB=${LIB:-$PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib}
SRC="../src/project.v ../src/rv32e_core.v ../src/spi_mem.v"

yosys -q -l synth.log -p "
  read_verilog -sv $SRC
  synth -top tt_um_dssoftx_tinyrv32e -flatten
  dfflegalize -cell \$_DFF_P_ x
  dfflibmap -liberty $LIB
  abc -liberty $LIB -script +strash;&get,-n;&fraig,-x;&put;scorr;dc2;dretime;strash;&get,-n;&dch,-f;&nf;&put;buffer;upsize;dnsize;stime,-p
  opt_clean -purge
  tee -o area.txt stat -liberty $LIB
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
"
grep "Chip area" area.txt
grep "Delay =" synth.log | tail -1 | sed 's/.*Delay =/logic-only critical path:/; s/ps.*/ps/'

# Netlist with power ports, as the testbench expects for GATES=yes
sed 's/^module tt_um_dssoftx_tinyrv32e(/module tt_um_dssoftx_tinyrv32e(VPWR, VGND, /; 0,/^  input /s//  input VPWR;\n  input VGND;\n  input /' \
  netlist.v > ../test/gate_level_netlist.v
echo "wrote test/gate_level_netlist.v"
