/*
 * Copyright (c) 2026 Daniel
 * SPDX-License-Identifier: Apache-2.0
 *
 * tinyrv32e: a multi-cycle RV32E CPU that runs code from SPI flash and
 * keeps data in SPI PSRAM, both on a Tiny Tapeout QSPI Pmod.
 *
 * Memory map
 *   0x0000_0000 .. 0x00FF_FFFF  SPI flash (read-only, CS0)  - reset vector 0
 *   0x0100_0000 .. 0x01FF_FFFF  SPI PSRAM (read/write, CS1)
 *   0x8000_0000                 GPIO out  (uo_out), read/write
 *   0x8000_0004                 GPIO in   (ui_in),  read-only
 *
 * Pins (QSPI Pmod on uio, used in single-lane SPI mode)
 *   uio[0] CS0 flash   uio[1] MOSI (SD0)   uio[2] MISO (SD1)   uio[3] SCK
 *   uio[4] SD2 = 1     uio[5] SD3 = 1      uio[6] CS1 PSRAM    uio[7] CS2 = 1
 *
 * While rst_n is low all uio pins are inputs, so the flash can be
 * programmed by another master on the same bus.
 */

`default_nettype none

module tt_um_dssoftx_tinyrv32e (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------
  // CPU
  // ---------------------------------------------------------------------
  wire        mem_req, mem_we, mem_ack, mem_fetch, mem_seq;
  wire [31:0] mem_addr, mem_wdata, mem_rdata;
  wire [1:0]  mem_size;

  rv32e_core core (
      .clk      (clk),
      .rst_n    (rst_n),
      .mem_req  (mem_req),
      .mem_addr (mem_addr),
      .mem_we   (mem_we),
      .mem_size (mem_size),
      .mem_wdata(mem_wdata),
      .mem_fetch(mem_fetch),
      .mem_seq  (mem_seq),
      .mem_ack  (mem_ack),
      .mem_rdata(mem_rdata)
  );

  // ---------------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------------
  wire sel_io   = mem_addr[31];
  wire sel_ram  = mem_addr[24];
  // Writes to flash are dropped (acked immediately, no SPI traffic).
  wire instant  = sel_io | (mem_we & ~sel_ram);

  // ---------------------------------------------------------------------
  // GPIO
  // ---------------------------------------------------------------------
  reg [7:0] gpio_out;

  always @(posedge clk) begin
    if (!rst_n)
      gpio_out <= 8'h00;
    else if (mem_req & sel_io & mem_we & ~mem_addr[2])
      gpio_out <= mem_wdata[7:0];
  end

  wire [31:0] io_rdata = {24'h0, mem_addr[2] ? ui_in : gpio_out};

  // ---------------------------------------------------------------------
  // SPI memory
  // ---------------------------------------------------------------------
  wire        spi_busy, spi_done;
  wire        cs_ramb_n;
  wire [31:0] spi_rdata;
  wire        cs_flash_n, cs_ram_n, sck, mosi;

  wire spi_start = mem_req & ~instant & ~spi_busy & ~spi_done;

  spi_mem spi (
      .clk           (clk),
      .rst_n         (rst_n),
      .start         (spi_start),
      .fetch         (mem_fetch),
      .cont          (mem_seq),
      .sel_ram       (sel_ram),
      .we            (mem_we),
      .size          (mem_size),
      .addr          (mem_addr[23:0]),
      .wdata         (mem_wdata),
      .busy          (spi_busy),
      .done          (spi_done),
      .rdata         (spi_rdata),
      .spi_cs_flash_n(cs_flash_n),
      .spi_cs_ram_n  (cs_ram_n),
      .spi_cs_ramb_n (cs_ramb_n),
      .spi_sck       (sck),
      .spi_mosi      (mosi),
      .spi_miso      (uio_in[2])
  );

  assign mem_ack   = instant ? mem_req : spi_done;
  assign mem_rdata = sel_io ? io_rdata : spi_rdata;

  // ---------------------------------------------------------------------
  // Pins
  // ---------------------------------------------------------------------
  assign uo_out  = gpio_out;
  assign uio_out = {cs_ramb_n, cs_ram_n, 1'b1, 1'b1, sck, 1'b0, mosi, cs_flash_n};
  assign uio_oe  = rst_n ? 8'b1111_1011 : 8'b0000_0000;

  wire _unused = &{ena, uio_in[7:3], uio_in[1:0], mem_addr[30:25], 1'b0};

endmodule
