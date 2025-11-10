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

  // ====================================================================
  // FIX: Improved opcode distribution to ensure ALL opcodes are covered
  // ====================================================================
  constraint opc_dist {
    opc dist {
      4'h0 := 5,  // NOP - explicit weight
      4'h1 := 10,  // ADD
      4'h2 := 10,  // SUB
      4'h3 := 8,  // AND
      4'h4 := 8,  // OR
      4'h5 := 8,  // XOR
      4'h6 := 10,  // ADDI - increased weight
      4'h7 := 10,  // SHL - increased weight
      4'h8 := 10,  // SHR - increased weight
      4'h9 := 12,  // LOAD
      4'hA := 12,  // STORE - separated from LOAD with equal weight
      4'hB := 7,  // BRZ
      4'hC := 7  // JMP
    };
  }

  // Constraint 2: "Smart" constraint for BRZ (0xB)
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

  // ====================================================================
  // FIX: Add constraint to make ADDI more effective with non-zero immediates
  // ====================================================================
  constraint addi_effective {
    if (opc == 4'h6) {  // ADDI
      imm4 dist {
        0        := 1,  // Rarely use 0
        [1 : 15] := 10  // Prefer non-zero values
      };
    }
  }

  // ====================================================================
  // FIX: Add constraint to make shifts more visible
  // ====================================================================
  constraint shift_effective {
    if (opc == 4'h7 || opc == 4'h8) {  // SHL or SHR
      imm4 dist {
        [1 :  7] := 10,  // Prefer reasonable shift amounts
        [8 : 15] := 2  // Large shifts less common
      };
      // Use non-zero registers
      rd inside {[1 : 7]};
    }
  }

  // ====================================================================
  // FIX: Add constraint for STORE to use non-zero registers
  // ====================================================================
  constraint store_effective {
    if (opc == 4'hA) {  // STORE
      rd inside {[1 : 7]};  // Don't store from r0 (always zero)
      rs inside {[0 : 7]};  // Any base register is fine
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

  // =================================================================
  // *** CRITICAL FIX: Improved load_reg_via_mem with better timing
  // =================================================================
  task automatic load_reg_via_mem(int reg_idx, logic [7:0] val, logic [7:0] addr);
    bit [15:0] load_instr;
    int timeout;

    // 1. Set the memory value at the address we will read from
    mem[addr]  = val;

    // 2. Build LOAD instruction manually (don't use randomize in helper)
    //    Format: LOAD rd, [rs + imm]
    //    We want: LOAD reg_idx, [r0 + addr[3:0]]
    load_instr = {4'h9, reg_idx[2:0], 1'b0, 3'b000, 1'b0, addr[3:0]};

    // 3. Drive the instruction and wait for completion
    $display("[%0t] Helper: Loading r%0d with 0x%h (from mem[0x%h])", $time, reg_idx, val, addr);

    // Wait for CPU ready
    timeout = 0;
    do begin
      @(tb_h.cb);
      timeout++;
      if (timeout > 100) begin
        $error("[%0t] TIMEOUT waiting for instr_ready in load_reg_via_mem", $time);
        $finish;
      end
    end while (!tb_h.cb.instr_ready);

    // Drive instruction
    tb_h.cb.instr <= load_instr;
    tb_h.cb.instr_valid <= 1'b1;
    @(tb_h.cb);
    tb_h.cb.instr_valid <= 1'b0;

    // Sample opcode coverage
    cg_op.sample();

    // 4. Wait for the LOAD to complete
    //    LOAD sequence: IDLE->DECODE->EXEC->MEM->IDLE
    //    We need to wait for the CPU to return to IDLE (instr_ready=1)
    timeout = 0;
    do begin
      @(tb_h.cb);
      timeout++;
      if (timeout > 100) begin
        $error("[%0t] TIMEOUT waiting for LOAD completion in load_reg_via_mem", $time);
        $display("[%0t]   mem_req=%b, mem_ready=%b, mem_addr=0x%h", $time, tb_h.cb.mem_req,
                 tb_h.cb.mem_ready, tb_h.cb.mem_addr);
        $finish;
      end
    end while (!tb_h.cb.instr_ready);

    // Give one more cycle for register write to settle
    @(tb_h.cb);

    // Sample flags
    cg_fl.sample();

    $display("[%0t] Helper: Load complete, r%0d should now be 0x%h", $time, reg_idx, val);
  endtask


  // ====================================================================
  // NEW: Helper task to specifically test missing opcodes
  // ====================================================================
  task automatic test_missing_opcodes();
    bit [15:0] test_instr;

    $display("[%0t] ========================================", $time);
    $display("[%0t] DIRECTED TEST: Missing Opcode Coverage", $time);
    $display("[%0t] ========================================", $time);

    // Test 1: NOP (0x0)
    $display("[%0t] Testing NOP (opcode 0x0)", $time);
    if (!inst_item.randomize() with {opc == 4'h0;}) $finish;
    drive_instr(inst_item.get_instr());
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    // Test 2: ADDI (0x6) - Load a value then add immediate
    $display("[%0t] Testing ADDI (opcode 0x6)", $time);
    load_reg_via_mem(1, 50, 4'h1);  // r1 = 50
    if (!inst_item.randomize() with {
          opc == 4'h6;  // ADDI
          rd == 1;  // r1 = r1 + imm
          imm4 == 10;  // Add 10
        })
      $finish;
    test_instr = inst_item.get_instr();
    $display("[%0t]   Instruction: r1 = r1 + 10 (r1 was 50, should become 60)", $time);
    drive_instr(test_instr);
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    // Test 3: SHL (0x7) - Shift left
    $display("[%0t] Testing SHL (opcode 0x7)", $time);
    load_reg_via_mem(2, 8'b00000011, 4'h2);  // r2 = 3
    if (!inst_item.randomize() with {
          opc == 4'h7;  // SHL
          rd == 2;  // r2 = r2 << imm
          imm4 == 2;  // Shift left by 2
        })
      $finish;
    test_instr = inst_item.get_instr();
    $display("[%0t]   Instruction: r2 = r2 << 2 (r2 was 3, should become 12)", $time);
    drive_instr(test_instr);
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    // Test 4: SHR (0x8) - Shift right (extra test to ensure it's covered)
    $display("[%0t] Testing SHR (opcode 0x8)", $time);
    load_reg_via_mem(3, 8'b11000000, 4'h3);  // r3 = 192
    if (!inst_item.randomize() with {
          opc == 4'h8;  // SHR
          rd == 3;  // r3 = r3 >> imm
          imm4 == 2;  // Shift right by 2
        })
      $finish;
    test_instr = inst_item.get_instr();
    $display("[%0t]   Instruction: r3 = r3 >> 2 (r3 was 192, should become 48)", $time);
    drive_instr(test_instr);
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    // Test 5: STORE (0xA) - Store to memory
    $display("[%0t] Testing STORE (opcode 0xA)", $time);
    load_reg_via_mem(4, 8'hAB, 4'h4);  // r4 = 0xAB
    if (!inst_item.randomize() with {
          opc == 4'hA;  // STORE
          rd == 4;  // Store r4
          rs == 0;  // Base = r0 (0)
          imm4 == 5;  // Offset = 5
        })
      $finish;
    test_instr = inst_item.get_instr();
    $display("[%0t]   Instruction: MEM[r0 + 5] = r4 (storing 0xAB to mem[5])", $time);
    drive_instr(test_instr);

    // Wait for STORE to complete (need to wait for IDLE state)
    do @(tb_h.cb); while (!tb_h.cb.instr_ready);
    @(tb_h.cb);

    cg_fl.sample();

    // Verify store worked
    if (mem[5] == 8'hAB) begin
      $display("[%0t]   STORE verification: PASS (mem[5] = 0x%h)", $time, mem[5]);
    end else begin
      $display("[%0t]   STORE verification: FAIL (mem[5] = 0x%h, expected 0xAB)", $time, mem[5]);
    end

    $display("[%0t] ========================================", $time);
    $display("[%0t] Directed opcode tests complete", $time);
    $display("[%0t] ========================================", $time);
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

    // Wait a few cycles for memory model to initialize
    repeat (3) @(tb_h.cb);

    // -----------------------------------------------------------------
    // 0. DIRECTED TEST FOR MISSING OPCODES (RUN FIRST!)
    // -----------------------------------------------------------------
    test_missing_opcodes();

    // -----------------------------------------------------------------
    // 1. RANDOM PHASE (INCREASED COUNT FOR BETTER COVERAGE)
    // -----------------------------------------------------------------
    num_instructions = 800;  // Increased from 500
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

      // Print every 100th instruction to reduce log spam
      if (i % 100 == 0) begin
        $display("[%0t] Progress: %0d/%0d instructions (opcode: 0x%h)", $time, i, num_instructions,
                 inst_item.opc);
      end

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
    // 2. DIRECTED FLAG-COVERAGE PHASE
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

    // -----------------------------------------------------------------
    // 4. PRINT COVERAGE SUMMARY
    // -----------------------------------------------------------------
    $display("[%0t] ========================================", $time);
    $display("[%0t] COVERAGE SUMMARY", $time);
    $display("[%0t] ========================================", $time);
    $display("[%0t] Opcode coverage: %0.2f%%", $time, cg_op.get_coverage());
    $display("[%0t] Flags coverage:  %0.2f%%", $time, cg_fl.get_coverage());
    $display("[%0t] ========================================", $time);

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
