# Run through scripts/run.py xsim after scripts/run.py project.
# Uses the existing project's parameters and requires a fresh testbench PASS.
if {[llength $argv] != 2} { error "Expected arguments: PROJECT_ROOT SEED" }
lassign $argv root seed
set root [file normalize $root]
if {![string is integer -strict $seed]} { error "SEED must be an integer" }
set project_file [file join $root build vivado apb_spi_master.xpr]
if {![file isfile $project_file]} { error "Missing Vivado project; run scripts/run.py project first" }
set output [file join $root build xsim]
file mkdir $output
set simulation_log [file join $root build vivado apb_spi_master.sim sim_1 behav xsim simulate.log]
set result_log [file join $output simulation.log]
# A previous passing run must never satisfy this invocation's success check.
file delete -force $simulation_log $result_log

open_project $project_file
set simset [get_filesets sim_1]
set saved_top [get_property top $simset]
set saved_runtime [get_property xsim.simulate.runtime $simset]
set saved_options [get_property xsim.simulate.xsim.more_options $simset]
set simulation_open 0
set failed [catch {
    set_property top tb_apb_spi_master $simset
    set_property xsim.simulate.runtime 0ns $simset
    set_property -dict [list xsim.simulate.xsim.more_options "-testplusarg SEED=$seed"] $simset
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    set simulation_open 1
    run all
} reason]
# Restore the GUI project's defaults, even after a compile or run failure.
if {$simulation_open && [catch {close_sim} close_error] && !$failed} {
    set failed 1
    set reason $close_error
}
set_property top $saved_top $simset
set_property xsim.simulate.runtime $saved_runtime $simset
set_property -dict [list xsim.simulate.xsim.more_options $saved_options] $simset
close_project
if {$failed} { error "Vivado behavioral simulation failed: $reason" }

if {![file isfile $simulation_log]} { error "XSim did not produce $simulation_log" }
file copy -force $simulation_log $result_log
set stream [open $simulation_log r]
set transcript [read $stream]
close $stream
if {[regexp -nocase -line {^[ \t]*(fatal|error):} $transcript]} {
    error "XSim reported an error/fatal; see $result_log"
}
if {![regexp -line {^PASS ALL checks=[0-9]+} $transcript]} {
    error "XSim did not reach the integration testbench's PASS ALL marker; see $result_log"
}
puts "PASS: Vivado behavioral simulation completed; transcript: $result_log"
puts "APB_SPI_TOOL_SUCCESS: xsim"
