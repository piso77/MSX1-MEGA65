----------------------------------------------------------------------------------
-- MSX1 for MEGA65
--
-- QNICE streaming device that replays a CRT/ROM file download as a
-- MiSTer-faithful ioctl byte stream into the core clock domain.
--
-- The M2M Shell handles the file browser, SD card access and the CSR
-- protocol (see qnice_csr.vhd). This module is a passive slave on the
-- QNICE bus: it latches each streamed byte, stalls the QNICE CPU via
-- qnice_wait_o, and hands the byte across the clock domain boundary
-- with a toggle/ack 4-phase handshake. On the core side it reconstructs
-- the exact ioctl waveform the MiSTer HPS would have produced:
--
--   * main_ioctl_isrom_o : level, high for the whole download
--   * main_ioctl_wr_o    : one main_clk cycle strobe per byte
--   * main_ioctl_addr_o  : linear byte offset within the file
--   * main_ioctl_data_o  : the byte
--
-- so that rom_detect.v (mapper auto-detection, rom_size, offset
-- heuristics) and the cart_rom download path work unmodified.
--
-- Faithful to MSX1.sv upstream behaviour:
--   * the core is held in reset for the entire download
--     (MSX1.sv: reset = ... | ioctl_isROMA | ioctl_isROMB)
--   * rom_enabled is set sticky at download start and survives
--     soft resets (MSX1.sv lines 309..324)
--
-- One instance per cartridge slot; see mega65.vhd.
--
-- done by Paolo Pisati <p.pisati@gmail.com> in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

library work;
   use work.qnice_csr_pkg.all;

entity crtrom_loader is
   generic (
      G_ROM_MAX : natural := 256 * 1024                    -- capacity of the backing BRAM slice, in bytes
   );
   port (
      -- QNICE clock domain
      qnice_clk_i         : in  std_logic;
      qnice_rst_i         : in  std_logic;
      qnice_addr_i        : in  std_logic_vector(27 downto 0);
      qnice_data_i        : in  std_logic_vector(15 downto 0);
      qnice_ce_i          : in  std_logic;                 -- asserted by the device mux in mega65.vhd
      qnice_we_i          : in  std_logic;
      qnice_data_o        : out std_logic_vector(15 downto 0);
      qnice_wait_o        : out std_logic;

      -- Core clock domain
      main_clk_i          : in  std_logic;
      main_rst_i          : in  std_logic;                 -- hard reset: clears rom_enabled
      main_ioctl_isrom_o  : out std_logic;                 -- level: download in progress
      main_ioctl_wr_o     : out std_logic;                 -- 1-cycle byte strobe
      main_ioctl_addr_o   : out std_logic_vector(24 downto 0);
      main_ioctl_data_o   : out std_logic_vector(7 downto 0);
      main_ioctl_wait_i   : in  std_logic;                 -- backpressure from the core (slots.sv)
      main_core_reset_o   : out std_logic;                 -- OR into the core's reset
      main_rom_enabled_o  : out std_logic                  -- sticky: a ROM lives in this slot
   );
end entity crtrom_loader;

architecture beh of crtrom_loader is

   ---------------------------------------------------------------------------
   -- QNICE clock domain
   ---------------------------------------------------------------------------

   -- CSR plumbing
   signal qnice_req_status  : std_logic_vector(3 downto 0);
   signal qnice_req_length  : std_logic_vector(22 downto 0);
   signal qnice_csr_data    : std_logic_vector(15 downto 0);
   signal qnice_csr_wait    : std_logic;
   signal qnice_csr         : std_logic;

   signal qnice_resp_status : std_logic_vector(3 downto 0) := C_CSR_RESP_IDLE;
   signal qnice_resp_error  : std_logic_vector(3 downto 0) := (others => '0');
   signal qnice_resp_addr   : std_logic_vector(22 downto 0) := (others => '0');

   -- byte handshake, QNICE side
   type   stream_state_type is (IDLE_ST, BUSY_ST);
   signal stream_state      : stream_state_type := IDLE_ST;
   signal stream_data       : std_logic_vector(7 downto 0);
   signal stream_addr       : std_logic_vector(24 downto 0);
   signal req_toggle        : std_logic := '0';
   signal ack_toggle_m      : std_logic := '0';            -- 2-FF synchronizer for ack
   signal ack_toggle_s      : std_logic := '0';

   signal stream_active     : std_logic := '0';            -- registered: req_status = LDNG
   signal size_err          : std_logic := '0';

   -- combinational helpers
   signal data_write        : std_logic;
   signal qnice_wait_stream : std_logic;

   constant C_ERR_ROM_TOO_LARGE : std_logic_vector(3 downto 0) := x"1";

   constant C_ERROR_STRINGS : string_vector(0 to 15) := (
      1      => "ROM too large      \n",
      others => "OK                 \n"
   );

   ---------------------------------------------------------------------------
   -- Core clock domain
   ---------------------------------------------------------------------------

   type   replay_state_type is (R_IDLE_ST, R_ARM_ST);
   signal replay_state      : replay_state_type := R_IDLE_ST;
   signal req_toggle_m      : std_logic := '0';            -- 2-FF synchronizer for req
   signal req_toggle_s      : std_logic := '0';
   signal req_toggle_p      : std_logic := '0';            -- previous, for edge detect
   signal ack_toggle        : std_logic := '0';
   signal isrom_m           : std_logic := '0';            -- 2-FF synchronizer for stream_active
   signal isrom_s           : std_logic := '0';
   signal rom_enabled       : std_logic := '0';

   attribute async_reg : string;
   attribute async_reg of ack_toggle_m, ack_toggle_s,
                          req_toggle_m, req_toggle_s,
                          isrom_m, isrom_s : signal is "true";

begin

   ---------------------------------------------------------------------------
   -- CSR: status/file-size registers and error string ROM (framework module)
   ---------------------------------------------------------------------------

   qnice_csr_inst : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_addr_i,
         qnice_data_i         => qnice_data_i,
         qnice_ce_i           => qnice_ce_i,
         qnice_we_i           => qnice_we_i,
         qnice_data_o         => qnice_csr_data,
         qnice_wait_o         => qnice_csr_wait,
         qnice_csr_o          => qnice_csr,
         qnice_req_status_o   => qnice_req_status,
         qnice_req_length_o   => qnice_req_length,
         qnice_resp_status_i  => qnice_resp_status,
         qnice_resp_error_i   => qnice_resp_error,
         qnice_resp_address_i => qnice_resp_addr
      ); -- qnice_csr_inst

   ---------------------------------------------------------------------------
   -- QNICE side: latch each streamed byte and stall the CPU until the
   -- core domain has consumed it.
   --
   -- The Shell writes one byte per bus write into the data window
   -- (qnice_csr = '0'); qnice_addr_i is the linear byte offset within the
   -- file. Because qnice_wait_o freezes the QNICE CPU mid-instruction,
   -- stream_data/stream_addr are guaranteed stable while req != ack:
   -- this is what makes the toggle CDC safe.
   ---------------------------------------------------------------------------

   data_write <= '1' when qnice_ce_i = '1' and qnice_we_i = '1' and
                          qnice_csr  = '0' and qnice_req_status = C_CSR_REQ_LDNG
            else '0';

   -- Stall while a transfer is pending or about to start. Deasserts in the
   -- same cycle the ack arrives, so QNICE completes the write on the next
   -- falling edge -- simultaneously with our BUSY->IDLE transition, which
   -- is why the same byte can never be latched twice.
   qnice_wait_stream <= '1' when data_write = '1' and size_err = '0' and
                                 not (stream_state = BUSY_ST and ack_toggle_s = req_toggle)
                   else '0';

   qnice_wait_o <= qnice_wait_stream or qnice_csr_wait;

   qnice_stream_proc : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         ack_toggle_m <= ack_toggle;
         ack_toggle_s <= ack_toggle_m;

         -- registered before CDC so the multi-bit status compare cannot glitch
         if qnice_req_status = C_CSR_REQ_LDNG then
            stream_active <= '1';
            -- new download: clear a stale size error from a previous too-large
            -- load; the Shell never returns the CSR status to IDLE after boot
            if stream_active = '0' then
               size_err <= '0';
            end if;
         else
            stream_active <= '0';
         end if;

         case stream_state is

            when IDLE_ST =>
               if data_write = '1' and size_err = '0' then
                  if unsigned(qnice_addr_i(22 downto 0)) >= G_ROM_MAX then
                     -- beyond BRAM capacity: swallow this and all further
                     -- bytes without stalling; report at parse time
                     size_err        <= '1';
                     qnice_resp_addr <= qnice_addr_i(22 downto 0);
                  else
                     stream_data  <= qnice_data_i(7 downto 0);
                     stream_addr  <= "00000" & qnice_addr_i(19 downto 0);
                     req_toggle   <= not req_toggle;
                     stream_state <= BUSY_ST;
                  end if;
               end if;

            when BUSY_ST =>
               if ack_toggle_s = req_toggle then
                  stream_state <= IDLE_ST;
               end if;

         end case;

         -- response handshake towards the Shell's PARSEST poll loop.
         -- Thanks to the per-byte stall, seeing REQ_OK means the last byte
         -- is already in the BRAM: we can answer immediately.
         case qnice_req_status is
            when C_CSR_REQ_LDNG =>
               qnice_resp_status <= C_CSR_RESP_PARSING;
               qnice_resp_error  <= (others => '0');
            when C_CSR_REQ_OK =>
               if size_err = '1' then
                  qnice_resp_status <= C_CSR_RESP_ERROR;
                  qnice_resp_error  <= C_ERR_ROM_TOO_LARGE;
               else
                  qnice_resp_status <= C_CSR_RESP_READY;
               end if;
            when others =>
               qnice_resp_status <= C_CSR_RESP_IDLE;
               size_err          <= '0';
         end case;

         if qnice_rst_i = '1' then
            stream_state      <= IDLE_ST;
            req_toggle        <= '0';
            ack_toggle_m      <= '0';
            ack_toggle_s      <= '0';
            stream_active     <= '0';
            size_err          <= '0';
            qnice_resp_status <= C_CSR_RESP_IDLE;
            qnice_resp_error  <= (others => '0');
            qnice_resp_addr   <= (others => '0');
         end if;
      end if;
   end process qnice_stream_proc;

   -- QNICE readback: only the CSR window is readable
   qnice_read_proc : process (all)
   begin
      qnice_data_o <= x"0000";
      if qnice_ce_i = '1' and qnice_csr = '1' then
         qnice_data_o <= qnice_csr_data;
      end if;
   end process qnice_read_proc;

   ---------------------------------------------------------------------------
   -- Core side: reconstruct the ioctl waveform.
   --
   -- stream_data/stream_addr are quasi-static while req != ack (QNICE is
   -- frozen), so sampling them here after the synchronized toggle edge is
   -- safe. R_ARM_ST waits for the isrom level (ordering at stream start)
   -- and for the core's ioctl_wait backpressure before firing the strobe.
   ---------------------------------------------------------------------------

   main_replay_proc : process (main_clk_i)
   begin
      if rising_edge(main_clk_i) then
         main_ioctl_wr_o <= '0';

         req_toggle_m <= req_toggle;
         req_toggle_s <= req_toggle_m;
         req_toggle_p <= req_toggle_s;

         isrom_m <= stream_active;
         isrom_s <= isrom_m;

         case replay_state is

            when R_IDLE_ST =>
               if req_toggle_p /= req_toggle_s then
                  main_ioctl_addr_o <= stream_addr;
                  main_ioctl_data_o <= stream_data;
                  replay_state      <= R_ARM_ST;
               end if;

            when R_ARM_ST =>
               if isrom_s = '1' and main_ioctl_wait_i = '0' then
                  main_ioctl_wr_o <= '1';
                  ack_toggle      <= req_toggle_s;
                  replay_state    <= R_IDLE_ST;
               end if;

         end case;

         -- sticky, like MSX1.sv: set at download start, survives the
         -- load-time core reset and OSD soft resets
         if isrom_s = '1' then
            rom_enabled <= '1';
         end if;

         if main_rst_i = '1' then
            replay_state <= R_IDLE_ST;
            req_toggle_m <= '0';
            req_toggle_s <= '0';
            req_toggle_p <= '0';
            ack_toggle   <= '0';
            isrom_m      <= '0';
            isrom_s      <= '0';
            rom_enabled  <= '0';
         end if;
      end if;
   end process main_replay_proc;

   main_ioctl_isrom_o <= isrom_s;
   main_rom_enabled_o <= rom_enabled;

   -- MSX1.sv holds the core in reset for the whole download:
   --    reset = RESET | ... | ioctl_isROMA | ioctl_isROMB | ...
   -- rom_detect.v has no reset input, so its detection state survives.
   main_core_reset_o  <= isrom_s;

end architecture beh;
