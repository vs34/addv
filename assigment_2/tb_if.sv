// tb_if.sv
`timescale 1ns / 1ps

interface tb_if (
    input logic clk,
    input logic rst_n
);
  // Instruction interface
  logic        instr_valid;
  logic [15:0] instr;
  logic        instr_ready;

  // Memory interface
  logic [ 7:0] mem_rdata;
  logic        mem_ready;
  logic        mem_req;
  logic        mem_we;
  logic [ 7:0] mem_addr;
  logic [ 7:0] mem_wdata;

  // status
  logic        done;
  logic [ 3:0] flags;  // {Z, N, C, V}

  // Clocking block for synchronous interactions on posedge clk
  clocking cb @(posedge clk);
    input rst_n;

    // TB drives these to CPU
    output instr_valid;
    output instr;

    // CPU drives these to TB
    input instr_ready;

    // CPU-driven memory signals (TB samples these)
    input mem_req;
    input mem_we;
    input mem_addr;
    input mem_wdata;

    // TB responses to CPU
    output mem_rdata;
    output mem_ready;

    // CPU status
    input done;
    input flags;
  endclocking

  // optional modports
  modport tb_mp(clocking cb);
  modport cpu_mp(clocking cb);
endinterface
