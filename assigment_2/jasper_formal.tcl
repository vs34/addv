# jasper_minimal.tcl
# Minimal JasperGold script with correct syntax

clear -all

# Load files
analyze -sv09 tb_if.sv
analyze -sv09 simple_cpu.sv
analyze -sv09 sva_assertions.sv

# Elaborate
elaborate -top simple_cpu

# Clock and reset
clock clk
reset -expression {!rst_n}

# Prove
prove -all

# Report
report > jasper_results.txt

# Show results
get_property_info -list

# Save
save_session jasper_session.tcl
