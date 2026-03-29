//=============================================================================
// Memory Bank Module
//
// This module implements a single DRAM memory bank with:
// - Row buffer (sense amplifiers) emulation
// - State machine tracking bank state (idle, active, precharging, etc.)
// - Timing-aware response generation
// - Refresh handling
// - Memory array storage
//=============================================================================

`include "hbm_params.vh"

module memory_bank
#(
    parameter int BANK_ID = 0
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Command interface from controller
    input  dram_cmd_t                   cmd,
    input  logic [ROW_ADDR_WIDTH-1:0]   row_addr,
    input  logic [COL_ADDR_WIDTH-1:0]   col_addr,
    input  logic [DATA_WIDTH-1:0]       write_data,
    input  logic                        cmd_valid,

    // Response interface to controller
    output logic [DATA_WIDTH-1:0]       read_data,
    output logic                        read_valid,

    // Status interface
    output bank_state_t                 state,
    output logic [ROW_ADDR_WIDTH-1:0]   open_row,

    // Power management
    input  power_state_t                power_state,

    // Debug/monitoring
    output logic [31:0]                 access_count,
    output logic [31:0]                 refresh_count
);

    //=========================================================================
    // Memory Array
    // Note: For simulation, we use a sparse memory model to avoid allocating
    // the full memory array which would be too large
    //=========================================================================

    // Row buffer (holds one activated row)
    logic [DATA_WIDTH-1:0] row_buffer [NUM_COLS];

    // Memory array - using 2D array (reduced size for simulation)
    // For full implementation, use associative array with VCS/Questa
    localparam int SIM_ROWS = 256;  // Reduced row count for Icarus compatibility
    logic [DATA_WIDTH-1:0] memory_array [SIM_ROWS][NUM_COLS];

    //=========================================================================
    // Internal Signals
    //=========================================================================

    bank_state_t current_state, next_state;

    // Timing counters
    logic [9:0] timing_counter;
    logic       timing_done;

    // Open row tracking
    logic [ROW_ADDR_WIDTH-1:0] active_row;
    logic                      row_open;

    // Command latching
    dram_cmd_t                   latched_cmd;
    logic [ROW_ADDR_WIDTH-1:0]   latched_row;
    logic [COL_ADDR_WIDTH-1:0]   latched_col;
    logic [DATA_WIDTH-1:0]       latched_wdata;

    // Read pipeline
    logic [DATA_WIDTH-1:0]       read_data_reg;
    logic [3:0]                  read_delay_counter;
    logic                        read_pending;

    // Statistics
    logic [31:0] access_cnt;
    logic [31:0] refresh_cnt;

    //=========================================================================
    // State Machine
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= BANK_IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // Next state logic
    always_comb begin
        next_state = current_state;

        case (current_state)
            BANK_IDLE: begin
                if (cmd_valid) begin
                    case (cmd)
                        CMD_ACTIVATE: next_state = BANK_ACTIVATING;
                        CMD_REFRESH:  next_state = BANK_REFRESHING;
                        CMD_POWER_DOWN: next_state = BANK_IDLE; // Handled by power manager
                        default:      next_state = BANK_IDLE;
                    endcase
                end
            end

            BANK_ACTIVATING: begin
                if (timing_done) begin
                    next_state = BANK_ACTIVE;
                end
            end

            BANK_ACTIVE: begin
                if (cmd_valid) begin
                    case (cmd)
                        CMD_READ:      next_state = BANK_READING;
                        CMD_WRITE:     next_state = BANK_WRITING;
                        CMD_PRECHARGE: next_state = BANK_PRECHARGING;
                        default:       next_state = BANK_ACTIVE;
                    endcase
                end
            end

            BANK_READING: begin
                if (timing_done) begin
                    next_state = BANK_ACTIVE;
                end
            end

            BANK_WRITING: begin
                if (timing_done) begin
                    next_state = BANK_ACTIVE;
                end
            end

            BANK_PRECHARGING: begin
                if (timing_done) begin
                    next_state = BANK_IDLE;
                end
            end

            BANK_REFRESHING: begin
                if (timing_done) begin
                    next_state = BANK_IDLE;
                end
            end

            default: next_state = BANK_IDLE;
        endcase
    end

    //=========================================================================
    // Timing Counter
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timing_counter <= '0;
        end else begin
            if (cmd_valid && current_state == BANK_IDLE) begin
                case (cmd)
                    CMD_ACTIVATE: timing_counter <= tRCD;
                    CMD_REFRESH:  timing_counter <= tRFC;
                    default:      timing_counter <= '0;
                endcase
            end else if (cmd_valid && current_state == BANK_ACTIVE) begin
                case (cmd)
                    CMD_READ:      timing_counter <= tCAS;
                    CMD_WRITE:     timing_counter <= tCAS;
                    CMD_PRECHARGE: timing_counter <= tRP;
                    default:       timing_counter <= '0;
                endcase
            end else if (timing_counter > 0) begin
                timing_counter <= timing_counter - 1;
            end
        end
    end

    assign timing_done = (timing_counter == 1);  // Done on last cycle

    //=========================================================================
    // Command Latching
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched_cmd <= CMD_NOP;
            latched_row <= '0;
            latched_col <= '0;
            latched_wdata <= '0;
        end else if (cmd_valid) begin
            latched_cmd <= cmd;
            latched_row <= row_addr;
            latched_col <= col_addr;
            latched_wdata <= write_data;
        end
    end

    //=========================================================================
    // Row Buffer and Memory Array Operations
    //=========================================================================

    // Activate operation - load row into row buffer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_row <= '0;
            row_open <= 1'b0;
            for (int i = 0; i < NUM_COLS; i++) begin
                row_buffer[i] <= '0;
            end
        end else begin
            // Activate: load row from memory array into row buffer
            if (current_state == BANK_ACTIVATING && timing_done) begin
                active_row <= latched_row;
                row_open <= 1'b1;

                // Load row into row buffer
                for (int c = 0; c < NUM_COLS; c++) begin
                    // Use modulo to map to simulation row space
                    row_buffer[c] <= memory_array[latched_row % SIM_ROWS][c];
                end
            end

            // Precharge: write back row buffer to memory array
            if (current_state == BANK_PRECHARGING && timing_done) begin
                row_open <= 1'b0;

                // Write back row buffer to memory array
                for (int c = 0; c < NUM_COLS; c++) begin
                    memory_array[active_row % SIM_ROWS][c] <= row_buffer[c];
                end
            end

            // Refresh: for simulation, just clear the refresh flag
            // In real hardware, this would restore charge on all cells
            if (current_state == BANK_REFRESHING && timing_done) begin
                row_open <= 1'b0;
            end
        end
    end

    //=========================================================================
    // Read Operation
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_data_reg <= '0;
            read_delay_counter <= '0;
            read_pending <= 1'b0;
            read_valid <= 1'b0;
        end else begin
            // Start read operation
            if (current_state == BANK_ACTIVE && cmd_valid && cmd == CMD_READ) begin
                read_data_reg <= row_buffer[col_addr];
                read_delay_counter <= tCAS - 1;
                read_pending <= 1'b1;
            end

            // Count down read latency
            if (read_pending && read_delay_counter > 0) begin
                read_delay_counter <= read_delay_counter - 1;
            end

            // Output read data after CAS latency
            if (read_pending && read_delay_counter == 0) begin
                read_valid <= 1'b1;
                read_pending <= 1'b0;
            end else begin
                read_valid <= 1'b0;
            end
        end
    end

    assign read_data = read_data_reg;

    //=========================================================================
    // Write Operation
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Row buffer initialized in activate section
        end else begin
            // Write to row buffer
            if (current_state == BANK_ACTIVE && cmd_valid && cmd == CMD_WRITE) begin
                row_buffer[col_addr] <= write_data;
            end
        end
    end

    //=========================================================================
    // Status Outputs
    //=========================================================================

    assign state = current_state;
    assign open_row = active_row;

    //=========================================================================
    // Statistics Counters
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            access_cnt <= '0;
            refresh_cnt <= '0;
        end else begin
            // Count accesses
            if (cmd_valid && (cmd == CMD_READ || cmd == CMD_WRITE)) begin
                access_cnt <= access_cnt + 1;
            end

            // Count refreshes
            if (cmd_valid && cmd == CMD_REFRESH) begin
                refresh_cnt <= refresh_cnt + 1;
            end
        end
    end

    assign access_count = access_cnt;
    assign refresh_count = refresh_cnt;

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SVA_ENABLE
    always @(posedge clk) begin
        if (cmd_valid && rst_n) begin
            case (cmd)
                CMD_ACTIVATE:
                    $display("[%0t] Bank[%0d]: ACTIVATE row=%0d", $time, BANK_ID, row_addr);
                CMD_READ:
                    $display("[%0t] Bank[%0d]: READ col=%0d data=0x%016h",
                             $time, BANK_ID, col_addr, row_buffer[col_addr]);
                CMD_WRITE:
                    $display("[%0t] Bank[%0d]: WRITE col=%0d data=0x%016h",
                             $time, BANK_ID, col_addr, write_data);
                CMD_PRECHARGE:
                    $display("[%0t] Bank[%0d]: PRECHARGE", $time, BANK_ID);
                CMD_REFRESH:
                    $display("[%0t] Bank[%0d]: REFRESH", $time, BANK_ID);
                default: ;
            endcase
        end
    end
    `endif

    //=========================================================================
    // Assertions
    //=========================================================================

    `ifdef SVA_ENABLE
    // Cannot read/write when bank is not active
    property p_rw_requires_active;
        @(posedge clk) disable iff (!rst_n)
        (cmd_valid && (cmd == CMD_READ || cmd == CMD_WRITE)) |->
            (current_state == BANK_ACTIVE);
    endproperty
    assert property (p_rw_requires_active) else
        $error("Bank[%0d]: Read/Write issued when bank not active", BANK_ID);

    // Cannot activate when already active
    property p_no_double_activate;
        @(posedge clk) disable iff (!rst_n)
        (cmd_valid && cmd == CMD_ACTIVATE) |->
            (current_state == BANK_IDLE);
    endproperty
    assert property (p_no_double_activate) else
        $error("Bank[%0d]: Activate issued when bank already active", BANK_ID);

    // Precharge only when active
    property p_precharge_when_active;
        @(posedge clk) disable iff (!rst_n)
        (cmd_valid && cmd == CMD_PRECHARGE) |->
            (current_state == BANK_ACTIVE || current_state == BANK_READING ||
             current_state == BANK_WRITING);
    endproperty
    assert property (p_precharge_when_active) else
        $error("Bank[%0d]: Precharge issued when bank not active", BANK_ID);
    `endif

endmodule : memory_bank
