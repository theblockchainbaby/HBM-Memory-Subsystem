//=============================================================================
// Performance Monitor Module
//
// This module monitors and measures memory subsystem performance:
// - Latency measurement (per-transaction and average)
// - Throughput calculation
// - Bank utilization tracking
// - Latency histogram generation
// - Real-time bandwidth measurement
//=============================================================================

module performance_monitor
    import hbm_params_pkg::*;
#(
    parameter int LATENCY_BINS = 32,      // Number of histogram bins
    parameter int LATENCY_BIN_SIZE = 10   // Cycles per bin
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Control
    input  logic                        enable,
    input  logic                        clear,

    // Transaction monitoring (from AXI interface)
    input  logic                        aw_valid,
    input  logic                        aw_ready,
    input  logic [ADDR_WIDTH-1:0]       aw_addr,

    input  logic                        w_valid,
    input  logic                        w_ready,
    input  logic                        w_last,

    input  logic                        b_valid,
    input  logic                        b_ready,

    input  logic                        ar_valid,
    input  logic                        ar_ready,
    input  logic [ADDR_WIDTH-1:0]       ar_addr,

    input  logic                        r_valid,
    input  logic                        r_ready,
    input  logic                        r_last,

    // Bank state monitoring
    input  bank_state_t                 bank_states [NUM_BANKS],

    // Power state monitoring
    input  power_state_t                power_state,

    //=========================================================================
    // Performance Metrics Output
    //=========================================================================

    // Latency metrics (in clock cycles)
    output logic [31:0]                 min_read_latency,
    output logic [31:0]                 max_read_latency,
    output logic [31:0]                 avg_read_latency,
    output logic [31:0]                 min_write_latency,
    output logic [31:0]                 max_write_latency,
    output logic [31:0]                 avg_write_latency,

    // Throughput metrics
    output logic [31:0]                 read_throughput_mbps,   // MB/s
    output logic [31:0]                 write_throughput_mbps,
    output logic [31:0]                 total_throughput_mbps,

    // Transaction counts
    output logic [31:0]                 total_read_transactions,
    output logic [31:0]                 total_write_transactions,
    output logic [63:0]                 total_bytes_read,
    output logic [63:0]                 total_bytes_written,

    // Bank utilization (percentage * 100, e.g., 5000 = 50.00%)
    output logic [15:0]                 bank_utilization [NUM_BANKS],
    output logic [15:0]                 overall_bank_utilization,

    // Latency histogram (read transactions per bin)
    output logic [31:0]                 read_latency_histogram [LATENCY_BINS],
    output logic [31:0]                 write_latency_histogram [LATENCY_BINS],

    // Power state distribution
    output logic [31:0]                 active_state_cycles,
    output logic [31:0]                 idle_state_cycles,
    output logic [31:0]                 powerdown_state_cycles,

    // Efficiency metrics
    output logic [15:0]                 bus_efficiency,        // Data cycles / total cycles
    output logic [15:0]                 command_efficiency     // Successful / attempted
);

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Cycle counter
    logic [63:0] cycle_count;

    // Transaction tracking
    typedef struct packed {
        logic        valid;
        logic [63:0] start_cycle;
        logic [ADDR_WIDTH-1:0] addr;
    } pending_trans_t;

    // Pending transaction queues (simplified - track up to 16 outstanding)
    pending_trans_t pending_reads [16];
    pending_trans_t pending_writes [16];
    logic [3:0]     read_head, read_tail;
    logic [3:0]     write_head, write_tail;

    // Latency accumulators
    logic [63:0] total_read_latency;
    logic [63:0] total_write_latency;
    logic [31:0] read_count;
    logic [31:0] write_count;
    logic [31:0] read_lat_min, read_lat_max;
    logic [31:0] write_lat_min, write_lat_max;

    // Throughput tracking
    logic [63:0] bytes_read;
    logic [63:0] bytes_written;
    logic [63:0] throughput_window_start;
    logic [63:0] window_bytes_read;
    logic [63:0] window_bytes_written;

    // Bank utilization tracking
    logic [63:0] bank_active_cycles [NUM_BANKS];

    // Bus efficiency tracking
    logic [63:0] data_cycles;
    logic [63:0] cmd_attempts;
    logic [63:0] cmd_successes;

    // Histogram
    logic [31:0] read_hist [LATENCY_BINS];
    logic [31:0] write_hist [LATENCY_BINS];

    // Power state tracking
    logic [63:0] active_cycles;
    logic [63:0] idle_cycles;
    logic [63:0] powerdown_cycles;

    //=========================================================================
    // Cycle Counter
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= '0;
        end else if (clear) begin
            cycle_count <= '0;
        end else if (enable) begin
            cycle_count <= cycle_count + 1;
        end
    end

    //=========================================================================
    // Read Transaction Tracking
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            for (int i = 0; i < 16; i++) begin
                pending_reads[i] <= '0;
            end
            read_head <= '0;
            read_tail <= '0;
        end else if (enable) begin
            // Track new read request
            if (ar_valid && ar_ready) begin
                pending_reads[read_tail].valid <= 1'b1;
                pending_reads[read_tail].start_cycle <= cycle_count;
                pending_reads[read_tail].addr <= ar_addr;
                read_tail <= read_tail + 1;
            end

            // Complete read transaction
            if (r_valid && r_ready && r_last) begin
                pending_reads[read_head].valid <= 1'b0;
                read_head <= read_head + 1;
            end
        end
    end

    //=========================================================================
    // Write Transaction Tracking
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            for (int i = 0; i < 16; i++) begin
                pending_writes[i] <= '0;
            end
            write_head <= '0;
            write_tail <= '0;
        end else if (enable) begin
            // Track new write request
            if (aw_valid && aw_ready) begin
                pending_writes[write_tail].valid <= 1'b1;
                pending_writes[write_tail].start_cycle <= cycle_count;
                pending_writes[write_tail].addr <= aw_addr;
                write_tail <= write_tail + 1;
            end

            // Complete write transaction
            if (b_valid && b_ready) begin
                pending_writes[write_head].valid <= 1'b0;
                write_head <= write_head + 1;
            end
        end
    end

    //=========================================================================
    // Latency Calculation
    //=========================================================================

    // Combinational latency calculations
    logic [31:0] read_latency_calc;
    logic [31:0] write_latency_calc;
    logic [31:0] read_bin_calc;
    logic [31:0] write_bin_calc;

    always_comb begin
        read_latency_calc = cycle_count[31:0] - pending_reads[read_head].start_cycle[31:0];
        write_latency_calc = cycle_count[31:0] - pending_writes[write_head].start_cycle[31:0];
        read_bin_calc = read_latency_calc / LATENCY_BIN_SIZE;
        write_bin_calc = write_latency_calc / LATENCY_BIN_SIZE;
        if (read_bin_calc >= LATENCY_BINS) read_bin_calc = LATENCY_BINS - 1;
        if (write_bin_calc >= LATENCY_BINS) write_bin_calc = LATENCY_BINS - 1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            total_read_latency <= '0;
            total_write_latency <= '0;
            read_count <= '0;
            write_count <= '0;
            read_lat_min <= 32'hFFFFFFFF;
            read_lat_max <= '0;
            write_lat_min <= 32'hFFFFFFFF;
            write_lat_max <= '0;
            for (int i = 0; i < LATENCY_BINS; i++) begin
                read_hist[i] <= '0;
                write_hist[i] <= '0;
            end
        end else if (enable) begin
            // Calculate read latency on completion
            if (r_valid && r_ready && r_last && pending_reads[read_head].valid) begin
                total_read_latency <= total_read_latency + read_latency_calc;
                read_count <= read_count + 1;

                if (read_latency_calc < read_lat_min) read_lat_min <= read_latency_calc;
                if (read_latency_calc > read_lat_max) read_lat_max <= read_latency_calc;

                // Update histogram
                read_hist[read_bin_calc[4:0]] <= read_hist[read_bin_calc[4:0]] + 1;
            end

            // Calculate write latency on completion
            if (b_valid && b_ready && pending_writes[write_head].valid) begin
                total_write_latency <= total_write_latency + write_latency_calc;
                write_count <= write_count + 1;

                if (write_latency_calc < write_lat_min) write_lat_min <= write_latency_calc;
                if (write_latency_calc > write_lat_max) write_lat_max <= write_latency_calc;

                // Update histogram
                write_hist[write_bin_calc[4:0]] <= write_hist[write_bin_calc[4:0]] + 1;
            end
        end
    end

    // Average latency calculation (divide by count)
    assign avg_read_latency = (read_count > 0) ?
                              (total_read_latency / read_count) : 32'd0;
    assign avg_write_latency = (write_count > 0) ?
                               (total_write_latency / write_count) : 32'd0;

    assign min_read_latency = (read_count > 0) ? read_lat_min : 32'd0;
    assign max_read_latency = read_lat_max;
    assign min_write_latency = (write_count > 0) ? write_lat_min : 32'd0;
    assign max_write_latency = write_lat_max;

    //=========================================================================
    // Throughput Calculation
    //=========================================================================

    localparam int THROUGHPUT_WINDOW = 1000;  // Calculate over 1000 cycles

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            bytes_read <= '0;
            bytes_written <= '0;
            throughput_window_start <= '0;
            window_bytes_read <= '0;
            window_bytes_written <= '0;
        end else if (enable) begin
            // Count bytes transferred
            if (r_valid && r_ready) begin
                bytes_read <= bytes_read + (WIDE_BUS_WIDTH / 8);
                window_bytes_read <= window_bytes_read + (WIDE_BUS_WIDTH / 8);
            end

            if (w_valid && w_ready) begin
                bytes_written <= bytes_written + (WIDE_BUS_WIDTH / 8);
                window_bytes_written <= window_bytes_written + (WIDE_BUS_WIDTH / 8);
            end

            // Reset window periodically
            if (cycle_count - throughput_window_start >= THROUGHPUT_WINDOW) begin
                throughput_window_start <= cycle_count;
                window_bytes_read <= '0;
                window_bytes_written <= '0;
            end
        end
    end

    // Throughput in MB/s (assuming 1GHz clock = 1ns per cycle)
    // Throughput = bytes / window_cycles * 1e9 / 1e6 = bytes / window * 1000
    assign read_throughput_mbps = (window_bytes_read * 1000) / THROUGHPUT_WINDOW;
    assign write_throughput_mbps = (window_bytes_written * 1000) / THROUGHPUT_WINDOW;
    assign total_throughput_mbps = read_throughput_mbps + write_throughput_mbps;

    assign total_bytes_read = bytes_read;
    assign total_bytes_written = bytes_written;
    assign total_read_transactions = read_count;
    assign total_write_transactions = write_count;

    //=========================================================================
    // Bank Utilization Tracking
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                bank_active_cycles[b] <= '0;
            end
        end else if (enable) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                if (bank_states[b] != BANK_IDLE) begin
                    bank_active_cycles[b] <= bank_active_cycles[b] + 1;
                end
            end
        end
    end

    // Calculate utilization percentage (x100 for precision)
    logic [31:0] total_util_comb;
    always_comb begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            if (cycle_count > 0) begin
                bank_utilization[b] = (bank_active_cycles[b] * 10000) / cycle_count;
            end else begin
                bank_utilization[b] = 0;
            end
        end

        // Overall utilization (average)
        total_util_comb = 0;
        for (int b = 0; b < NUM_BANKS; b++) begin
            total_util_comb = total_util_comb + bank_utilization[b];
        end
        overall_bank_utilization = total_util_comb / NUM_BANKS;
    end

    //=========================================================================
    // Power State Tracking
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            active_cycles <= '0;
            idle_cycles <= '0;
            powerdown_cycles <= '0;
        end else if (enable) begin
            case (power_state)
                PWR_ACTIVE:     active_cycles <= active_cycles + 1;
                PWR_IDLE:       idle_cycles <= idle_cycles + 1;
                PWR_STANDBY:    idle_cycles <= idle_cycles + 1;
                PWR_POWER_DOWN: powerdown_cycles <= powerdown_cycles + 1;
                PWR_SELF_REFRESH: powerdown_cycles <= powerdown_cycles + 1;
            endcase
        end
    end

    assign active_state_cycles = active_cycles[31:0];
    assign idle_state_cycles = idle_cycles[31:0];
    assign powerdown_state_cycles = powerdown_cycles[31:0];

    //=========================================================================
    // Bus Efficiency Tracking
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            data_cycles <= '0;
            cmd_attempts <= '0;
            cmd_successes <= '0;
        end else if (enable) begin
            // Data cycles (actual data transfer)
            if ((r_valid && r_ready) || (w_valid && w_ready)) begin
                data_cycles <= data_cycles + 1;
            end

            // Command attempts
            if (ar_valid || aw_valid) begin
                cmd_attempts <= cmd_attempts + 1;
            end

            // Command successes
            if ((ar_valid && ar_ready) || (aw_valid && aw_ready)) begin
                cmd_successes <= cmd_successes + 1;
            end
        end
    end

    // Efficiency calculations (percentage x 100)
    assign bus_efficiency = (cycle_count > 0) ?
                           ((data_cycles * 10000) / cycle_count) : 16'd0;
    assign command_efficiency = (cmd_attempts > 0) ?
                               ((cmd_successes * 10000) / cmd_attempts) : 16'd10000;

    //=========================================================================
    // Histogram Output
    //=========================================================================

    always_comb begin
        for (int i = 0; i < LATENCY_BINS; i++) begin
            read_latency_histogram[i] = read_hist[i];
            write_latency_histogram[i] = write_hist[i];
        end
    end

    //=========================================================================
    // Performance Report Generation
    //=========================================================================

    `ifdef SIMULATION
    // Print performance report
    task print_report();
        $display("\n");
        $display("╔═══════════════════════════════════════════════════════════════╗");
        $display("║              HBM SUBSYSTEM PERFORMANCE REPORT                 ║");
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ Total Simulation Cycles: %0d", cycle_count);
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ LATENCY METRICS (cycles)                                      ║");
        $display("║   Read:  Min=%0d  Max=%0d  Avg=%0d",
                 min_read_latency, max_read_latency, avg_read_latency);
        $display("║   Write: Min=%0d  Max=%0d  Avg=%0d",
                 min_write_latency, max_write_latency, avg_write_latency);
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ THROUGHPUT METRICS                                            ║");
        $display("║   Read Throughput:  %0d MB/s", read_throughput_mbps);
        $display("║   Write Throughput: %0d MB/s", write_throughput_mbps);
        $display("║   Total Throughput: %0d MB/s", total_throughput_mbps);
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ TRANSACTION COUNTS                                            ║");
        $display("║   Total Reads:  %0d (%0d bytes)", read_count, bytes_read);
        $display("║   Total Writes: %0d (%0d bytes)", write_count, bytes_written);
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ BANK UTILIZATION                                              ║");
        for (int b = 0; b < NUM_BANKS; b++) begin
            $display("║   Bank[%0d]: %0d.%02d%%", b,
                     bank_utilization[b]/100, bank_utilization[b]%100);
        end
        $display("║   Overall: %0d.%02d%%",
                 overall_bank_utilization/100, overall_bank_utilization%100);
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ EFFICIENCY METRICS                                            ║");
        $display("║   Bus Efficiency:     %0d.%02d%%",
                 bus_efficiency/100, bus_efficiency%100);
        $display("║   Command Efficiency: %0d.%02d%%",
                 command_efficiency/100, command_efficiency%100);
        $display("╠═══════════════════════════════════════════════════════════════╣");
        $display("║ POWER STATE DISTRIBUTION                                      ║");
        $display("║   Active:    %0d cycles (%0d%%)",
                 active_cycles, (active_cycles * 100) / (cycle_count > 0 ? cycle_count : 1));
        $display("║   Idle:      %0d cycles (%0d%%)",
                 idle_cycles, (idle_cycles * 100) / (cycle_count > 0 ? cycle_count : 1));
        $display("║   Power-Down: %0d cycles (%0d%%)",
                 powerdown_cycles, (powerdown_cycles * 100) / (cycle_count > 0 ? cycle_count : 1));
        $display("╚═══════════════════════════════════════════════════════════════╝");
        $display("\n");
    endtask

    // Print latency histogram
    task print_histogram();
        $display("\n=== READ LATENCY HISTOGRAM ===");
        for (int i = 0; i < LATENCY_BINS; i++) begin
            if (read_hist[i] > 0) begin
                $display("  [%3d-%3d]: %0d",
                         i * LATENCY_BIN_SIZE,
                         (i + 1) * LATENCY_BIN_SIZE - 1,
                         read_hist[i]);
            end
        end

        $display("\n=== WRITE LATENCY HISTOGRAM ===");
        for (int i = 0; i < LATENCY_BINS; i++) begin
            if (write_hist[i] > 0) begin
                $display("  [%3d-%3d]: %0d",
                         i * LATENCY_BIN_SIZE,
                         (i + 1) * LATENCY_BIN_SIZE - 1,
                         write_hist[i]);
            end
        end
    endtask
    `endif

endmodule : performance_monitor
