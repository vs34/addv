// top.sv
`timescale 1ns / 1ps
module TOP;  // note: your earlier command used -top TOP
  // clock
  logic clk = 0;
  always #5 clk = ~clk;
  // reset
  logic rst_n;
  initial begin
    rst_n = 0;
    #20 rst_n = 1;
  end

  // instantiate interface
  tb_if tb_if_i (
      .clk  (clk),
      .rst_n(rst_n)
  );

  // instantiate CPU (simple_cpu.v)
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

  // instantiate the program and connect interface to its port
  // tb_prog tb_prog_inst (tb_if_i);
  tb_prog_c tb_prog_inst (tb_if_i);
endmodule
