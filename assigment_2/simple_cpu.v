// simple_cpu.sv
module simple_cpu (
    input clk,
    input rst_n,

    // instruction interface
    input instr_valid,
    input [15:0] instr,
    output reg instr_ready,

    // memory interface
    input [7:0] mem_rdata,
    input mem_ready,
    output reg mem_req,
    output reg mem_we,
    output reg [7:0] mem_addr,
    output reg [7:0] mem_wdata,

    // status
    output reg done,
    output reg [3:0] flags  // {Z, N, C, V}
);

  // FSM states
  localparam IDLE = 3'd0, FETCH = 3'd1, DECODE = 3'd2, EXEC = 3'd3, MEM = 3'd4, WB = 3'd5;

  reg [2:0] state;
  reg [15:0] instr_reg;
  reg [7:0] regfile[0:7];
  reg [7:0] alu_a, alu_b, alu_out;
  reg [7:0] pc;
  reg carry, overflow, zero, negative;

  // decode fields properly (no nested bit select!)
  reg [3:0] opcode;
  reg [2:0] rd_idx, rs_idx;
  reg [3:0] imm4;

  integer i;

  // combinational decode from instr_reg
  always @(*) begin
    opcode = instr_reg[15:12];
    rd_idx = instr_reg[11:9];  // use only top 3 bits for 8 regs
    rs_idx = instr_reg[7:5];
    imm4   = instr_reg[3:0];
  end

  // synchronous FSM
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      pc <= 8'd0;
      instr_ready <= 1'b0;
      done <= 1'b0;
      mem_req <= 1'b0;
      mem_we <= 1'b0;
      flags <= 4'b0;
      for (i = 0; i < 8; i = i + 1) regfile[i] <= 8'd0;
    end else begin
      case (state)
        //--------------------------------------------------
        // IDLE: waiting for instruction fetch
        //--------------------------------------------------
        IDLE: begin
          instr_ready <= 1'b1;
          if (instr_valid) begin
            instr_reg <= instr;
            instr_ready <= 1'b0;
            state <= DECODE;
          end
        end

        //--------------------------------------------------
        // DECODE: read operands
        //--------------------------------------------------
        DECODE: begin
          alu_a <= regfile[rd_idx];
          alu_b <= regfile[rs_idx];
          state <= EXEC;
        end

        //--------------------------------------------------
        // EXEC: perform operation (cycle count: 3 typical)
        //--------------------------------------------------
        EXEC: begin
          case (opcode)
            4'h0: pc <= pc + 1;  // NOP
            4'h1: alu_out <= alu_a + alu_b;  // ADD
            4'h2: alu_out <= alu_a - alu_b;  // SUB
            4'h3: alu_out <= alu_a & alu_b;
            4'h4: alu_out <= alu_a | alu_b;
            4'h5: alu_out <= alu_a ^ alu_b;
            4'h6: alu_out <= alu_a + imm4;  // ADDI
            4'h7: alu_out <= alu_a << imm4;  // SHL
            4'h8: alu_out <= alu_a >> imm4;  // SHR
            4'h9, 4'hA: begin  // LOAD/STORE
              mem_addr <= regfile[rs_idx] + imm4;
              mem_req  <= 1'b1;
              mem_we   <= (opcode == 4'hA);
              if (opcode == 4'hA) mem_wdata <= regfile[rs_idx];
              state <= MEM;
            end
            4'hB: begin  // BRZ
              if (regfile[rs_idx] == 0) pc <= pc + imm4;
              else pc <= pc + 1;
            end
            4'hC: pc <= pc + imm4;  // JMP
            4'hF: done <= 1'b1;  // HALT
            default: pc <= pc + 1;
          endcase
          if (opcode < 4'h9) state <= WB;
        end

        //--------------------------------------------------
        // MEM: wait for memory ready
        //--------------------------------------------------
        MEM: begin
          if (mem_ready) begin
            mem_req <= 1'b0;
            if (opcode == 4'h9) regfile[rd_idx] <= mem_rdata;
            pc <= pc + 1;
            state <= WB;
          end
        end

        //--------------------------------------------------
        // WB: write back results
        //--------------------------------------------------
        WB: begin
          if (opcode >= 4'h1 && opcode <= 4'h8) regfile[rd_idx] <= alu_out;

          // update flags
          zero = (alu_out == 8'd0);
          negative = alu_out[7];
          // simple carry/overflow approximation
          carry = (opcode == 4'h1) ? (alu_a + alu_b > 8'hFF) :
                            (opcode == 4'h2) ? (alu_a < alu_b) : 1'b0;
          overflow = carry ^ negative;
          flags <= {zero, negative, carry, overflow};

          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
