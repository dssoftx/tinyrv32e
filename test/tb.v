`default_nettype none
`timescale 1ns / 1ps

/* Testbench: the TT design plus a QSPI Pmod (SPI flash + SPI PSRAM).
 *
 * cocotb drives clk / rst_n / ui_in and loads programs by writing
 * flash.hex and ram.hex, then pulsing `reload`. In RTL simulation every
 * register write and store is logged to trace.txt for comparison against
 * the instruction-set simulator.
 */
module tb ();

  // Waveforms slow the simulation down a lot: enable with WAVES=1.
  initial begin
    if ($test$plusargs("waves")) begin
      $dumpfile("tb.fst");
      $dumpvars(0, tb);
    end
  end

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  wire [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  tt_um_dssoftx_tinyrv32e user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // ---------------------------------------------------------------------
  // QSPI Pmod: undriven pins are pulled high, like the board does.
  // ---------------------------------------------------------------------
  wire cs_flash_n = uio_oe[0] ? uio_out[0] : 1'b1;
  wire mosi       = uio_oe[1] ? uio_out[1] : 1'b1;
  wire sck        = uio_oe[3] ? uio_out[3] : 1'b0;
  wire cs_ram_n   = uio_oe[6] ? uio_out[6] : 1'b1;
  wire cs_ramb_n  = uio_oe[7] ? uio_out[7] : 1'b1;
  wire miso_flash, miso_ram;
  wire miso       = !cs_flash_n ? miso_flash : (!cs_ram_n ? miso_ram : 1'b1);

  assign uio_in = {uio_out[7:3], miso, uio_out[1:0]};

  spi_dev #(.WRITABLE(0)) flash (.cs_n(cs_flash_n), .sck(sck), .mosi(mosi), .miso(miso_flash));
  spi_dev #(.WRITABLE(1), .NEEDS_RESET(1)) ram   (.cs_n(cs_ram_n),  .sck(sck), .mosi(mosi), .miso(miso_ram));
  // Second PSRAM (RAM B): only ever receives the power-up reset.
  wire miso_ramb;
  spi_dev #(.WRITABLE(1), .NEEDS_RESET(1)) ram_b (.cs_n(cs_ramb_n), .sck(sck), .mosi(mosi), .miso(miso_ramb));

  // Programs halt by spinning on `j .` in flash. (The PSRAM model's
  // detector would also fire on four identical word loads in a row.)
  wire halted = flash.halted;

  // Exact clock count from reset release to halt, for performance numbers.
  reg [31:0] cycle_count;
  always @(posedge clk)
    if (!rst_n)       cycle_count <= 32'd0;
    else if (!halted) cycle_count <= cycle_count + 32'd1;

  // ---------------------------------------------------------------------
  // Program loading and trace
  // ---------------------------------------------------------------------
  reg reload = 1'b0;
  reg flush  = 1'b0;
  integer tf = 0;

  always @(posedge reload) begin
    flash.clear;
    ram.clear;
    ram_b.clear;
    $readmemh("flash.hex", flash.mem);
    $readmemh("ram.hex", ram.mem);
`ifndef GL_TEST
    if (tf) $fclose(tf);
    tf = $fopen("trace.txt", "w");
`endif
  end

  always @(posedge flush) if (tf) $fflush(tf);

`ifndef GL_TEST
  wire        tr_rf_we   = user_project.core.rf_we;
  wire [3:0]  tr_rd      = user_project.core.rd;
  wire [31:0] tr_rf_data = user_project.core.rf_wdata;
  wire        tr_st      = user_project.core.mem_req & user_project.core.mem_we &
                           user_project.core.mem_ack;
  wire [31:0] tr_addr    = user_project.core.mem_addr;
  wire [1:0]  tr_size    = user_project.core.mem_size;
  wire [31:0] tr_wdata   = user_project.core.mem_wdata;

  always @(posedge clk) begin
    if (tf && rst_n) begin
      if (tr_rf_we) $fwrite(tf, "R %0d %08x\n", tr_rd, tr_rf_data);
      if (tr_st)    $fwrite(tf, "W %08x %0d %08x\n", tr_addr, tr_size, tr_wdata);
    end
  end
`endif

endmodule
