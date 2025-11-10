// tb_prog_constraints.sv
// Constrained program-style testbench for simple_cpu
// Instantiate in TOP as: tb_prog tb_prog_inst (tb_if_i);
`timescale 1ns / 1ps

program tb_prog_c (
    tb_if tb_h
);

  // ---------------------------------------------------------------------
  // Local state / variables (declarations first)
  // ---------------------------------------------------------------------
  bit [15:0] rand_instr;
  int unsigned num_instructions;
  logic [7:0] mem[0:255];

  // counters / helpers
  int instr_count;
  int seed;

  // ---------------------------------------------------------------------
  // Coverage groups
  // ---------------------------------------------------------------------
  // Opcode coverpoint (explicit bins so missing ops are visible)
  covergroup cg_opcode;
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
  endgroup
  cg_opcode cg_op = new();

  // Flags coverpoint: 4-bit {Z,N,C,V}
  covergroup cg_flags @(tb_h.cb);
    cp_flags: coverpoint tb_h.flags {
      bins all_flags[] = {[0 : 15]};
      bins Z_set = {4'b1xxx};
      bins N_set = {4'bx1xx};
      bins C_set = {4'bxx1x};
      bins V_set = {4'bxxx1};
    }
  endgroup
  cg_flags cg_fl = new();

  // Cross coverage opcode x flags
  covergroup cg_x @(tb_h.cb);
    cross cg_opcode.cp_opcode, cg_flags.cp_flags;
  endgroup
  cg_x cg_cross = new();

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
          // write
          mem[tb_h.cb.mem_addr] = tb_h.cb.mem_wdata;
          tb_h.cb.mem_rdata <= 8'h00;
          tb_h.cb.mem_ready <= 1'b1;
        end else begin
          // read
          tb_h.cb.mem_rdata <= mem[tb_h.cb.mem_addr];
          tb_h.cb.mem_ready <= 1'b1;
        end
        // present ready one cycle
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
  // - Designed to bias and inject under-covered opcodes (SHR, LOAD, STORE,
  //   BRZ, JMP, HALT) while still exercising common ops.
  // ---------------------------------------------------------------------
  function automatic bit [15:0] make_random_instr();
    bit [3:0] opc;
    bit [2:0] rd, rs;
    bit [3:0] imm4;
    int mode_selector;
    int pick;

    // locals declared, now procedural
    rd = $urandom_range(0, 7);
    rs = $urandom_range(0, 7);
    imm4 = $urandom_range(0, 15);

    // Directed-injection mode (20%): choose deliberately from rare ops
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
      // Mostly-random but biased: slightly increase LOAD/STORE/SHR chance
      pick = $urandom_range(0, 99);
      if (pick < 6) opc = 4'hF;  // small chance HALT
      else if (pick < 18) opc = 4'h9;  // LOAD
      else if (pick < 30) opc = 4'hA;  // STORE
      else if (pick < 42) opc = 4'h8;  // SHR
      else begin
        // pick a "common" opcode 0..7 (NOP..SHL) uniformly
        opc = $urandom_range(0, 7);
      end
    end

    // BRZ tuning: give half of BRZ cases a zero-source by selecting rs=0
    if (opc == 4'hB) begin
      if ($urandom_range(0, 1) == 0)
        rs = 3'd0;  // preferentially use reg0 (we will zero reg0 periodically)
    end

    return {opc, rd, 1'b0, rs, imm4};
  endfunction

  // ---------------------------------------------------------------------
  // Small deterministic "primer" sequences to prepare registers:
  // used periodically to set reg0=0, reg1=0xFF, reg2=1 etc.
  // This helps exercise BRZ and flag conditions.
  // ---------------------------------------------------------------------
  task automatic inject_primer_sequence();
    // sequence of ADDI ops to set selected registers
    bit [15:0] seq[0:3];
    // ADDI rd,imm : opcode 6
    // Set reg0 = 0 (ADDI rd0, imm0)
    seq[0] = {4'h6, 3'd0, 1'b0, 3'd0, 4'h0};  // ADDI r0,0
    // Set reg1 = 8'hFF via ADDI sequences (do multiple adds)
    seq[1] = {4'h6, 3'd1, 1'b0, 3'd1, 4'hF};  // ADDI r1,15
    seq[2] = {4'h6, 3'd1, 1'b0, 3'd1, 4'hF};  // ADDI r1,15
    seq[3] = {4'h6, 3'd1, 1'b0, 3'd1, 4'hF};  // ADDI r1,15  (accumulates)
    // Drive them synchronously as normal instructions
    foreach (seq[i]) begin
      // wait for CPU ready and not done
      do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);
      tb_h.cb.instr <= seq[i];
      tb_h.cb.instr_valid <= 1'b1;
      @(tb_h.cb);
      tb_h.cb.instr_valid <= 1'b0;
      // sample coverage on primer ops too
      cg_op.sample();
      cg_fl.sample();
    end
  endtask

  // ---------------------------------------------------------------------
  // Main test sequence
  // ---------------------------------------------------------------------
  task automatic run_tests();
    // wait for reset deassertion
    wait (tb_h.rst_n == 1);

    // initialize memory with random pattern
    for (int i = 0; i < 256; i++) mem[i] = $urandom_range(0, 255);

    // spawn memory model
    fork
      mem_model();
    join_none

    // set run parameters
    num_instructions = 800;
    instr_count = 0;
    seed = $urandom();

    // main random + directed instruction loop
    for (int i = 0; i < num_instructions; i++) begin
      bit [15:0] inst;
      inst = make_random_instr();

      // periodically inject deterministic primer to prepare registers
      if ((i % 100) == 0) begin
        inject_primer_sequence();
      end

      // occasional short deterministic targeted sequence to force a BRZ taken case:
      if ((i % 125) == 60) begin
        // force reg0 = 0 then issue BRZ rs=0
        // set r0 = 0 (ADDI r0,0) then BRZ r0, imm=1
        bit [15:0] a0 = {4'h6, 3'd0, 1'b0, 3'd0, 4'h0};  // ADDI r0,0
        bit [15:0] b0 = {4'hB, 3'd0, 1'b0, 3'd0, 4'h1};  // BRZ r0, +1
        // drive a0
        do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);
        tb_h.cb.instr <= a0;
        tb_h.cb.instr_valid <= 1'b1;
        @(tb_h.cb);
        tb_h.cb.instr_valid <= 1'b0;
        cg_op.sample();
        cg_fl.sample();
        // drive b0
        do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);
        tb_h.cb.instr <= b0;
        tb_h.cb.instr_valid <= 1'b1;
        @(tb_h.cb);
        tb_h.cb.instr_valid <= 1'b0;
        cg_op.sample();
        cg_fl.sample();
        if (tb_h.cb.done) begin
          $display("[%0t] HALT observed during targeted BRZ sequence", $time);
          break;
        end
        // continue main loop
        continue;
      end

      // wait for CPU ready to accept instruction and ensure not done
      do @(tb_h.cb); while (!tb_h.cb.instr_ready || tb_h.cb.done);

      // drive instruction
      tb_h.cb.instr <= inst;
      tb_h.cb.instr_valid <= 1'b1;
      @(tb_h.cb);
      tb_h.cb.instr_valid <= 1'b0;

      // sample covergroups
      cg_op.sample();
      cg_fl.sample();
      cg_cross.sample();

      instr_count++;
      if (tb_h.cb.done) begin
        $display("[%0t] HALT observed after %0d instructions", $time, i + 1);
        break;
      end
    end

    // allow a few cycles to settle
    repeat (20) @(tb_h.cb);

    $display("Constrained test finished. Instructions issued: %0d", instr_count);
    $display("Stopping simulation and writing coverage.");
    $finish;
  endtask

  // ---------------------------------------------------------------------
  // Program entry: auto-start from program context (avoids module->program cross-call)
  // ---------------------------------------------------------------------
  initial begin
    // initialize interface-driven outputs to safe defaults
    tb_h.instr_valid = 0;
    tb_h.instr = 16'h0000;
    tb_h.mem_ready = 0;
    tb_h.mem_rdata = 8'h00;

    // wait one clock to let TOP reset settle
    @(tb_h.cb);
    run_tests();
  end

endprogram
