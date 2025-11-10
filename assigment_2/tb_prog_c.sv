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
  // **NEW**: Handle for our instruction class
  instruction inst_item;
  // forward-declare any ints used later in functions/tasks
  // (these will be re-declared locally in functions where needed)

  // =================================================================
  // *** FIX 1: Remove @(tb_h.cb) to disable automatic sampling
  // =================================================================
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

  // =================================================================
  // *** FIX 1: Remove @(tb_h.cb) to disable automatic sampling
  // =================================================================
  covergroup cg_flags;
    // flags order in CPU: {Z, N, C, V}
    cp_flags: coverpoint tb_h.flags {
      bins all_flags[] = {[0 : 15]};
    }
  endgroup
  cg_flags cg_fl = new();


  // =================================================================
  // *** FIX 2: Declare persistent variable *outside* the automatic task
  // =================================================================
  logic mem_ready_ff;  // This now has a static lifetime

  // memory model task (FIXED to prevent race condition)
  task automatic mem_model();
    // *** FIX 2 ***: Variable declaration was moved outside

    // Default state
    tb_h.cb.mem_ready <= 1'b0;
    tb_h.cb.mem_rdata <= 8'h00;
    mem_ready_ff <= 1'b0;

    forever begin
      @(tb_h.cb);  // Wait for the clock

      // --- Handle Ready Signal ---
      // Drive the ready signal from our registered value
      tb_h.cb.mem_ready <= mem_ready_ff;
      // Default: set ready back to 0 next cycle
      mem_ready_ff <= 1'b0;

      // --- Handle Request ---
      if (tb_h.cb.mem_req) begin
        //
        // CPU request is high. Service it.
        // We will set mem_ready_ff = 1, so it goes high *next* clock.
        //
        mem_ready_ff <= 1'b1;

        if (tb_h.cb.mem_we) begin
          // Write operation
          mem[tb_h.cb.mem_addr] = tb_h.cb.mem_wdata;
          tb_h.cb.mem_rdata <= 8'h00;  // Drive 0 on data bus for writes
        end else begin
          // Read operation
          tb_h.cb.mem_rdata <= mem[tb_h.cb.mem_addr];
        end

      end else begin
        // No request, just drive 0
        tb_h.cb.mem_rdata <= 8'h00;
      end
    end
  endtask

  // --- **NEW**: Helper task to drive a single instruction
  task automatic drive_instr(bit [15:0] inst);
    // 1. Wait for CPU to be ready
    do @(tb_h.cb); while (!tb_h.cb.instr_ready);
    // 2. Drive instruction for one clock
    tb_h.cb.instr <= inst;
    tb_h.cb.instr_valid <= 1'b1;
    @(tb_h.cb);
    // 3. De-assert
    tb_h.cb.instr_valid <= 1'b0;

    // 4. Sample coverage right after instruction is sent
    //    Flags will be updated on the WB state, so we sample again later
    cg_op.sample();
  endtask

  // --- **NEW**: Helper task to load a register with a specific value
  // Note: This assumes reg[0] is 0 (which it is at reset)
  // It uses `LOAD rd, [r0 + addr]`
  task automatic load_reg_via_mem(int reg_idx, logic [7:0] val, logic [7:0] addr);
    bit [15:0] load_instr;

    // 1. Set the memory value at the address we will read from
    mem[addr] = val;

    // 2. Create the LOAD instruction: opc=9, rd=reg_idx, rs=0, imm=addr
    //    We can use our class for this!
    if (!inst_item.randomize() with {
          opc == 4'h9;  // LOAD
          rd == reg_idx;
          rs == 0;  // Use reg[0] as base
          imm4 == addr;  // This is a 4-bit immediate, so we must use a low addr
                         // Let's modify this to use addr[3:0]
        }) begin
      $error("Failed to randomize LOAD helper");
      $finish;
    end
    load_instr = inst_item.get_instr();

    // 3. Drive the instruction
    $display("[%0t] Helper: Loading r%0d with %0d (from mem[%0h])", $time, reg_idx, val, addr);
    drive_instr(load_instr);

    // 4. Wait for the instruction to complete (IDLE->DEC->EXEC->MEM->WB)
    //    This is critical. We must wait for the writeback.
    repeat (5) @(tb_h.cb);
    cg_fl.sample();  // Sample flags after it has time to write back
  endtask


  // main test sequence (MODIFIED)
  task automatic run_tests();

    // =================================================================
    // ALL task-local variable declarations MUST be at the top.
    bit [15:0] inst;
    bit [15:0] halt_instr;
    // =================================================================

    // wait for external reset deassertion
    wait (tb_h.rst_n == 1);

    // initialize memory
    for (int i = 0; i < 256; i++) mem[i] = $urandom_range(0, 255);

    // spawn memory model
    fork
      mem_model();
    join_none

    // **NEW**: Construct the instruction item
    inst_item = new();

    // -----------------------------------------------------------------
    // 1. RANDOM PHASE
    // -----------------------------------------------------------------
    num_instructions = 500;
    $display("[%0t] Running %0d random instructions (HALT is constrained)...", $time,
             num_instructions);

    for (int i = 0; i < num_instructions; i++) begin

      // Randomize the class object
      if (!inst_item.randomize()) begin
        $error("Randomization failed!");
        $finish;
      end

      // This is now an assignment, not a declaration.
      inst = inst_item.get_instr();

      // **ADD THIS LINE TO PRINT THE INSTRUCTION**
      $display("[%0t] Driving instr #%0d: 0x%h (opcode: 0x%h)", $time, i, inst, inst_item.opc);

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

    // -----------------------------------------------------------------
    // 2. **NEW**: DIRECTED FLAG-COVERAGE PHASE
    // -----------------------------------------------------------------
    $display("[%0t] Random instructions complete. Running directed flag tests...", $time);

    // --- Test 1: Force Zero (Z) flag (XOR r1, r1)
    $display("[%0t] Flag Test: Forcing Zero flag (XOR r1, r1)", $time);
    load_reg_via_mem(1, 8'hAA, 4'h1);  // Load r1 with non-zero
    if (!inst_item.randomize() with {
          opc == 4'h5;
          rd == 1;
          rs == 1;
        })
      $finish;  // XOR r1, r1
    drive_instr(inst_item.get_instr());
    repeat (4) @(tb_h.cb);
    cg_fl.sample();  // Wait for WB

    // --- Test 2: Force Carry (C) flag (SUB 10 - 20)
    $display("[%0t] Flag Test: Forcing Carry/Borrow flag (SUB r1, r2)", $time);
    load_reg_via_mem(1, 10, 4'h2);  // r1 = 10
    load_reg_via_mem(2, 20, 4'h3);  // r2 = 20
    if (!inst_item.randomize() with {
          opc == 4'h2;
          rd == 1;
          rs == 2;
        })
      $finish;  // SUB r1, r2
    drive_instr(inst_item.get_instr());
    repeat (4) @(tb_h.cb);
    cg_fl.sample();  // Wait for WB. Result -10 (F6). N=1, C=1.

    // --- Test 3: Force Overflow (V) flag (ADD 100 + 100)
    $display("[%0t] Flag Test: Forcing Overflow flag (ADD r1, r2)", $time);
    load_reg_via_mem(1, 100, 4'h4);  // r1 = 100 (positive)
    load_reg_via_mem(2, 100, 4'h5);  // r2 = 100 (positive)
    if (!inst_item.randomize() with {
          opc == 4'h1;
          rd == 1;
          rs == 2;
        })
      $finish;  // ADD r1, r2
    drive_instr(inst_item.get_instr());
    repeat (4) @(tb_h.cb);
    cg_fl.sample();  // Wait for WB. Result 200 (C8). N=1, C=0. V=1.

    // --- Test 4: Force Negative (N) flag (ADD 100 + 20)
    $display("[%0t] Flag Test: Forcing Negative flag (ADD r1, r2)", $time);
    load_reg_via_mem(1, 100, 4'h6);  // r1 = 100
    load_reg_via_mem(2, 50, 4'h7);  // r2 = 50
    if (!inst_item.randomize() with {
          opc == 4'h1;
          rd == 1;
          rs == 2;
        })
      $finish;  // ADD r1, r2
    drive_instr(inst_item.get_instr());
    repeat (4) @(tb_h.cb);
    cg_fl.sample();  // Wait for WB. Result 150 (96). N=1. V=0. C=0.

    // -----------------------------------------------------------------
    // 3. DIRECTED HALT TEST (Original)
    // -----------------------------------------------------------------
    $display("[%0t] Directed flag tests complete. Sending directed HALT.", $time);

    // 1. Turn off the no_halt constraint
    inst_item.no_halt.constraint_mode(0);
    // 2. Randomize again, forcing opc to be HALT
    if (!inst_item.randomize() with {opc == 4'hF;}) begin
      $error("HALT instruction randomization failed!");
      $finish;
    end

    // Use assignment
    halt_instr = inst_item.get_instr();

    // 3. Drive the HALT instruction
    drive_instr(halt_instr);

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
