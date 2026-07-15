----------------------------------------------------------------------------------
-- MSX1 for MEGA65
--
-- Wrapper for the MiSTer core that runs exclusively in the core's clock domanin
--
-- based on M2M by MJoergen and sy2002
-- based on MSX1_MiSTer by the MiSTer development team
-- port done by Paolo Pisati <p.pisati@gmail.com> in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity main is
   generic (
      G_VDNUM : natural -- amount of virtual drives
   );
   port (
      clk_main_i             : in    std_logic;
      ce_10m7_i              : in    std_logic;
      ce_5m3_i               : in    std_logic;

      -- A pulse of reset_soft_i needs to be 32 clock cycles long at a minimum
      reset_soft_i           : in    std_logic;
      reset_hard_i           : in    std_logic;

      -- Pull high to pause the core
      pause_i                : in    std_logic;

      -- Trigger the sequence RUN<Return> to autostart PRG files
      trigger_run_i          : in    std_logic;

      ---------------------------
      -- Configuration options
      ---------------------------

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i       : in    natural;
      video_retro15khz_i     : in    std_logic;

      ---------------------------
      -- C16 I/O ports
      ---------------------------

      -- M2M Keyboard interface
      kb_key_num_i           : in    integer range 0 to 79; -- cycles through all MEGA65 keys
      kb_key_pressed_n_i     : in    std_logic;             -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- MEGA65 joysticks and paddles
      joy_1_up_n_i           : in    std_logic;
      joy_1_down_n_i         : in    std_logic;
      joy_1_left_n_i         : in    std_logic;
      joy_1_right_n_i        : in    std_logic;
      joy_1_fire_n_i         : in    std_logic;
      joy_1_up_n_o           : out   std_logic;
      joy_1_down_n_o         : out   std_logic;
      joy_1_left_n_o         : out   std_logic;
      joy_1_right_n_o        : out   std_logic;
      joy_1_fire_n_o         : out   std_logic;
      joy_2_up_n_i           : in    std_logic;
      joy_2_down_n_i         : in    std_logic;
      joy_2_left_n_i         : in    std_logic;
      joy_2_right_n_i        : in    std_logic;
      joy_2_fire_n_i         : in    std_logic;
      joy_2_up_n_o           : out   std_logic;
      joy_2_down_n_o         : out   std_logic;
      joy_2_left_n_o         : out   std_logic;
      joy_2_right_n_o        : out   std_logic;
      joy_2_fire_n_o         : out   std_logic;
      pot1_x_i               : in    std_logic_vector(7 downto 0);
      pot1_y_i               : in    std_logic_vector(7 downto 0);
      pot2_x_i               : in    std_logic_vector(7 downto 0);
      pot2_y_i               : in    std_logic_vector(7 downto 0);

      -- Video output
      video_ce_o             : out   std_logic;
      video_ce_ovl_o         : out   std_logic;
      video_red_o            : out   std_logic_vector(7 downto 0);
      video_green_o          : out   std_logic_vector(7 downto 0);
      video_blue_o           : out   std_logic_vector(7 downto 0);
      video_vs_o             : out   std_logic;
      video_hs_o             : out   std_logic;
      video_hblank_o         : out   std_logic;
      video_vblank_o         : out   std_logic;

      -- Audio output (Signed PCM)
      audio_left_o           : out   signed(15 downto 0);
      audio_right_o          : out   signed(15 downto 0);

      -- C16 drive led (color is RGB)
      drive_led_o            : out   std_logic;
      drive_led_col_o        : out   std_logic_vector(23 downto 0);

      -- Access to main memory
      conf_clk_i             : in    std_logic;
      conf_ai_i              : in    std_logic_vector(15 downto 0);
      conf_di_i              : in    std_logic_vector(7 downto 0);
      conf_wr_i              : in    std_logic;

      -- IEC handled by QNICE
      iec_clk_sd_i           : in    std_logic;             -- QNICE "sd card write clock" for floppy drive internal dual clock RAM buffer
      iec_qnice_addr_i       : in    std_logic_vector(27 downto 0);
      iec_qnice_data_i       : in    std_logic_vector(15 downto 0);
      iec_qnice_data_o       : out   std_logic_vector(15 downto 0);
      iec_qnice_ce_i         : in    std_logic;
      iec_qnice_we_i         : in    std_logic;

      -- CBM-488/IEC serial (hardware) port
      iec_hardware_port_en_i : in    std_logic;
      iec_reset_n_o          : out   std_logic;
      iec_atn_n_o            : out   std_logic;
      iec_clk_en_o           : out   std_logic;
      iec_clk_n_i            : in    std_logic;
      iec_clk_n_o            : out   std_logic;
      iec_data_en_o          : out   std_logic;
      iec_data_n_i           : in    std_logic;
      iec_data_n_o           : out   std_logic;
      iec_srq_en_o           : out   std_logic;
      iec_srq_n_i            : in    std_logic;
      iec_srq_n_o            : out   std_logic
   );
end entity main;

architecture synthesis of main is

   -- Generic MiSTer C16 signals
   signal   drive_led : std_logic;

   signal   o_audio : std_logic_vector(15 downto 0);

   -- unprocessed video output of the C16 core
   signal   vga_hs    : std_logic;
   signal   vga_vs    : std_logic;
   signal   div       : unsigned(1 downto 0);
   signal   div_ovl   : unsigned(0 downto 0);

   -- clock enable to derive the C16's pixel clock from the core's main clock
   signal   video_ce   : std_logic;
   signal   video_ce_d : std_logic;

   signal   reset_core_n : std_logic   := '1';
   signal   hard_reset_n : std_logic   := '1';
   signal   cache_dirty  : std_logic_vector(G_VDNUM - 1 downto 0);
   signal   prevent_reset    : std_logic;

   constant C_HARD_RST_DELAY : natural := 100_000; -- roundabout 1/30 of a second
   signal   hard_rst_counter : natural := 0;

   signal joy0, joy1 : std_logic_vector(5 downto 0);

   -- MSX1 ROM cart space
   signal sdram_addr : std_logic_vector(24 downto 0);
   signal cart_addr : std_logic_vector(18 downto 0);
   signal cart_dout : std_logic_vector(7 downto 0);
   signal cart_din : std_logic_vector(7 downto 0);
   signal cart_we : std_logic;
   signal cart_cs : std_logic;
begin

   -- prevent data corruption by not allowing a soft reset to happen while the cache is still dirty
   -- since we can have more than one cache that might be dirty, we convert the std_logic_vector of length G_VDNUM
   -- into an unsigned and check for zero
   prevent_reset   <= '0' when unsigned(cache_dirty) = 0 else
                      '1';

   -- the color of the drive led is green normally, but it turns yellow
   -- when the cache is dirty and/or currently being flushed
   --drive_led_col_o <= x"00FF00" when unsigned(cache_dirty) = 0 else
   --                   x"FFFF00";

   -- the drive led is on if either the C64 is writing to the virtual disk (cached in RAM)
   -- or if the dirty cache is dirty and/orcurrently being flushed to the SD card
   --drive_led_o     <= drive_led when unsigned(cache_dirty) = 0 else
   --                   '1';

   --------------------------------------------------------------------------------------------------
   -- Hard reset
   --------------------------------------------------------------------------------------------------

   hard_reset_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset_soft_i = '1' or reset_hard_i = '1' then
            -- Due to sw_cartridge_wrapper's logic, reset_soft_i stays high longer than reset_hard_i.
            -- We need to make sure that this is not interfering with hard_reset_n
            if reset_hard_i = '1' then
               hard_rst_counter <= C_HARD_RST_DELAY;
               hard_reset_n     <= '0';
            end if;

            -- reset_core_n is low-active, so prevent_reset = 0 means execute reset
            -- but a hard reset can override
            reset_core_n <= prevent_reset and (not reset_hard_i);
         else
            -- The idea of the hard reset is, that while reset_core_n is back at '1' and therefore the core is
            -- running (not being reset any more), hard_reset_n stays low for C_HARD_RST_DELAY clock cycles.
            -- Reason: We need to give the KERNAL time to execute the routine $FD02 where it checks for the
            -- cartridge signature "CBM80" in $8003 onwards. In case reset_n = '0' during these tests (i.e. hard
            -- reset active) we will return zero instead of "CBM80" and therefore perform a hard reset.
            reset_core_n <= '1';
            if hard_rst_counter = 0 then
               hard_reset_n <= '1';
            else
               hard_rst_counter <= hard_rst_counter - 1;
            end if;
         end if;
      end if;
   end process hard_reset_proc;

   --------------------------------------------------------------------------------------------------
   -- MiSTer C16 core / main machine
   --------------------------------------------------------------------------------------------------

   joy0 <= not(joy_1_fire_n_i & joy_1_up_n_i & joy_1_down_n_i & joy_1_left_n_i & joy_1_right_n_i & '0');
   joy1 <= not(joy_2_fire_n_i & joy_2_up_n_i & joy_2_down_n_i & joy_2_left_n_i & joy_2_right_n_i & '0');

   -- split cart space in two 256Kb halves:
   -- bit 18 = the slot-select bit (addr[22], the 3'b001 vs 3'b000 from the slots.sv mux),
   -- bits 17:0 = the 256 KB offset within the slot.
   cart_addr <= sdram_addr(22) & sdram_addr(17 downto 0);

   cart : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 19,
         DATA_WIDTH        => 8
      ) port map (
         clock_a           => clk_main_i,
         address_a         => cart_addr,
         data_a            => cart_din,
         q_a               => cart_dout,
         wren_a            => cart_we,
         cs_a              => cart_cs
      );

   MSX1 : entity work.msx1
      port map (
         clk                    => clk_main_i,
         ce_10m7                => ce_10m7_i,
         reset                  => reset_soft_i or reset_hard_i,

         -- VGA/SCART interface
         border                 => '1',
         R                      => video_red_o,
         G                      => video_green_o,
         B                      => video_blue_o,
         hsync_n                => vga_hs,
         vsync_n                => vga_vs,
         hblank                 => video_hblank_o,
         vblank                 => video_vblank_o,
         vdp_pal                => '0',

         audio                  => o_audio,

         kb_scancode            => std_logic_vector(to_unsigned(kb_key_num_i, 7)),
         kb_release             => kb_key_pressed_n_i,
         joy0                   => joy0,
         joy1                   => joy1,

         ioctl_download         => '0',
         ioctl_index            => (others => '0'),
         ioctl_wr               => (others => '0'),
         ioctl_addr             => (others => '0'),
         ioctl_dout             => (others => '0'),
         ioctl_isROMA           => '0',
         ioctl_isROMB           => '0',
         ioctl_isBIOS           => '0',
         ioctl_isFWBIOS         => '0',
         ioctl_wait             => open,
         rom_enabled            => (others => '0'),

         -- tape
         cas_motor              => open,
         cas_audio_in           => '0',

         slot_A                 => (others => '0'),
         slot_B                 => (others => '0'),
         mapper_info            => open,

         -- SDRAM
         sdram_dout             => cart_dout,
         sdram_din              => cart_din,
         sdram_addr             => sdram_addr,
         sdram_we               => cart_we,
         sdram_rd               => cart_cs,
         sdram_ready            => '1',

         img_mounted            => '0',
         img_size               => (others => '0'),
         img_wp                 => '0',
         sd_lba                 => open,
         sd_rd                  => open,
         sd_wr                  => open,
         sd_ack                 => '0',
         sd_buff_addr           => (others => '0'),
         sd_buff_dout           => (others => '0'),
         sd_buff_din            => open,
         sd_buff_wr             => '0',
         sd_din_strobe          => '0'

         -- memory and bus / decode logic
--         rnw                    => c16_rnw,
--         addr                   => c16_addr,
--         dout                   => c16_dout,
--         din                    => c16_din,
--         cs_ram                 => cs_ram,
--         cs0                    => cs0,
--         cs1                    => cs1,
--         cs_io                  => cs_io,

         -- joystick
         -- keyboard
--         kb_key_num_i           => kb_key_num_i,
--         kb_key_pressed_n_i     => kb_key_pressed_n_i,
--         key_play               => open,

         -- IEC
--         iec_dataout            => c16_iec_data_out,
--         iec_datain             => c16_iec_data_in and hw_iec_data_n_in,
--         iec_clkout             => c16_iec_clk_out,
--         iec_clkin              => c16_iec_clk_in and hw_iec_clk_n_in,
--         iec_atnout             => c16_iec_atn_out,
--         iec_reset              => open,

         -- TED audio and SID selector
--         sound                  => o_audio,
--         sid_type               => sid_type_i,

         -- video mode?
--         pal                    => open
      );

   --------------------------------------------------------------------------------------------------
   -- Generate video output for the M2M framework
   --------------------------------------------------------------------------------------------------

   video_ce        <= ce_5m3_i;
   video_ce_o      <= video_ce and not video_ce_d;
   video_ce_ovl_o  <= '1' when video_retro15khz_i = '0' else
                      not div_ovl(0);

   process(clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if video_hs_o = '0' and vga_hs = '0' then
            video_vs_o <= not vga_vs;
         end if;
         video_hs_o <= not vga_hs;
      end if;
   end process;

   video_ce_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         video_ce_d <= video_ce;
         div_ovl    <= div_ovl + 1;
      end if;
   end process video_ce_proc;

   --------------------------------------------------------------------------------------------------
   -- MiSTer audio signal processing: Convert the core's 6-bit signal to a signed 16-bit signal
   --------------------------------------------------------------------------------------------------

   audio_left_o    <= signed(o_audio);
   audio_right_o   <= signed(o_audio);

end architecture synthesis;
