// Constrained program-style testbench for simple_cpu
// Instantiate in TOP as: tb_prog tb_prog_inst (tb_if_i);
`timescale 1ns / 1ps

program tb_prog_c (
    tb_if tb_h
);

  // Local state / variables
  bit [15:0] rand_instr;
  int unsigned num_instructions;
  logic [7:0] mem[0:255];
  int instr_count;
  int seed;

  // Declare generator handle at program scope for simulator compatibility
  instr_gen_c gen;

  // ---------------------------------------------------------------------
  // Covergroup
  // ---------------------------------------------------------------------
  covergroup cg_opfl @(tb_h.cb);
    cp_opcode: coverpoint tb_h.instr[15:12] {
      bins nop = {4'h0};
      bins add = {4'h1};
      bins sub = {4'h2};
      bins and_ = {4'h3};
      bins or_ = {4'h4};
      bins xor_ = {4'h5};
      bins addi = {4'h6};
      bins shl = {4'h7};
      bins shr = {4'h8};
      bins load = {4'h9};
      bins store = {4'hA};
      bins brz = {4'hB};
      bins jmp = {4'hC};
      bins halt = {4'hD};
      bins others = default;
    }
  endgroup

  cg_opfl cg_inst = new();

  // ---------------------------------------------------------------------
  // Constraint class to hold all constraints and randomization
  // ---------------------------------------------------------------------
  class instr_gen_c;
    rand bit [15:0] rand_instr;

    // opcode constraint — includes all
    constraint opcode_c {
      rand_instr[15:12] inside {4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'hA,
                                4'hB, 4'hC, 4'hD};
    }

    // weighted distribution
    constraint opcode_weight_c {
      rand_instr[15:12] dist {
        4'h0 := 2,
        4'h1 := 2,
        4'h2 := 2,
        4'h3 := 2,
        4'h4 := 2,
        4'h5 := 2,
        4'h6 := 2,
        4'h7 := 2,
        4'h8 := 2,
        4'h9 := 5,
        4'hA := 5,
        4'hB := 5,
        4'hC := 5,
        4'hD := 3
      };
    }

    // memory validity constraint
    constraint mem_addr_c {rand_instr[7:0] < 8'd128;}
  endclass

  // ---------------------------------------------------------------------
  // Initial block: generate & drive randomized instructions
  // ---------------------------------------------------------------------
  initial begin
    num_instructions = 200;
    seed = 42;
    instr_count = 0;

    // instantiate generator (assignment inside procedural block for compatibility)
    gen = new();

    for (int i = 0; i < num_instructions; i++) begin
      if (!gen.randomize()) begin
        $fatal("Randomization failed at %0d", i);
      end

      tb_h.instr = gen.rand_instr;
      tb_h.instr_valid = 1'b1;

      @(tb_h.cb);
      tb_h.instr_valid = 1'b0;

      cg_inst.sample();

      instr_count++;
    end

    $display("Program generation completed: %0d instructions", instr_count);
  end

endprogram
