/*
 * Behavioural SPI memory for simulation (mode 0).
 *   0x03 read  : any length, auto-increment
 *   0x02 write : only if WRITABLE (PSRAM), auto-increment
 * Address wraps at 2**AW bytes.
 *
 * Halt detector: `halted` goes high once the same address has been read
 * as a single 4-byte burst HALT_REPEATS times in a row with no other
 * traffic on this chip, which is what a CPU spinning on `j .` looks like
 * from the outside. (Longer bursts are streamed straight-line code, e.g.
 * a loop body, and must not count.) This works for
 * RTL and gate-level simulation alike.
 *
 * NEEDS_RESET (PSRAM, APS6404): like the real part, the model must receive
 * Reset-Enable (66h) immediately followed by Reset (99h), no earlier than
 * POWERUP_NS after power-up (the last `clear`), before any read or write.
 * Violations count as protocol errors.
 */

`default_nettype none
`timescale 1ns / 1ps

module spi_dev #(
    parameter WRITABLE     = 0,
    parameter AW           = 18,
    parameter HALT_REPEATS = 4,
    parameter real MIN_CS_HIGH = 30.0,
    parameter NEEDS_RESET  = 0,
    parameter real POWERUP_NS = 150000.0,
    parameter real TRST_NS    = 50.0
) (
    input  wire cs_n,
    input  wire sck,
    input  wire mosi,
    output reg  miso
);

  reg [7:0]  mem [0:(1<<AW)-1];
  integer    bitcnt;
  reg [7:0]  cmd;
  reg [23:0] addr;
  reg [23:0] waddr;
  reg [7:0]  sh;

  reg [23:0] last_addr;
  integer    repeats;
  reg        halted;

  // PSRAM initialization state
  reg      reset_en;   // 66h received, waiting for 99h
  reg      ready;      // initialized by 66h + 99h
  realtime t_powerup;
  realtime t_reset;

  integer i;
  task clear;
    begin
      reset_en  = 1'b0;
      ready     = 1'b0;
      t_powerup = $realtime;
      t_reset   = -1000.0;
      for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 8'h00;
      repeats   = 0;
      last_addr = 24'hFFFFFF;
      halted    = 1'b0;
    end
  endtask

  initial begin
    miso   = 1'b0;
    bitcnt = 0;
    clear;
  end

  // Bus protocol checks (mode 0): SCK low at both CS edges, and CS high
  // for at least MIN_CS_HIGH ns between transactions (flash tSHSL).
  realtime   t_cs_rise;
  integer    protocol_errors;
  initial begin
    t_cs_rise       = -1000.0;
    protocol_errors = 0;
  end

  always @(negedge cs_n) begin
    bitcnt = 0;
    if (sck !== 1'b0) begin
      protocol_errors = protocol_errors + 1;
      $display("SPI protocol error at %0t: CS fell with SCK high", $realtime);
    end
    if (NEEDS_RESET && ready && ($realtime - t_reset < TRST_NS)) begin
      protocol_errors = protocol_errors + 1;
      $display("SPI protocol error at %0t: command %0.1f ns after reset (tRST)",
               $realtime, $realtime - t_reset);
    end
    if ($realtime - t_cs_rise < MIN_CS_HIGH) begin
      protocol_errors = protocol_errors + 1;
      $display("SPI protocol error at %0t: CS high for only %0.1f ns",
               $realtime, $realtime - t_cs_rise);
    end
  end

  always @(posedge cs_n) begin
    t_cs_rise = $realtime;
    if (sck !== 1'b0) begin
      protocol_errors = protocol_errors + 1;
      $display("SPI protocol error at %0t: CS rose with SCK high", $realtime);
    end
    if (NEEDS_RESET) begin
      if (bitcnt == 8 && cmd == 8'h66) begin
        reset_en = 1'b1;
      end else if (bitcnt == 8 && cmd == 8'h99 && reset_en) begin
        reset_en = 1'b0;
        ready    = 1'b1;
        t_reset  = $realtime;
        if ($realtime - t_powerup < POWERUP_NS) begin
          protocol_errors = protocol_errors + 1;
          $display("SPI protocol error at %0t: PSRAM reset only %0.1f us after power-up",
                   $realtime, ($realtime - t_powerup) / 1000.0);
        end
      end else begin
        reset_en = 1'b0;
        if (bitcnt >= 32 && !ready) begin
          protocol_errors = protocol_errors + 1;
          $display("SPI protocol error at %0t: PSRAM command %02h before 66h/99h reset",
                   $realtime, cmd);
        end
      end
    end
    if (bitcnt == 64 && cmd == 8'h03) begin
      if (addr == last_addr) repeats = repeats + 1;
      else repeats = 0;
      last_addr = addr;
      if (repeats >= HALT_REPEATS) halted = 1'b1;
    end else if (bitcnt >= 32) begin
      repeats   = 0;
      last_addr = 24'hFFFFFF;
    end
  end

  always @(posedge sck) begin
    if (!cs_n) begin
      if (bitcnt < 8) begin
        cmd = {cmd[6:0], mosi};
      end else if (bitcnt < 32) begin
        addr = {addr[22:0], mosi};
        if (bitcnt == 31) waddr = addr;
      end else if (cmd == 8'h02 && WRITABLE) begin
        sh = {sh[6:0], mosi};
        if ((bitcnt % 8) == 7) begin
          mem[waddr[AW-1:0]] = sh;
          waddr = waddr + 24'd1;
        end
      end
      bitcnt = bitcnt + 1;
    end
  end

  always @(negedge sck) begin
    if (!cs_n && bitcnt >= 32 && cmd == 8'h03) begin
      miso = mem[(addr + (bitcnt - 32) / 8) & ((1 << AW) - 1)][7 - ((bitcnt - 32) % 8)];
    end
  end

endmodule
