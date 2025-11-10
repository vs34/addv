// top.sv
`timescale 1ns / 1ps

module top;
  // Clock generation in TOP
  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;  // 10 ns period

  // Reset
  logic rst_n;
  initial begin
    rst_n = 0;
    #20;
    rst_n = 1;
  end

  // instantiate the interface
  tb_if tb_if_i (
      .clk  (clk),
      .rst_n(rst_n)
  );

  // Instantiate CPU (simple_cpu.sv must be compiled alongside)
  simple_cpu uut (
      .clk        (tb_if_i.clk),
      .rst_n      (tb_if_i.rst_n),
      .instr_valid(tb_if_i.instr_valid),
      .instr      (tb_if_i.instr),
      .instr_ready(tb_if_i.instr_ready),
      .mem_rdata  (tb_if_i.mem_rdata),
      .mem_ready  (tb_if_i.mem_ready),
      .mem_req    (tb_if_i.mem_req),
      .mem_we     (tb_if_i.mem_we),
      .mem_addr   (tb_if_i.mem_addr),
      .mem_wdata  (tb_if_i.mem_wdata),
      .done       (tb_if_i.done),
      .flags      (tb_if_i.flags)
  );

  // construct and start program-based testbench (defined in tb_prog.sv)
  initial begin
    tb_prog p = new(tb_if_i);
    p.start();
  end
endmodule
