# Run through scripts/run.py synth [--implement]. No package pins or bitstream.
source [file join [file dirname [info script]] common.tcl]
set settings [parse_settings $argv 1]
dict with settings {}
set implement [lindex $argv 4]
if {$implement ni {0 1}} { error "IMPLEMENT must be 0 or 1" }
set output [file join $root build synth]
file mkdir $output

create_project -in_memory -part $part
# This property selects generated-netlist language, not the RTL parser.
# Vivado accepts Verilog/VHDL here; read_verilog -sv selects SystemVerilog.
set_property target_language Verilog [current_project]
read_verilog -sv $rtl
read_xdc [file join $root constraints generic_ooc.xdc]
synth_design -top apb_spi_master -part $part -mode out_of_context \
    -generic [list FIFO_DEPTH=$depth NUM_CS=$count]
write_checkpoint -force [file join $output post_synth.dcp]
report_utilization -file [file join $output utilization_synth.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $output timing_synth.rpt]
report_drc -file [file join $output drc_synth.rpt]

if {$implement} {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $output post_route.dcp]
    report_utilization -file [file join $output utilization_route.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -file [file join $output timing_route.rpt]
    report_route_status -file [file join $output route_status.rpt]
    report_drc -file [file join $output drc_route.rpt]
    # Only paths covered by the generic PCLK constraint are checked here.
    # APB and SPI board-level IO timing remains the integrator's responsibility.
    foreach delay_type {max min} {
        set worst [get_timing_paths -delay_type $delay_type -max_paths 1 -quiet]
        if {[llength $worst] == 0} { error "No constrained $delay_type timing paths found" }
        set slack [get_property SLACK [lindex $worst 0]]
        puts "Internal $delay_type timing slack: $slack ns"
        if {$slack < 0.0} { error "Internal $delay_type timing failed: $slack ns" }
    }
}
puts "Reports saved to $output"
puts "Generic OOC result: only internal PCLK timing is constrained; no board IO timing or bitstream."
puts "APB_SPI_TOOL_SUCCESS: synth"
