#!/bin/bash
# Minimal script to compile and run simple_cpu simulation with VCS

# Clean previous build
rm -rf simv csrc simv.daidir ucli.key *.log *.vpd

cat run.bash

# Compile
vcs -full64 -licqueue \
    -timescale=1ns/1ns \
    +vcs+flush+all \
    +warn=all \
    -sverilog \
    tb_if.sv simple_cpu.v tb_prog.sv top.sv \
    -o simv

# Run
./simv +vcs+lic+wait

