## VIC 20 for MEGA65 (VIC20MEGA65)
##
## MEGA65 port done by MJoergen in 2024 and licensed under GPL v3


create_generated_clock -name video_clk [get_pins CORE/clk_inst/i_clk_main/CLKOUT0]
create_generated_clock -name main_clk  [get_pins CORE/clk_inst/i_clk_main/CLKOUT1]

## crtrom_loader CDC (qnice_clk <-> main_clk): toggle handshake; the payload
## (stream_addr/stream_data) is quasi-static while req != ack because the
## QNICE CPU is frozen via qnice_wait_o. See CORE/vhdl/crtrom_loader.vhd.
## NB: a plain "get_pins -hierarchical <glob>" cannot match a pattern that
## contains a hierarchy separator, so the instance-scoped patterns below
## must use the -filter form.
set_max_delay 8 -datapath_only -from [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/stream_addr_reg[*]/C}]  -to [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/main_ioctl_addr_o_reg[*]/D}]
set_max_delay 8 -datapath_only -from [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/stream_data_reg[*]/C}]  -to [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/main_ioctl_data_o_reg[*]/D}]
set_max_delay 8 -datapath_only -from [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/req_toggle_reg/C}]      -to [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/req_toggle_m_reg/D}]
set_max_delay 8 -datapath_only -from [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/ack_toggle_reg/C}]      -to [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/ack_toggle_m_reg/D}]
set_max_delay 8 -datapath_only -from [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/stream_active_reg/C}]   -to [get_pins -hierarchical -filter {NAME =~ *crtrom_loader_*_inst/isrom_m_reg/D}]
