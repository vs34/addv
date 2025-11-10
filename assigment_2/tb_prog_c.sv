`timescale 1ns / 1ps

// This instruction class replaces the make_random_instr() function.
// It uses constraints to better control test generation.
class instruction;
  // These are the random fields
  rand bit [3:0] opc;
  rand bit [2:0] rd;
  rand bit [2:0] rs;
  rand bit [3:0] imm4;

  // Constraint 1: Prevent HALT (0xF) from running during the main test
  // We will test it directly at the end.
  constraint no_halt {opc != 4'hF;}

  // Constraint 2: Distribute opcodes to hit all bins
  // This gives more weight to memory/branch ops to hit them faster.
  constraint opc_dist {
    opc dist {
      [4'h0 : 4'h8] :/ 6,  // 60% for ALU/Shift ops
      [4'h9 : 4'hA] :/ 2,  // 20% for LOAD/STORE
      [4'hB : 4'hC] :/ 2  // 20% for BRZ/JMP
    };
  }

  // Constraint 3: "Smart" constraint for BRZ (0xB)
  // To make BRZ effective, we need the source register to be 0 sometimes.
  // This makes reg[0] the source 50% of the time for BRZ.
  constraint brz_smart {
    if (opc == 4'hB) {
      rs dist {
        0 := 50,
        [1 : 7] := 50
      };
    }
  }

  // Helper function to build the 16-bit instruction
  // This fixes the 15-bit bug from the original function.
  function bit [15:0] get_instr();
    // Format: {opc[15:12], rd[11:9], 1'b0[8], rs[7:5], 1'b0[4], imm4[3:0]}
    return {opc, rd, 1'b0, rs, 1'b0, imm4};
  endfunction
endclass


// The program name is changed to tb_prog_c
program tb_prog_c (
    tb_if tb_h
);

  // local variables (declarations first)
  int unsigned num_instructions;
  logic [7:0] mem[0:255];

  // Handle for our instruction class
  instruction inst_item;

  // forward-declare any ints used later in functions/tasks
  // (these will be re-declared locally in functions where needed)

  // Coverage groups (Copied directly from tb_prog.sv)
  covergroup cg_opcode @(tb_h.cb);
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

  covergroup cg_flags @(tb_h.cb);
    // flags order in CPU: {Z, N, C, V}
    cp_flags: coverpoint tb_h.flags {
      bins all_flags[] = {[0 : 15]};
    }
  endgroup
  cg_flags cg_fl = new();

  // memory model task (Copied directly from tb_prog.sv)
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


  // main test sequence (CORRECTED)
  task automatic run_tests();
    // **FIX**: All local variable declarations MUST go at the top of the task.
    bit [15:0] inst;
    bit [15:0] halt_instr;

    // wait for external reset deassertion
    wait (tb_h.rst_n == 1);

    // initialize memory
    for (int i = 0; i < 256; i++) mem[i] = $urandom_range(0, 255);

    // spawn memory model
    fork
      mem_model();
    join_none

    // Construct the instruction item
    inst_item = new();

    // issue randomized instruction stream until max count
    num_instructions = 500;
    $display("[%0t] Running %0d random instructions (HALT is constrained)...", $time,
             num_instructions);

    for (int i = 0; i < num_instructions; i++) begin

      $display("%d valus", i);
      // Randomize the class object
      if (!inst_item.randomize()) begin
        $error("Randomization failed!");
        $finish;
      end

      // This is now an assignment, not a declaration.
      inst = inst_item.get_instr();

      // wait until CPU is ready to accept an instruction
      do @(tb_h.cb); while (!tb_h.cb.instr_ready);

      // drive instruction and valid for one clock
      tb_h.cb.instr <= inst;  // Use the local 'inst' variable
      tb_h.cb.instr_valid <= 1'b1;
      @(tb_h.cb);
      tb_h.cb.instr_valid <= 1'b0;

      // sample coverage
      cg_op.sample();
      cg_fl.sample();
    end

    // --- Directed HALT test ---
    $display("[%0t] Random instructions complete. Sending directed HALT.", $time);

    // 1. Turn off the no_halt constraint
    inst_item.no_halt.constraint_mode(0);

    // 2. Randomize again, forcing opc to be HALT
    if (!inst_item.randomize() with {opc == 4'hF;}) begin
      $error("HALT instruction randomization failed!");
      $finish;
    end

    // This is now an assignment, not a declaration.
    halt_instr = inst_item.get_instr();  // This will be 16'hF...

    // 3. Wait and drive the HALT instruction
    do @(tb_h.cb); while (!tb_h.cb.instr_ready);
    tb_h.cb.instr <= halt_instr;  // Use the local 'halt_instr' variable
    tb_h.cb.instr_valid <= 1'b1;
    @(tb_h.cb);
    tb_h.cb.instr_valid <= 1'b0;

    // 4. Wait for the CPU to signal 'done'
    do @(tb_h.cb); while (!tb_h.cb.done);

    $display("[%0t] HALT observed.", $time);

    // 5. Sample coverage one last time to get the HALT bin
    cg_op.sample();
    cg_fl.sample();

    // allow final cycles to settle
    repeat (10) @(tb_h.cb);

    $display("Test complete. Stopping simulation.");
    $finish;
  endtask

  // entry: start the program (called from TOP)
  task start();
    // initialize interface-driven outputs to safe defaults
    tb_h.instr_valid = 0;
    tb_h.instr = 16'h0000;
    tb_h.mem_ready = 0;
    tb_h.mem_rdata = 8'h00;

    @(tb_h.cb);
    run_tests();
  endtask

  // program auto-start: call start() from program context
  initial begin
    // small settle time (optional)
    @(tb_h.cb);
    start();
  end
endprogram
