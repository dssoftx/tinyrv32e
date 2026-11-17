/*
 * Copyright (c) 2026 Daniel
 * SPDX-License-Identifier: Apache-2.0
 *
 * Multi-cycle RV32E core.
 *
 *   - Full RV32E base integer ISA (37 instructions).
 *   - FENCE, ECALL, EBREAK, CSR and unknown opcodes execute as NOPs.
 *   - No interrupts, no exceptions; misaligned jump targets are truncated
 *     to a 4-byte boundary. Misaligned loads/stores just work (the memory
 *     is byte-serial anyway).
 *   - One regfile read port (rs1 and rs2 are read in consecutive cycles),
 *     one write port, iterative 1-bit-per-cycle shifter.
 *
 * Cycle flow: FETCH -> RS1 -> RS2 -> EXEC -> [SHIFT | MEM] -> FETCH
 * The core is memory-bound: an SPI fetch is ~128 clocks, or ~64 when it
 * continues the flash read stream of the previous (sequential) fetch.
 */

`default_nettype none

module rv32e_core #(
    parameter PC_BITS = 25   // flash at 0x0000_0000, PSRAM at 0x0100_0000
) (
    input  wire        clk,
    input  wire        rst_n,

    // Simple memory port. mem_req is held until mem_ack (single cycle).
    output wire        mem_req,
    output wire [31:0] mem_addr,
    output wire        mem_we,
    output wire [1:0]  mem_size,   // 0: byte, 1: half, 2: word
    output wire [31:0] mem_wdata,
    output wire        mem_fetch,  // request is an instruction fetch
    output wire        mem_seq,    // ... at the word after the previous fetch
    input  wire        mem_ack,
    input  wire [31:0] mem_rdata
);

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  localparam S_FETCH = 3'd0;
  localparam S_RS1   = 3'd1;
  localparam S_RS2   = 3'd2;
  localparam S_EXEC  = 3'd3;
  localparam S_SHIFT = 3'd4;
  localparam S_MEM   = 3'd5;

  reg [2:0]          state;
  reg [PC_BITS-1:2]  pc;        // word address, bits [1:0] are always 0
  reg [31:2]         ir;        // bits [1:0] of a 32-bit instruction are 11
  reg [31:0]         A;         // rs1, also the shifter
  reg [31:0]         B;         // rs2 or immediate, B[4:0] is the shift count
  reg [31:0]         rf [1:15]; // x0 is hardwired to zero
  reg                seq;       // pc = previous fetch address + 4

  // ---------------------------------------------------------------------
  // Decode
  // ---------------------------------------------------------------------
  wire [4:0] opcode = ir[6:2];
  wire [3:0] rd     = ir[10:7];   // RV32E: only 16 registers
  wire [2:0] f3     = ir[14:12];
  wire [3:0] rs1    = ir[18:15];
  wire [3:0] rs2    = ir[23:20];
  wire       f7b5   = ir[30];

  wire is_lui    = (opcode == 5'b01101);
  wire is_auipc  = (opcode == 5'b00101);
  wire is_jal    = (opcode == 5'b11011);
  wire is_jalr   = (opcode == 5'b11001);
  wire is_branch = (opcode == 5'b11000);
  wire is_load   = (opcode == 5'b00000);
  wire is_store  = (opcode == 5'b01000);
  wire is_opimm  = (opcode == 5'b00100);
  wire is_op     = (opcode == 5'b01100);

  wire is_alu    = is_op | is_opimm;
  wire is_shift  = is_alu & (f3[1:0] == 2'b01);   // sll, srl, sra
  wire uses_rs2  = is_op | is_branch | is_store;

  wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
  wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
  wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
  wire [31:0] imm_u = {ir[31:12], 12'h000};
  wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

  wire [31:0] imm = is_store              ? imm_s :
                    is_branch             ? imm_b :
                    (is_lui | is_auipc)   ? imm_u :
                    is_jal                ? imm_j :
                                            imm_i;

  // ---------------------------------------------------------------------
  // Register file read (single port)
  // ---------------------------------------------------------------------
  wire [3:0]  rsel  = (state == S_RS1) ? rs1 : rs2;
  wire [31:0] rdata = (rsel == 4'd0) ? 32'h0 : rf[rsel];

  // ---------------------------------------------------------------------
  // ALU
  // ---------------------------------------------------------------------
  // Stores need A + imm while B holds rs2 (the store data).
  wire [31:0] op2 = is_store ? imm_s : B;

  wire is_sub = is_branch |
                (is_alu & (f3 == 3'b010 | f3 == 3'b011)) |  // slt, sltu
                (is_op  & (f3 == 3'b000) & f7b5);            // sub

  wire [32:0] sum = {1'b0, A} + {1'b0, op2 ^ {32{is_sub}}} + {32'h0, is_sub};

  wire eq  = (sum[31:0] == 32'h0);
  wire ltu = ~sum[32];
  wire lt  = (A[31] ^ op2[31]) ? A[31] : sum[31];

  reg [31:0] alu_res;
  always @(*) begin
    case (f3)
      3'b000:  alu_res = sum[31:0];
      3'b010:  alu_res = {31'h0, lt};
      3'b011:  alu_res = {31'h0, ltu};
      3'b100:  alu_res = A ^ op2;
      3'b110:  alu_res = A | op2;
      3'b111:  alu_res = A & op2;
      default: alu_res = sum[31:0];   // shifts are handled in S_SHIFT
    endcase
  end

  wire taken = (f3[2] ? (f3[1] ? ltu : lt) : eq) ^ f3[0];

  // ---------------------------------------------------------------------
  // PC arithmetic
  // ---------------------------------------------------------------------
  wire [31:0]        pc_full = {{(32-PC_BITS){1'b0}}, pc, 2'b00};
  wire [PC_BITS-1:2] pc_inc  = pc + 1'b1;
  wire [31:0]        pc_tgt  = pc_full + imm;          // jal, branch, auipc
  wire [31:0]        link    = {{(32-PC_BITS){1'b0}}, pc_inc, 2'b00};

  // ---------------------------------------------------------------------
  // Load data extension
  // ---------------------------------------------------------------------
  wire [31:0] ld_data = f3[1] ? mem_rdata :
                        f3[0] ? {{16{~f3[2] & mem_rdata[15]}}, mem_rdata[15:0]} :
                                {{24{~f3[2] & mem_rdata[7]}},  mem_rdata[7:0]};

  // ---------------------------------------------------------------------
  // Memory port
  // ---------------------------------------------------------------------
  assign mem_req   = (state == S_FETCH) | (state == S_MEM);
  assign mem_addr  = (state == S_FETCH) ? pc_full : sum[31:0];
  assign mem_we    = (state == S_MEM) & is_store;
  assign mem_size  = (state == S_FETCH) ? 2'd2 : f3[1:0];
  assign mem_wdata = B;
  assign mem_fetch = (state == S_FETCH);
  assign mem_seq   = seq;

  // ---------------------------------------------------------------------
  // Register file write
  // ---------------------------------------------------------------------
  reg        rf_we;
  reg [31:0] rf_wdata;

  always @(*) begin
    rf_we    = 1'b0;
    rf_wdata = alu_res;
    case (state)
      S_EXEC: begin
        rf_we = is_lui | is_auipc | is_jal | is_jalr | (is_alu & ~is_shift);
        if (is_lui)                rf_wdata = imm_u;
        else if (is_auipc)         rf_wdata = pc_tgt;
        else if (is_jal | is_jalr) rf_wdata = link;
      end
      S_SHIFT: begin
        rf_we    = (B[4:0] == 5'd0);
        rf_wdata = A;
      end
      S_MEM: begin
        rf_we    = mem_ack & is_load;
        rf_wdata = ld_data;
      end
      default: ;
    endcase
    if (rd == 4'd0) rf_we = 1'b0;
  end

  always @(posedge clk) begin
    if (rf_we) rf[rd] <= rf_wdata;
  end

  // ---------------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state <= S_FETCH;
      pc    <= {(PC_BITS-2){1'b0}};
      ir    <= 30'h0;
      A     <= 32'h0;
      B     <= 32'h0;
      seq   <= 1'b0;
    end else begin
      case (state)
        S_FETCH: if (mem_ack) begin
          ir    <= mem_rdata[31:2];
          state <= S_RS1;
        end

        S_RS1: begin
          A     <= rdata;
          state <= S_RS2;
        end

        S_RS2: begin
          B     <= uses_rs2 ? rdata : imm;
          state <= S_EXEC;
        end

        S_EXEC: begin
          state <= S_FETCH;
          pc    <= pc_inc;
          seq   <= 1'b1;
          if (is_jal) begin
            pc  <= pc_tgt[PC_BITS-1:2];
            seq <= 1'b0;
          end else if (is_jalr) begin
            pc  <= sum[PC_BITS-1:2];
            seq <= 1'b0;
          end else if (is_branch && taken) begin
            pc  <= pc_tgt[PC_BITS-1:2];
            seq <= 1'b0;
          end
          else if (is_shift) begin
            pc    <= pc;
            state <= S_SHIFT;
          end else if (is_load | is_store) begin
            pc    <= pc;
            state <= S_MEM;
          end
        end

        S_SHIFT: begin
          if (B[4:0] == 5'd0) begin
            pc    <= pc_inc;
            state <= S_FETCH;
          end else begin
            A      <= (f3 == 3'b001) ? {A[30:0], 1'b0}
                                     : {f7b5 & A[31], A[31:1]};
            B[4:0] <= B[4:0] - 5'd1;
          end
        end

        S_MEM: if (mem_ack) begin
          pc    <= pc_inc;
          state <= S_FETCH;
        end

        default: state <= S_FETCH;
      endcase
    end
  end

endmodule
