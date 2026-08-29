# Generic out-of-context constraint: 100 MHz APB/RTL clock.
# This checks internal PCLK paths only. It does NOT constrain APB input/output
# timing, SPI MISO/MOSI/SCLK timing, reset release, pin locations, or IO standards.
# Add board/peripheral-specific timing and pin constraints in the integrating
# design. SCLK is a registered output, not a clock for internal sequential logic.
create_clock -name pclk -period 10.000 [get_ports pclk]
# Representative 7-series global-buffer location for OOC delay/skew estimation.
# This is an integration assumption, NOT a board pin or the final PS clock route.
# Replace it with the real upstream BUFG location in an integrating design.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports pclk]
set_clock_uncertainty -setup 0.250 [get_clocks pclk]
