`timescale 1ns / 1ps

class instruction;
  rand bit [3:0] opc;
  rand bit [2:0] rd;
  rand bit [2:0] rs;
  rand bit [3:0] imm4;

  constraint no_halt {opc != 4'hF;}

  constraint opc_dist {
    opc dist {
      4'h0 := 5,
      4'h1 := 10,
      4'h2 := 10,
      4'h3 := 8,
      4'h4 := 8,
      4'h5 := 8,
      4'h6 := 10,
      4'h7 := 10,
      4'h8 := 10,
      4'h9 := 12,
      4'hA := 12,
      4'hB := 7,
      4'hC := 7
    };
  }

  constraint brz_smart {
    if (opc == 4'hB)
    rs dist {
      0 := 50,
      [1 : 7] := 50
    };
  }

  constraint addi_effective {
    if (opc == 4'h6)
    imm4 dist {
      0 := 1,
      [1 : 15] := 10
    };
  }

  constraint shift_effective {
    if (opc == 4'h7 || opc == 4'h8) {
      imm4 dist {
        [1 :  7] := 10,
        [8 : 15] := 2
      };
      rd inside {[1 : 7]};
    }
  }

  constraint store_effective {
    if (opc == 4'hA) {
      rd inside {[1 : 7]};
      rs inside {[0 : 7]};
    }
  }

  function bit [15:0] get_instr();
    return {opc, rd, 1'b0, rs, 1'b0, imm4};
  endfunction
endclass


program tb_prog_c (
    tb_if tb_h
);
  int unsigned num_instructions;
  logic [7:0] mem[0:255];
  instruction inst_item;
  logic mem_ready_ff;

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

  covergroup cg_flags;
    cp_flags: coverpoint tb_h.flags {bins all_flags[] = {[0 : 15]};}
  endgroup
  cg_flags cg_fl = new();

  task automatic mem_model();
    tb_h.cb.mem_ready <= 1'b0;
    tb_h.cb.mem_rdata <= 8'h00;
    mem_ready_ff <= 1'b0;

    forever begin
      @(tb_h.cb);
      tb_h.cb.mem_ready <= mem_ready_ff;
      mem_ready_ff <= 1'b0;

      if (tb_h.cb.mem_req) begin
        mem_ready_ff <= 1'b1;
        if (tb_h.cb.mem_we) begin
          mem[tb_h.cb.mem_addr] = tb_h.cb.mem_wdata;
          tb_h.cb.mem_rdata <= 8'h00;
        end else begin
          tb_h.cb.mem_rdata <= mem[tb_h.cb.mem_addr];
        end
      end else begin
        tb_h.cb.mem_rdata <= 8'h00;
      end
    end
  endtask

  task automatic drive_instr(bit [15:0] inst);
    do @(tb_h.cb); while (!tb_h.cb.instr_ready);
    tb_h.cb.instr <= inst;
    tb_h.cb.instr_valid <= 1'b1;
    @(tb_h.cb);
    tb_h.cb.instr_valid <= 1'b0;
    cg_op.sample();
  endtask

  task automatic send_directed_tests();
    bit [15:0] test_instr;

    $display("\n[%0t] === Directed Opcode Tests ===", $time);

    if (!inst_item.randomize() with {opc == 4'h0;}) $finish;
    drive_instr(inst_item.get_instr());
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    if (!inst_item.randomize() with {
          opc == 4'h6;
          rd == 1;
          imm4 == 10;
        })
      $finish;
    drive_instr(inst_item.get_instr());
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    if (!inst_item.randomize() with {
          opc == 4'h7;
          rd == 2;
          imm4 == 2;
        })
      $finish;
    drive_instr(inst_item.get_instr());
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    if (!inst_item.randomize() with {
          opc == 4'h8;
          rd == 3;
          imm4 == 2;
        })
      $finish;
    drive_instr(inst_item.get_instr());
    repeat (5) @(tb_h.cb);
    cg_fl.sample();

    if (!inst_item.randomize() with {
          opc == 4'hA;
          rd == 4;
          rs == 0;
          imm4 == 5;
        })
      $finish;
    drive_instr(inst_item.get_instr());
    do @(tb_h.cb); while (!tb_h.cb.instr_ready);
    @(tb_h.cb);
    cg_fl.sample();

    $display("[%0t] === Directed Tests Complete ===\n", $time);
  endtask

  task automatic run_tests();
    bit [15:0] inst, halt_instr;

    wait (tb_h.rst_n == 1);
    for (int i = 0; i < 256; i++) mem[i] = $urandom_range(0, 255);

    fork
      mem_model();
    join_none

    inst_item = new();
    repeat (3) @(tb_h.cb);

    send_directed_tests();

    num_instructions = 600;
    $display("[%0t] Running %0d random instructions...", $time, num_instructions);

    for (int i = 0; i < num_instructions; i++) begin
      if (!inst_item.randomize()) begin
        $error("Randomization failed!");
        $finish;
      end

      inst = inst_item.get_instr();

      if (i % 100 == 0) begin
        $display("[%0t] Progress: %0d/%0d (opc=0x%h)", $time, i, num_instructions, inst_item.opc);
      end

      do @(tb_h.cb); while (!tb_h.cb.instr_ready);
      tb_h.cb.instr <= inst;
      tb_h.cb.instr_valid <= 1'b1;
      @(tb_h.cb);
      tb_h.cb.instr_valid <= 1'b0;

      cg_op.sample();
      cg_fl.sample();
    end

    $display("[%0t] Random phase complete. Sending HALT...", $time);

    inst_item.no_halt.constraint_mode(0);
    if (!inst_item.randomize() with {opc == 4'hF;}) begin
      $error("HALT randomization failed!");
      $finish;
    end

    halt_instr = inst_item.get_instr();
    drive_instr(halt_instr);
    do @(tb_h.cb); while (!tb_h.cb.done);

    $display("[%0t] HALT observed.", $time);
    cg_op.sample();
    cg_fl.sample();

    $display("\n========================================");
    $display("COVERAGE SUMMARY");
    $display("========================================");
    $display("Opcode coverage: %0.2f%%", cg_op.get_coverage());
    $display("Flags coverage:  %0.2f%%", cg_fl.get_coverage());
    $display("========================================\n");

    repeat (10) @(tb_h.cb);
    $finish;
  endtask

  task start();
    tb_h.instr_valid = 0;
    tb_h.instr = 16'h0000;
    tb_h.mem_ready = 0;
    tb_h.mem_rdata = 8'h00;

    @(tb_h.cb);
    run_tests();
  endtask

  initial begin
    @(tb_h.cb);
    start();
  end
endprogram
