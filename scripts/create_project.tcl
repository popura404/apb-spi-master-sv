# Create a GUI project; generated project files are disposable build products.
source [file join [file dirname [info script]] common.tcl]
set settings [parse_settings $argv 0]
dict with settings {}
set output [file join $root build vivado]
file mkdir $output

create_project -force apb_spi_master $output -part $part
# Vivado's generated-netlist language property accepts Verilog/VHDL; source
# parsing is set separately and explicitly to SystemVerilog below.
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
add_files -norecurse $rtl
add_files -fileset sim_1 -norecurse $tb
set_property file_type SystemVerilog [get_files [concat $rtl $tb]]
add_files -fileset constrs_1 -norecurse [file join $root constraints generic_ooc.xdc]
set_property top apb_spi_master [get_filesets sources_1]
set_property generic [list FIFO_DEPTH=$depth NUM_CS=$count] [get_filesets sources_1]
set_property top tb_apb_spi_master [get_filesets sim_1]
set_property generic [list FIFO_DEPTH=$depth NUM_CS=$count] [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
set_property -dict [list {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} {-mode out_of_context}] [get_runs synth_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Vivado project: [file join $output apb_spi_master.xpr]"
puts "This project is generic OOC IP; configure board pins and external timing before hardware use."
close_project
puts "APB_SPI_TOOL_SUCCESS: project"
