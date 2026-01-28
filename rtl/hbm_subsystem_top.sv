//=============================================================================
// HBM Subsystem Top-Level Module
//
// This is the top-level integration module that connects all components:
// - Wide Bus Interface (AXI-like system interface)
// - Bank Interleaver
// - DRAM Controller
// - Memory Banks (8 banks)
// - ECC Module
// - Power Manager
//
// Architecture:
//
//   System Bus (512-bit)
//         |
//   +-------------+
//   | Wide Bus    |
//   | Interface   |
//   +-------------+
//         |
//   +-------------+
//   | Bank        |
//   | Interleaver |
//   +-------------+
//         |
//   +-------------+     +-------------+
//   | DRAM        |<--->| Power       |
//   | Controller  |     | Manager     |
//   +-------------+     +-------------+
//         |
//   +-------------+
//   |  ECC Module |
//   +-------------+
//         |
//   +---+---+---+---+---+---+---+---+
//   | B | B | B | B | B | B | B | B |
//   | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
//   +---+---+---+---+---+---+---+---+
//
//=============================================================================

module hbm_subsystem_top
    import hbm_params_pkg::*;
(
    input  logic                        clk,
    input  logic                        rst_n,

    //=========================================================================
    // AXI-like System Interface (512-bit wide)
    //=========================================================================

    // Write Address Channel
    input  logic                        s_awvalid,
    output logic                        s_awready,
    input  logic [ADDR_WIDTH-1:0]       s_awaddr,
    input  logic [7:0]                  s_awlen,
    input  logic [2:0]                  s_awsize,
    input  logic [1:0]                  s_awburst,

    // Write Data Channel
    input  logic                        s_wvalid,
    output logic                        s_wready,
    input  logic [WIDE_BUS_WIDTH-1:0]   s_wdata,
    input  logic [WIDE_BUS_WIDTH/8-1:0] s_wstrb,
    input  logic                        s_wlast,

    // Write Response Channel
    output logic                        s_bvalid,
    input  logic                        s_bready,
    output logic [1:0]                  s_bresp,

    // Read Address Channel
    input  logic                        s_arvalid,
    output logic                        s_arready,
    input  logic [ADDR_WIDTH-1:0]       s_araddr,
    input  logic [7:0]                  s_arlen,
    input  logic [2:0]                  s_arsize,
    input  logic [1:0]                  s_arburst,

    // Read Data Channel
    output logic                        s_rvalid,
    input  logic                        s_rready,
    output logic [WIDE_BUS_WIDTH-1:0]   s_rdata,
    output logic [1:0]                  s_rresp,
    output logic                        s_rlast,

    //=========================================================================
    // Configuration Interface
    //=========================================================================

    input  logic [1:0]                  cfg_interleave_mode,
    input  logic [15:0]                 cfg_idle_timeout,
    input  logic [15:0]                 cfg_standby_timeout,
    input  logic [15:0]                 cfg_powerdown_timeout,
    input  logic                        cfg_force_active,
    input  logic                        cfg_force_powerdown,
    input  logic                        cfg_force_self_refresh,

    // ECC error injection (for testing)
    input  logic                        cfg_ecc_inject_enable,
    input  logic [6:0]                  cfg_ecc_inject_position,
    input  logic                        cfg_ecc_inject_double,

    //=========================================================================
    // Status and Statistics Interface
    //=========================================================================

    output power_state_t                status_power_state,
    output logic                        status_wake_up_in_progress,
    output perf_counters_t              status_perf_counters,

    // Per-bank status
    output bank_state_t                 status_bank_states [NUM_BANKS],

    // Detailed statistics
    output logic [31:0]                 stats_total_requests,
    output logic [31:0]                 stats_bank_conflicts,
    output logic [31:0]                 stats_total_bursts,
    output logic [31:0]                 stats_ecc_corrections,
    output logic [31:0]                 stats_ecc_errors,
    output logic [31:0]                 stats_active_cycles,
    output logic [31:0]                 stats_idle_cycles,
    output logic [31:0]                 stats_powerdown_cycles,
    output logic [31:0]                 stats_estimated_energy
);

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Wide Bus to Interleaver
    logic                        wb_req_valid;
    logic                        wb_req_ready;
    logic                        wb_req_write;
    logic [ADDR_WIDTH-1:0]       wb_req_addr;
    logic [DATA_WIDTH-1:0]       wb_req_wdata;
    logic [7:0]                  wb_req_tag;

    logic                        wb_resp_valid;
    logic [DATA_WIDTH-1:0]       wb_resp_rdata;
    logic [7:0]                  wb_resp_tag;
    logic                        wb_resp_error;

    // Interleaver to Controller
    mem_request_t                int_req;
    logic                        int_req_ready;

    // Controller to Banks
    dram_cmd_t                   ctrl_bank_cmd       [NUM_BANKS];
    logic [ROW_ADDR_WIDTH-1:0]   ctrl_bank_row_addr  [NUM_BANKS];
    logic [COL_ADDR_WIDTH-1:0]   ctrl_bank_col_addr  [NUM_BANKS];
    logic [DATA_WIDTH-1:0]       ctrl_bank_write_data[NUM_BANKS];
    logic                        ctrl_bank_cmd_valid [NUM_BANKS];

    // Banks to Controller
    logic [DATA_WIDTH-1:0]       bank_read_data      [NUM_BANKS];
    logic                        bank_read_valid     [NUM_BANKS];
    bank_state_t                 bank_states         [NUM_BANKS];
    logic [ROW_ADDR_WIDTH-1:0]   bank_open_row       [NUM_BANKS];

    // Controller Response
    mem_response_t               ctrl_resp;
    logic                        ctrl_resp_valid;

    // ECC interfaces
    logic                        ecc_encode_valid;
    logic [ECC_DATA_WIDTH-1:0]   ecc_encode_data_in;
    logic [ECC_TOTAL_WIDTH-1:0]  ecc_encode_data_out;
    logic                        ecc_encode_done;

    logic                        ecc_decode_valid;
    logic [ECC_TOTAL_WIDTH-1:0]  ecc_decode_data_in;
    logic [ECC_DATA_WIDTH-1:0]   ecc_decode_data_out;
    logic                        ecc_decode_done;
    logic                        ecc_single_error;
    logic                        ecc_double_error;
    logic [6:0]                  ecc_error_position;

    // Power management
    power_state_t                power_state;
    power_state_t                bank_power_states   [NUM_BANKS];
    logic                        refresh_req;
    logic                        refresh_ack;
    logic                        wake_up_in_progress;
    logic [7:0]                  wake_up_cycles_remaining;

    // Bank statistics
    logic [31:0]                 bank_access_count   [NUM_BANKS];
    logic [31:0]                 bank_refresh_count  [NUM_BANKS];

    // Interleaver statistics
    logic [31:0]                 interleaver_total_requests;
    logic [31:0]                 interleaver_bank_conflicts;

    // Wide bus statistics
    logic [31:0]                 widebus_total_bursts;
    logic [31:0]                 widebus_total_beats;
    logic [63:0]                 widebus_total_bytes;

    // ECC statistics
    logic [31:0]                 ecc_corrections_count;
    logic [31:0]                 ecc_uncorrectable_count;

    // Power statistics
    logic [31:0]                 pwr_active_cycles;
    logic [31:0]                 pwr_idle_cycles;
    logic [31:0]                 pwr_standby_cycles;
    logic [31:0]                 pwr_powerdown_cycles;
    logic [31:0]                 pwr_selfrefresh_cycles;
    logic [31:0]                 pwr_estimated_energy;

    // Controller perf counters
    perf_counters_t              ctrl_perf_counters;

    // Request pending for power manager
    logic                        request_pending;

    //=========================================================================
    // Wide Bus Interface Instance
    //=========================================================================

    wide_bus_interface u_wide_bus (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // System interface
        .awvalid                (s_awvalid),
        .awready                (s_awready),
        .awaddr                 (s_awaddr),
        .awlen                  (s_awlen),
        .awsize                 (s_awsize),
        .awburst                (s_awburst),

        .wvalid                 (s_wvalid),
        .wready                 (s_wready),
        .wdata                  (s_wdata),
        .wstrb                  (s_wstrb),
        .wlast                  (s_wlast),

        .bvalid                 (s_bvalid),
        .bready                 (s_bready),
        .bresp                  (s_bresp),

        .arvalid                (s_arvalid),
        .arready                (s_arready),
        .araddr                 (s_araddr),
        .arlen                  (s_arlen),
        .arsize                 (s_arsize),
        .arburst                (s_arburst),

        .rvalid                 (s_rvalid),
        .rready                 (s_rready),
        .rdata                  (s_rdata),
        .rresp                  (s_rresp),
        .rlast                  (s_rlast),

        // Memory interface
        .mem_req_valid          (wb_req_valid),
        .mem_req_ready          (wb_req_ready),
        .mem_req_write          (wb_req_write),
        .mem_req_addr           (wb_req_addr),
        .mem_req_wdata          (wb_req_wdata),
        .mem_req_tag            (wb_req_tag),

        .mem_resp_valid         (wb_resp_valid),
        .mem_resp_rdata         (wb_resp_rdata),
        .mem_resp_tag           (wb_resp_tag),
        .mem_resp_error         (wb_resp_error),

        // Statistics
        .total_bursts           (widebus_total_bursts),
        .total_beats            (widebus_total_beats),
        .total_bytes_transferred(widebus_total_bytes)
    );

    //=========================================================================
    // Bank Interleaver Instance
    //=========================================================================

    bank_interleaver u_interleaver (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // External interface
        .req_valid              (wb_req_valid),
        .req_write              (wb_req_write),
        .req_addr               (wb_req_addr),
        .req_wdata              (wb_req_wdata),
        .req_tag                (wb_req_tag),
        .req_ready              (wb_req_ready),

        .resp_valid             (wb_resp_valid),
        .resp_rdata             (wb_resp_rdata),
        .resp_tag               (wb_resp_tag),
        .resp_error             (wb_resp_error),

        // Controller interface
        .ctrl_req               (int_req),
        .ctrl_ready             (int_req_ready),

        .ctrl_resp              (ctrl_resp),
        .ctrl_resp_valid        (ctrl_resp_valid),

        // Configuration
        .interleave_mode        (cfg_interleave_mode),

        // Statistics
        .total_requests         (interleaver_total_requests),
        .bank_conflicts         (interleaver_bank_conflicts)
    );

    //=========================================================================
    // DRAM Controller Instance
    //=========================================================================

    dram_controller u_controller (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // Request interface
        .req_in                 (int_req),
        .req_ready              (int_req_ready),

        // Response interface
        .resp_out               (ctrl_resp),
        .resp_valid             (ctrl_resp_valid),

        // Bank command interface
        .bank_cmd               (ctrl_bank_cmd),
        .bank_row_addr          (ctrl_bank_row_addr),
        .bank_col_addr          (ctrl_bank_col_addr),
        .bank_write_data        (ctrl_bank_write_data),
        .bank_cmd_valid         (ctrl_bank_cmd_valid),

        // Bank response interface
        .bank_read_data         (bank_read_data),
        .bank_read_valid        (bank_read_valid),
        .bank_state             (bank_states),
        .bank_open_row          (bank_open_row),

        // Power management
        .power_state            (power_state),
        .refresh_req            (refresh_req),
        .refresh_ack            (refresh_ack),

        // Performance counters
        .perf_counters          (ctrl_perf_counters)
    );

    // Request pending signal for power manager
    assign request_pending = int_req.valid;

    //=========================================================================
    // Memory Banks (8 instances)
    //=========================================================================

    genvar g;
    generate
        for (g = 0; g < NUM_BANKS; g++) begin : gen_banks
            memory_bank #(
                .BANK_ID        (g)
            ) u_bank (
                .clk            (clk),
                .rst_n          (rst_n),

                // Command interface
                .cmd            (ctrl_bank_cmd[g]),
                .row_addr       (ctrl_bank_row_addr[g]),
                .col_addr       (ctrl_bank_col_addr[g]),
                .write_data     (ctrl_bank_write_data[g]),
                .cmd_valid      (ctrl_bank_cmd_valid[g]),

                // Response interface
                .read_data      (bank_read_data[g]),
                .read_valid     (bank_read_valid[g]),

                // Status
                .state          (bank_states[g]),
                .open_row       (bank_open_row[g]),

                // Power
                .power_state    (bank_power_states[g]),

                // Statistics
                .access_count   (bank_access_count[g]),
                .refresh_count  (bank_refresh_count[g])
            );
        end
    endgenerate

    //=========================================================================
    // ECC Module Instance
    //=========================================================================

    ecc_module u_ecc (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // Encode path (writes)
        .encode_valid           (ecc_encode_valid),
        .encode_data_in         (ecc_encode_data_in),
        .encode_data_out        (ecc_encode_data_out),
        .encode_done            (ecc_encode_done),

        // Decode path (reads)
        .decode_valid           (ecc_decode_valid),
        .decode_data_in         (ecc_decode_data_in),
        .decode_data_out        (ecc_decode_data_out),
        .decode_done            (ecc_decode_done),
        .single_error           (ecc_single_error),
        .double_error           (ecc_double_error),
        .error_position         (ecc_error_position),

        // Error injection
        .inject_enable          (cfg_ecc_inject_enable),
        .inject_position        (cfg_ecc_inject_position),
        .inject_double          (cfg_ecc_inject_double),

        // Statistics
        .corrections_count      (ecc_corrections_count),
        .uncorrectable_count    (ecc_uncorrectable_count)
    );

    // ECC is in the data path - for simplicity, bypass in this version
    // In full implementation, ECC would wrap all bank data
    assign ecc_encode_valid = 1'b0;  // Not used in passthrough mode
    assign ecc_encode_data_in = '0;
    assign ecc_decode_valid = 1'b0;
    assign ecc_decode_data_in = '0;

    //=========================================================================
    // Power Manager Instance
    //=========================================================================

    power_manager u_power_mgr (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // Activity monitoring
        .request_pending        (request_pending),
        .refresh_pending        (refresh_req),
        .bank_states            (bank_states),

        // Power state output
        .current_power_state    (power_state),
        .bank_power_states      (bank_power_states),

        // Control
        .force_active           (cfg_force_active),
        .force_power_down       (cfg_force_powerdown),
        .force_self_refresh     (cfg_force_self_refresh),

        // Configuration
        .idle_timeout           (cfg_idle_timeout),
        .standby_timeout        (cfg_standby_timeout),
        .powerdown_timeout      (cfg_powerdown_timeout),

        // Wake-up signaling
        .wake_up_in_progress    (wake_up_in_progress),
        .wake_up_cycles_remaining(wake_up_cycles_remaining),

        // Statistics
        .active_cycles          (pwr_active_cycles),
        .idle_cycles            (pwr_idle_cycles),
        .standby_cycles         (pwr_standby_cycles),
        .powerdown_cycles       (pwr_powerdown_cycles),
        .self_refresh_cycles    (pwr_selfrefresh_cycles),
        .estimated_energy       (pwr_estimated_energy)
    );

    // Refresh acknowledge (simple implementation)
    assign refresh_ack = refresh_req;

    //=========================================================================
    // Status and Statistics Outputs
    //=========================================================================

    assign status_power_state = power_state;
    assign status_wake_up_in_progress = wake_up_in_progress;
    assign status_perf_counters = ctrl_perf_counters;

    always_comb begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            status_bank_states[b] = bank_states[b];
        end
    end

    assign stats_total_requests = interleaver_total_requests;
    assign stats_bank_conflicts = interleaver_bank_conflicts;
    assign stats_total_bursts = widebus_total_bursts;
    assign stats_ecc_corrections = ecc_corrections_count;
    assign stats_ecc_errors = ecc_uncorrectable_count;
    assign stats_active_cycles = pwr_active_cycles;
    assign stats_idle_cycles = pwr_idle_cycles;
    assign stats_powerdown_cycles = pwr_powerdown_cycles;
    assign stats_estimated_energy = pwr_estimated_energy;

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SIMULATION
    initial begin
        $display("=================================================");
        $display("HBM Subsystem Configuration:");
        $display("  Number of Banks:    %0d", NUM_BANKS);
        $display("  Rows per Bank:      %0d", NUM_ROWS);
        $display("  Columns per Row:    %0d", NUM_COLS);
        $display("  Data Width:         %0d bits", DATA_WIDTH);
        $display("  Wide Bus Width:     %0d bits", WIDE_BUS_WIDTH);
        $display("  ECC Data Width:     %0d bits", ECC_DATA_WIDTH);
        $display("  ECC Total Width:    %0d bits", ECC_TOTAL_WIDTH);
        $display("  Address Width:      %0d bits", ADDR_WIDTH);
        $display("=================================================");
        $display("Timing Parameters (cycles):");
        $display("  tRCD: %0d  tRP: %0d  tRAS: %0d  tCAS: %0d",
                 tRCD, tRP, tRAS, tCAS);
        $display("  tRFC: %0d  tREFI: %0d", tRFC, tREFI);
        $display("=================================================");
    end
    `endif

endmodule : hbm_subsystem_top
