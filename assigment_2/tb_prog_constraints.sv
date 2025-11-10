// tb_prog_constraints.sv
// Constrained program-style testbench for simple_cpu
// Instantiate in TOP as: tb_prog tb_prog_inst (tb_if_i);
`timescale 1ns / 1ps

program tb_prog (
    tb_if tb_h
);

  // Local state / variables
  bit [15:0] rand_instr;
  int unsigned num_instructions;
  logic [7:0] mem[0:255];
  int instr_count;
  int seed;

  // ---------------------------------------------------------------------
  // Combined covergroup with opcode coverpoint, flags coverpoint and cross
  // Automatically sampled on tb_h.cb (posedge clock)
  // ---------------------------------------------------------------------
  covergroup cg_opfl @(tb_h.cb);
    // opcode coverpoint
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
      bins halt = {4'hF};
      bins others = default;
    }

    // flags coverpoint (4-bit {Z,N,C,V})
    cp_flags: coverpoint tb_h.flags {
      bins all_flags[] = {[0 : 15]};
      bins Z_set = {4'b1xxx};
      bins N_set = {4'bx1xx};
      bins C_set = {4'bxx1x};
      bins V_set = {4'bxxx1};
    }

    // cross opcode x flags
    cross cp_opcode, cp_flags;
  endgroup
  cg_opfl cg = new();

  // ---------------------------------------------------------------------
  // Memory model task: responds to mem_req from CPU
  // ---------------------------------------------------------------------
  task automatic mem_model();
    forever begin
      @(tb_h.cb);
      if (tb_h.cb.mem_req) begin
        int delay = $urandom_range(0, 1);
        repeat (delay) @(tb_h.cb);
        if (tb_h.cb.mem_we) begin
          mem[tb_h.cb.mem_addr] = tb_h.cb.mem_wdata;
          tb_h.cb.mem_rdata <= 8'h00;
          tb_h.cb.mem_ready <= 1'b1;
        end else begin
          tb_h.cb.mem_rdata <= mem[tb_h.cb.mem_addr];
          tb_h.cb.mem_ready <= 1'b1;
        end
        @(tb_h.cb);
        tb_h.cb.mem_ready <= 1'b0;
        tb_h.cb.mem_rdata <= 8'h00;
      end else begin
        tb_h.cb.mem_ready <= 1'b0;
        tb_h.cb.mem_rdata <= 8'h00;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Constrained random instruction generator
  // ---------------------------------------------------------------------
  function automatic bit [15:0] make_random_instr();
    bit [3:0] opc;
    bit [2:0] rd, rs;
    bit [3:0] imm4;
    int mode_selector;
    int pick;

    rd = $urandom_range(0, 7);
    rs = $urandom_range(0, 7);
    imm4 = $urandom_range(0, 15);

    mode_selector = $urandom_range(0, 99);
    if (mode_selector < 20) begin
      pick = $urandom_range(0, 99);
      if (pick < 20) opc = 4'h8;  // SHR
      else if (pick < 40) opc = 4'h9;  // LOAD
      else if (pick < 60) opc = 4'hA;  // STORE
      else if (pick < 75) opc = 4'hB;  // BRZ
      else if (pick < 90) opc = 4'hC;  // JMP
      else opc = 4'hF;  // HALT
    end else begin
      pick = $urandom_range(0, 99);
      if (pick < 6) opc = 4'hF;  // small chance HALT
      else if (pick < 18) opc = 4'h9;  // LOAD
      else if (pick < 30) opc = 4'hA;  // STORE
      else if (pick < 42) opc = 4'h8;  // SHR
      else opc = $urandom_range(0, 7);  // common ops NOP..SHL
    end

    // BRZ tuning: give half of BRZ cases a zero-source by selecting rs=0
    if (opc == 4'hB) begin
      if ($urandom_range(0, 1) == 0)
        rs = 3'd0;  // preferentially use reg0 (primer will zero it periodically)
    end

    return {opc, rd, 1'b0, rs, imm4};
  endfunction

  // ---------------------------------------------------------------------
  // Small deterministic primer to prepare registers to exercise flags/BRZ
  // ---------------------------------------------------------------------
  task automatic inject_primer_sequence();
    bit [15:0] seq[0:3];
    seq[0] = {4'h6, 3'd0, 1'b0, 3'd0, 4'h0};  // ADDI r0,0
    seq[1] = {4'h6, 3'd1, 1'b0, 3'd1, 4'hF};  // ADDI r1,15
    seq[2] = {4'h6, 3'd1, 1'b0, 3'd1, 4'hF};
    seq[3] = {4'h6, 3'd1, 1'b0, 3'd1, 4'hF};
    foreach (seq[i]) begin
      do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);
      tb_h.cb.instr <= seq[i];
      tb_h.cb.instr_valid <= 1'b1;
      @(tb_h.cb);
      tb_h.cb.instr_valid <= 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------
  // Main test sequence
  // ---------------------------------------------------------------------
  task automatic run_tests();
    wait (tb_h.rst_n == 1);

    // init memory
    for (int i = 0; i < 256; i++) mem[i] = $urandom_range(0, 255);

    // spawn memory model
    fork
      mem_model();
    join_none

    num_instructions = 800;
    instr_count = 0;
    seed = $urandom();

    for (int i = 0; i < num_instructions; i++) begin
      bit [15:0] inst;
      inst = make_random_instr();

      if ((i % 100) == 0) begin
        inject_primer_sequence();
      end

      if ((i % 125) == 60) begin
        bit [15:0] a0 = {4'h6, 3'd0, 1'b0, 3'd0, 4'h0};  // ADDI r0,0
        bit [15:0] b0 = {4'hB, 3'd0, 1'b0, 3'd0, 4'h1};  // BRZ r0, +1
        do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);
        tb_h.cb.instr <= a0;
        tb_h.cb.instr_valid <= 1'b1;
        @(tb_h.cb);
        tb_h.cb.instr_valid <= 1'b0;
        do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);
        tb_h.cb.instr <= b0;
        tb_h.cb.instr_valid <= 1'b1;
        @(tb_h.cb);
        tb_h.cb.instr_valid <= 1'b0;
        if (tb_h.cb.done) begin
          $display("[%0t] HALT observed during targeted BRZ sequence", $time);
          break;
        end
        continue;
      end

      do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);

      tb_h.cb.instr <= inst;
      tb_h.cb.instr_valid <= 1'b1;
      @(tb_h.cb);
      tb_h.cb.instr_valid <= 1'b0;

      instr_count++;
      if (tb_h.cb.done) begin
        $display("[%0t] HALT observed after %0d instructions", $time, i + 1);
        break;
      end
    end

    repeat (20) @(tb_h.cb);

    $display("Constrained test finished. Instructions issued: %0d", instr_count);
    $finish;
  endtask

  // Program auto-start (program context)
  initial begin
    tb_h.instr_valid = 0;
    tb_h.instr = 16'h0000;
    tb_h.mem_ready = 0;
    tb_h.mem_rdata = 8'h00;
    @(tb_h.cb);
    run_tests();
  end

endprogram
