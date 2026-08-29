# Shared SystemVerilog source collection and parameter validation.
proc collect_hdl {directory} {
    set result [list]
    foreach path [lsort [glob -nocomplain -directory $directory *]] {
        if {[file isdirectory $path]} {
            set result [concat $result [collect_hdl $path]]
        } elseif {[string tolower [file extension $path]] eq {.v}} {
            error "This project uses SystemVerilog .sv sources only; convert or remove legacy source: $path"
        } elseif {[string tolower [file extension $path]] eq {.sv}} {
            lappend result [file normalize $path]
        }
    }
    return $result
}

proc parse_settings {arguments extra_args} {
    if {[llength $arguments] != 4 + $extra_args} {
        error "Expected arguments: PROJECT_ROOT PART FIFO_DEPTH NUM_CS [expr {$extra_args ? {IMPLEMENT} : {}}]"
    }
    lassign $arguments root part depth count
    if {![string is integer -strict $depth] || $depth < 2 || $depth > 32768 || ($depth & ($depth - 1)) != 0} {
        error "FIFO_DEPTH must be a power of two in 2..32768"
    }
    if {![string is integer -strict $count] || $count < 1 || $count > 4} {
        error "NUM_CS must be in 1..4"
    }
    set root [file normalize $root]
    set rtl [collect_hdl [file join $root rtl]]
    set tb [collect_hdl [file join $root tb]]
    if {[llength $rtl] == 0 || [llength $tb] == 0} {
        error "SystemVerilog .sv RTL or testbench sources are missing under $root"
    }
    return [dict create root $root part $part depth $depth count $count rtl $rtl tb $tb]
}
