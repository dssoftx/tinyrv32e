/*
 * Copyright (c) 2026 Daniel
 * SPDX-License-Identifier: Apache-2.0
 *
 * Single-lane SPI memory controller (mode 0, SCK = clk/2).
 *
 * One transaction = 8-bit command + 24-bit address + 1/2/4 data bytes.
 *   read : cmd 0x03, data bytes shifted in on MISO
 *   write: cmd 0x02, data bytes shifted out on MOSI
 * Works with standard SPI NOR flash (W25Q-style, reads only) and
 * APS6404-style SPI PSRAM (reads + writes) sharing one bus.
 *
 * Data is little-endian: byte 0 of the access goes on the wire first and
 * lands in rdata[7:0]. Bytes above the access size are don't-care.
 *
 * The requester must hold wdata stable until done (the core does).
 *
 * Fetch streaming: after a 4-byte instruction fetch from flash, CS0 stays
 * low and the flash keeps its read pointer. If the next request is a
 * sequential fetch (cont = 1), only the 32 data bits are clocked, which
 * halves the cost of straight-line code. Any other request first raises
 * CS0 for two cycles (flash tSHSL), then starts a normal transaction.
 * PSRAM transactions never stream (APS6404 tCEM limit).
 *
 * PSRAM power-up: the APS6404 needs >= 150 us after power-up, then a
 * Reset-Enable (66h) + Reset (99h) sequence, to finish initialization.
 * After rst_n, the controller waits INIT_WAIT clocks (8192: 164 us at
 * 50 MHz, 328 us at 25 MHz), then sends 66h and 99h to both PSRAMs at once
 * (CS1 and CS2 low together; these commands have no output phase). It
 * reports busy until done, so the core's first fetch waits.
 */

`default_nettype none

module spi_mem (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,     // request; may be ignored while closing
    input  wire        fetch,     // this request is an instruction fetch
    input  wire        cont,      // fetch at the address after the last one
    input  wire        sel_ram,   // 0: flash (CS0), 1: PSRAM (CS1)
    input  wire        we,        // 1: write (PSRAM only)
    input  wire [1:0]  size,      // 0: 1 byte, 1: 2 bytes, 2: 4 bytes
    input  wire [23:0] addr,
    input  wire [31:0] wdata,
    output wire        busy,
    output reg         done,      // 1-cycle pulse, rdata valid
    output wire [31:0] rdata,

    output reg         spi_cs_flash_n,
    output reg         spi_cs_ram_n,
    output reg         spi_cs_ramb_n,   // second PSRAM: reset only
    output reg         spi_sck,
    output wire        spi_mosi,
    input  wire        spi_miso
);

  reg [31:0] sr;       // shared in/out shift register, MSB goes out first
  reg [5:0]  cnt;      // bit index within the transaction
  reg        we_r;
  reg [1:0]  size_r;
  reg        fetch_r;
  reg        open;     // CS0 low, flash streaming from the next fetch address
  reg [1:0]  closing;  // CS high cycles left before a new transaction

  reg        busy_r;   // a transaction is running

  // PSRAM power-up sequence
  localparam [12:0] INIT_WAIT = 13'h1FFF;
  reg [12:0] init_wait;  // counts down before the first command
  reg [1:0]  init_step;  // 0: wait, 1: send 66h, 2: send 99h, 3: done
  reg        init_cmd;   // the running transaction is an 8-bit init command
  wire       init_done = (init_step == 2'd3);

  assign busy = busy_r | ~init_done;

  wire stream = open & cont & fetch & ~sel_ram;

  // Last bit index: 32 header bits + 8/16/32 data bits, minus one;
  // an init command is the 8-bit opcode alone.
  wire [5:0] last = init_cmd  ? 6'd7  :
                    size_r[1] ? 6'd63 : (size_r[0] ? 6'd47 : 6'd39);

  // wdata byte-reversed so that byte 0 is shifted out first, MSB first.
  wire [31:0] wdata_wire = {wdata[7:0], wdata[15:8], wdata[23:16], wdata[31:24]};

  assign spi_mosi = sr[31];

  // Bytes arrive in order b0, b1, ... and pile up from the LSB end.
  assign rdata = size_r[1] ? {sr[7:0], sr[15:8], sr[23:16], sr[31:24]} :
                 size_r[0] ? {16'h0000, sr[7:0], sr[15:8]} :
                             {24'h000000, sr[7:0]};

  always @(posedge clk) begin
    if (!rst_n) begin
      busy_r         <= 1'b0;
      done           <= 1'b0;
      spi_cs_flash_n <= 1'b1;
      spi_cs_ram_n   <= 1'b1;
      spi_cs_ramb_n  <= 1'b1;
      init_wait      <= INIT_WAIT;
      init_step      <= 2'd0;
      init_cmd       <= 1'b0;
      spi_sck        <= 1'b0;
      sr             <= 32'h0;
      cnt            <= 6'd0;
      we_r           <= 1'b0;
      size_r         <= 2'd0;
      fetch_r        <= 1'b0;
      open           <= 1'b0;
      closing        <= 2'd0;
    end else begin
      done <= 1'b0;

      if (closing != 2'd0) begin
        // Hold all CS high; the request stays pending in the meantime.
        closing <= closing - 2'd1;
      end else if (busy_r) begin
        if (!spi_sck) begin
          // Rising edge: device samples MOSI.
          spi_sck <= 1'b1;
        end else begin
          // Falling edge: sample MISO (data has been stable for two clk
          // periods), shift, device drives its next bit.
          spi_sck <= 1'b0;
          if (cnt == last) begin
            sr     <= {sr[30:0], spi_miso};
            busy_r <= 1'b0;
            if (init_cmd) begin
              // 66h or 99h sent: CS high for >= 3 clocks before the next
              // command (APS6404 tCPH 18 ns, tRST 50 ns).
              init_cmd      <= 1'b0;
              init_step     <= init_step + 2'd1;
              spi_cs_ram_n  <= 1'b1;
              spi_cs_ramb_n <= 1'b1;
              closing       <= 2'd3;
            end else begin
              done           <= 1'b1;
              spi_cs_flash_n <= fetch_r ? 1'b0 : 1'b1;   // keep streaming
              spi_cs_ram_n   <= 1'b1;
              open           <= fetch_r;
            end
          end else begin
            cnt <= cnt + 6'd1;
            if (cnt == 6'd31 && we_r)
              sr <= wdata_wire;  // header done, start sending data
            else
              sr <= {sr[30:0], spi_miso};
          end
        end
      end else if (!init_done) begin
        if (init_step == 2'd0) begin
          if (init_wait == 13'd0)
            init_step <= 2'd1;
          else
            init_wait <= init_wait - 13'd1;
        end else begin
          // Send 66h (step 1) or 99h (step 2) to both PSRAMs.
          busy_r        <= 1'b1;
          init_cmd      <= 1'b1;
          spi_cs_ram_n  <= 1'b0;
          spi_cs_ramb_n <= 1'b0;
          spi_sck       <= 1'b0;
          sr            <= {(init_step == 2'd1) ? 8'h66 : 8'h99, 24'h000000};
          cnt           <= 6'd0;
          we_r          <= 1'b0;
          fetch_r       <= 1'b0;
        end
      end else if (start && open && !stream) begin
        // End the fetch stream before anything else uses the bus.
        open           <= 1'b0;
        spi_cs_flash_n <= 1'b1;
        closing        <= 2'd1;
      end else if (start) begin
        busy_r         <= 1'b1;
        spi_cs_flash_n <= sel_ram;
        spi_cs_ram_n   <= ~sel_ram;
        spi_sck        <= 1'b0;
        sr             <= {we ? 8'h02 : 8'h03, addr};
        cnt            <= stream ? 6'd32 : 6'd0;   // streaming: data bits only
        we_r           <= we;
        size_r         <= size;
        fetch_r        <= fetch & ~sel_ram & ~we & size[1];
        open           <= 1'b0;
      end
    end
  end

endmodule
