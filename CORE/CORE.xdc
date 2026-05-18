## VIC 20 for MEGA65 (VIC20MEGA65)
##
## MEGA65 port done by MJoergen in 2024 and licensed under GPL v3


create_generated_clock -name video_clk [get_pins CORE/clk_inst/i_clk_main/CLKOUT0]
create_generated_clock -name main_clk  [get_pins CORE/clk_inst/i_clk_main/CLKOUT1]
