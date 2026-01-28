//=============================================================================
// DRAM Controller Module
//
// This module implements the core DRAM controller with:
// - Command scheduling respecting DRAM timing constraints
// - Per-bank state tracking
// - Request queuing and arbitration
// - Timing counters for tRCD, tRP, tRAS, tCAS, etc.
// - Refresh management
//=============================================================================

module dram_controller
    import hbm_params_pkg::*;
(
    input  logic                        clk,
    input  logic                        rst_n,

    // Request interface (from bank interleaver)
    input  mem_request_t                req_in,
    output logic                        req_ready,

    // Response interface (to wide bus interface)
    output mem_response_t               resp_out,
    output logic                        resp_valid,

    // Bank command interface
    output dram_cmd_t                   bank_cmd        [NUM_BANKS],
    output logic [ROW_ADDR_WIDTH-1:0]   bank_row_addr   [NUM_BANKS],
    output logic [COL_ADDR_WIDTH-1:0]   bank_col_addr   [NUM_BANKS],
    output logic [DATA_WIDTH-1:0]       bank_write_data [NUM_BANKS],
    output logic                        bank_cmd_valid  [NUM_BANKS],

    // Bank response interface
    input  logic [DATA_WIDTH-1:0]       bank_read_data  [NUM_BANKS],
    input  logic                        bank_read_valid [NUM_BANKS],
    input  bank_state_t                 bank_state      [NUM_BANKS],
    input  logic [ROW_ADDR_WIDTH-1:0]   bank_open_row   [NUM_BANKS],

    // Power management interface
    input  power_state_t                power_state,
    output logic                        refresh_req,
    input  logic                        refresh_ack,

    // Performance counters
    output perf_counters_t              perf_counters
);

    //=========================================================================
    // Internal Types
    //=========================================================================

    // Controller states
    typedef enum logic [3:0] {
        CTRL_IDLE,
        CTRL_ACTIVATE,
        CTRL_WAIT_ACTIVATE,
        CTRL_READ,
        CTRL_WRITE,
        CTRL_WAIT_DATA,
        CTRL_PRECHARGE,
        CTRL_WAIT_PRECHARGE,
        CTRL_REFRESH,
        CTRL_WAIT_REFRESH,
        CTRL_POWER_DOWN
    } ctrl_state_t;

    // Pending request entry
    typedef struct packed {
        logic                          valid;
        mem_request_t                  request;
        logic [15:0]                   age;  // For aging-based priority
    } pending_req_t;

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Controller state machine
    ctrl_state_t ctrl_state, ctrl_state_next;

    // Current request being processed
    mem_request_t current_req;
    logic         current_req_valid;

    // Request queue (simple 4-entry queue per bank)
    pending_req_t req_queue [NUM_BANKS][4];
    logic [1:0]   queue_head [NUM_BANKS];
    logic [1:0]   queue_tail [NUM_BANKS];
    logic [2:0]   queue_count [NUM_BANKS];

    // Per-bank timing counters
    logic [9:0]   bank_timer      [NUM_BANKS];  // General purpose timer
    logic [9:0]   bank_act_timer  [NUM_BANKS];  // Time since activation
    logic         bank_timing_ok  [NUM_BANKS];  // Timing constraints met

    // Global timing counters
    logic [15:0]  refresh_counter;
    logic [3:0]   faw_counter [4];  // Four Activate Window tracking
    logic [1:0]   faw_index;
    logic         faw_ok;

    // Data pipeline registers
    logic [DATA_WIDTH-1:0] read_data_pipe [4];
    logic [7:0]            read_tag_pipe  [4];
    logic                  read_valid_pipe [4];
    logic [2:0]            read_bank_pipe [4];

    // Write pipeline
    logic [DATA_WIDTH-1:0] write_data_reg;
    logic [2:0]            write_bank_reg;
    logic                  write_pending;

    // Performance counters internal
    perf_counters_t perf_cnt;

    // Bank selection
    logic [BANK_ADDR_WIDTH-1:0] selected_bank;
    logic                       bank_ready [NUM_BANKS];

    //=========================================================================
    // Request Queue Management
    //=========================================================================

    // Enqueue incoming requests
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                for (int i = 0; i < 4; i++) begin
                    req_queue[b][i].valid <= 1'b0;
                end
                queue_head[b] <= '0;
                queue_tail[b] <= '0;
                queue_count[b] <= '0;
            end
        end else begin
            // Enqueue new request
            if (req_in.valid && req_ready) begin
                req_queue[req_in.bank_addr][queue_tail[req_in.bank_addr]].valid   <= 1'b1;
                req_queue[req_in.bank_addr][queue_tail[req_in.bank_addr]].request <= req_in;
                req_queue[req_in.bank_addr][queue_tail[req_in.bank_addr]].age     <= '0;
                queue_tail[req_in.bank_addr] <= queue_tail[req_in.bank_addr] + 1;
                queue_count[req_in.bank_addr] <= queue_count[req_in.bank_addr] + 1;
            end

            // Dequeue when request is processed
            if (current_req_valid &&
                (ctrl_state == CTRL_READ || ctrl_state == CTRL_WRITE)) begin
                req_queue[current_req.bank_addr][queue_head[current_req.bank_addr]].valid <= 1'b0;
                queue_head[current_req.bank_addr] <= queue_head[current_req.bank_addr] + 1;
                queue_count[current_req.bank_addr] <= queue_count[current_req.bank_addr] - 1;
            end

            // Age all pending requests
            for (int b = 0; b < NUM_BANKS; b++) begin
                for (int i = 0; i < 4; i++) begin
                    if (req_queue[b][i].valid && req_queue[b][i].age < 16'hFFFF) begin
                        req_queue[b][i].age <= req_queue[b][i].age + 1;
                    end
                end
            end
        end
    end

    // Request ready signal (can accept if any bank queue has space)
    always_comb begin
        if (power_state == PWR_POWER_DOWN || power_state == PWR_SELF_REFRESH) begin
            req_ready = 1'b0;
        end else begin
            req_ready = (queue_count[req_in.bank_addr] < 3);
        end
    end

    //=========================================================================
    // Per-Bank Timing Control
    //=========================================================================

    // Timing counters per bank
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                bank_timer[b]     <= '0;
                bank_act_timer[b] <= '0;
            end
        end else begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                // Decrement timer if non-zero
                if (bank_timer[b] > 0) begin
                    bank_timer[b] <= bank_timer[b] - 1;
                end

                // Track time since activation
                if (bank_state[b] == BANK_ACTIVATING) begin
                    bank_act_timer[b] <= '0;
                end else if (bank_state[b] == BANK_ACTIVE ||
                             bank_state[b] == BANK_READING ||
                             bank_state[b] == BANK_WRITING) begin
                    if (bank_act_timer[b] < 10'h3FF) begin
                        bank_act_timer[b] <= bank_act_timer[b] + 1;
                    end
                end else begin
                    bank_act_timer[b] <= '0;
                end

                // Set timer on command issue
                if (bank_cmd_valid[b]) begin
                    case (bank_cmd[b])
                        CMD_ACTIVATE:  bank_timer[b] <= tRCD;
                        CMD_READ:      bank_timer[b] <= tCAS + tBURST;
                        CMD_WRITE:     bank_timer[b] <= tCAS + tBURST + tWR;
                        CMD_PRECHARGE: bank_timer[b] <= tRP;
                        CMD_REFRESH:   bank_timer[b] <= tRFC;
                        default:       bank_timer[b] <= bank_timer[b];
                    endcase
                end
            end
        end
    end

    // Timing OK signals
    always_comb begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            bank_timing_ok[b] = (bank_timer[b] == 0);
        end
    end

    //=========================================================================
    // Four Activate Window (tFAW) Tracking
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) begin
                faw_counter[i] <= '0;
            end
            faw_index <= '0;
        end else begin
            // Decrement all FAW counters
            for (int i = 0; i < 4; i++) begin
                if (faw_counter[i] > 0) begin
                    faw_counter[i] <= faw_counter[i] - 1;
                end
            end

            // Record new activation
            for (int b = 0; b < NUM_BANKS; b++) begin
                if (bank_cmd_valid[b] && bank_cmd[b] == CMD_ACTIVATE) begin
                    faw_counter[faw_index] <= tFAW;
                    faw_index <= faw_index + 1;
                end
            end
        end
    end

    // Check if FAW allows new activation
    assign faw_ok = (faw_counter[0] == 0) || (faw_counter[1] == 0) ||
                    (faw_counter[2] == 0) || (faw_counter[3] == 0);

    //=========================================================================
    // Refresh Counter
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_counter <= tREFI;
            refresh_req <= 1'b0;
        end else begin
            if (refresh_counter > 0) begin
                refresh_counter <= refresh_counter - 1;
                refresh_req <= 1'b0;
            end else begin
                refresh_req <= 1'b1;
                if (refresh_ack) begin
                    refresh_counter <= tREFI;
                end
            end
        end
    end

    //=========================================================================
    // Bank Selection and Request Arbitration
    //=========================================================================

    // Determine which banks are ready for commands
    always_comb begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            bank_ready[b] = queue_count[b] > 0 &&
                            bank_timing_ok[b] &&
                            power_state == PWR_ACTIVE;
        end
    end

    // Select bank with oldest request (simple round-robin with aging)
    logic [15:0] max_age_comb;
    always_comb begin
        selected_bank = '0;
        max_age_comb = '0;

        for (int b = 0; b < NUM_BANKS; b++) begin
            if (bank_ready[b] && req_queue[b][queue_head[b]].valid) begin
                if (req_queue[b][queue_head[b]].age > max_age_comb) begin
                    max_age_comb = req_queue[b][queue_head[b]].age;
                    selected_bank = b[BANK_ADDR_WIDTH-1:0];
                end
            end
        end
    end

    //=========================================================================
    // Main Controller State Machine
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_state <= CTRL_IDLE;
            current_req_valid <= 1'b0;
        end else begin
            ctrl_state <= ctrl_state_next;

            // Capture current request
            if (ctrl_state == CTRL_IDLE && ctrl_state_next != CTRL_IDLE) begin
                if (ctrl_state_next != CTRL_REFRESH && ctrl_state_next != CTRL_POWER_DOWN) begin
                    current_req <= req_queue[selected_bank][queue_head[selected_bank]].request;
                    current_req_valid <= 1'b1;
                end
            end

            if (ctrl_state == CTRL_READ || ctrl_state == CTRL_WRITE) begin
                current_req_valid <= 1'b0;
            end
        end
    end

    // Next state logic
    always_comb begin
        ctrl_state_next = ctrl_state;

        case (ctrl_state)
            CTRL_IDLE: begin
                if (power_state == PWR_POWER_DOWN) begin
                    ctrl_state_next = CTRL_POWER_DOWN;
                end else if (refresh_req && refresh_ack) begin
                    ctrl_state_next = CTRL_REFRESH;
                end else if (bank_ready[selected_bank]) begin
                    if (bank_state[selected_bank] == BANK_IDLE) begin
                        // Need to activate row first
                        if (faw_ok) begin
                            ctrl_state_next = CTRL_ACTIVATE;
                        end
                    end else if (bank_state[selected_bank] == BANK_ACTIVE) begin
                        if (bank_open_row[selected_bank] == req_queue[selected_bank][queue_head[selected_bank]].request.row_addr) begin
                            // Row hit - can issue R/W directly
                            if (req_queue[selected_bank][queue_head[selected_bank]].request.req_type == REQ_READ) begin
                                ctrl_state_next = CTRL_READ;
                            end else begin
                                ctrl_state_next = CTRL_WRITE;
                            end
                        end else begin
                            // Row miss - need to precharge first
                            ctrl_state_next = CTRL_PRECHARGE;
                        end
                    end
                end
            end

            CTRL_ACTIVATE: begin
                ctrl_state_next = CTRL_WAIT_ACTIVATE;
            end

            CTRL_WAIT_ACTIVATE: begin
                if (bank_timing_ok[current_req.bank_addr] &&
                    bank_state[current_req.bank_addr] == BANK_ACTIVE) begin
                    if (current_req.req_type == REQ_READ) begin
                        ctrl_state_next = CTRL_READ;
                    end else begin
                        ctrl_state_next = CTRL_WRITE;
                    end
                end
            end

            CTRL_READ: begin
                ctrl_state_next = CTRL_WAIT_DATA;
            end

            CTRL_WRITE: begin
                ctrl_state_next = CTRL_IDLE;
            end

            CTRL_WAIT_DATA: begin
                if (bank_read_valid[current_req.bank_addr]) begin
                    ctrl_state_next = CTRL_IDLE;
                end
            end

            CTRL_PRECHARGE: begin
                ctrl_state_next = CTRL_WAIT_PRECHARGE;
            end

            CTRL_WAIT_PRECHARGE: begin
                if (bank_timing_ok[current_req.bank_addr] &&
                    bank_state[current_req.bank_addr] == BANK_IDLE) begin
                    if (faw_ok) begin
                        ctrl_state_next = CTRL_ACTIVATE;
                    end
                end
            end

            CTRL_REFRESH: begin
                ctrl_state_next = CTRL_WAIT_REFRESH;
            end

            CTRL_WAIT_REFRESH: begin
                if (bank_state[0] != BANK_REFRESHING &&
                    bank_state[1] != BANK_REFRESHING &&
                    bank_state[2] != BANK_REFRESHING &&
                    bank_state[3] != BANK_REFRESHING &&
                    bank_state[4] != BANK_REFRESHING &&
                    bank_state[5] != BANK_REFRESHING &&
                    bank_state[6] != BANK_REFRESHING &&
                    bank_state[7] != BANK_REFRESHING) begin
                    ctrl_state_next = CTRL_IDLE;
                end
            end

            CTRL_POWER_DOWN: begin
                if (power_state == PWR_ACTIVE) begin
                    ctrl_state_next = CTRL_IDLE;
                end
            end

            default: ctrl_state_next = CTRL_IDLE;
        endcase
    end

    //=========================================================================
    // Command Generation
    //=========================================================================

    always_comb begin
        // Default: no commands
        for (int b = 0; b < NUM_BANKS; b++) begin
            bank_cmd[b] = CMD_NOP;
            bank_row_addr[b] = '0;
            bank_col_addr[b] = '0;
            bank_write_data[b] = '0;
            bank_cmd_valid[b] = 1'b0;
        end

        case (ctrl_state)
            CTRL_ACTIVATE: begin
                bank_cmd[current_req.bank_addr] = CMD_ACTIVATE;
                bank_row_addr[current_req.bank_addr] = current_req.row_addr;
                bank_cmd_valid[current_req.bank_addr] = 1'b1;
            end

            CTRL_READ: begin
                bank_cmd[current_req.bank_addr] = CMD_READ;
                bank_col_addr[current_req.bank_addr] = current_req.col_addr;
                bank_cmd_valid[current_req.bank_addr] = 1'b1;
            end

            CTRL_WRITE: begin
                bank_cmd[current_req.bank_addr] = CMD_WRITE;
                bank_col_addr[current_req.bank_addr] = current_req.col_addr;
                bank_write_data[current_req.bank_addr] = current_req.write_data;
                bank_cmd_valid[current_req.bank_addr] = 1'b1;
            end

            CTRL_PRECHARGE: begin
                bank_cmd[current_req.bank_addr] = CMD_PRECHARGE;
                bank_cmd_valid[current_req.bank_addr] = 1'b1;
            end

            CTRL_REFRESH: begin
                for (int b = 0; b < NUM_BANKS; b++) begin
                    bank_cmd[b] = CMD_REFRESH;
                    bank_cmd_valid[b] = 1'b1;
                end
            end

            default: begin
                // NOP on all banks
            end
        endcase
    end

    //=========================================================================
    // Read Data Pipeline
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) begin
                read_data_pipe[i] <= '0;
                read_tag_pipe[i] <= '0;
                read_valid_pipe[i] <= 1'b0;
            end
        end else begin
            // Shift pipeline
            read_data_pipe[3]  <= read_data_pipe[2];
            read_tag_pipe[3]   <= read_tag_pipe[2];
            read_valid_pipe[3] <= read_valid_pipe[2];

            read_data_pipe[2]  <= read_data_pipe[1];
            read_tag_pipe[2]   <= read_tag_pipe[1];
            read_valid_pipe[2] <= read_valid_pipe[1];

            read_data_pipe[1]  <= read_data_pipe[0];
            read_tag_pipe[1]   <= read_tag_pipe[0];
            read_valid_pipe[1] <= read_valid_pipe[0];

            // Capture read data from banks
            read_valid_pipe[0] <= 1'b0;
            for (int b = 0; b < NUM_BANKS; b++) begin
                if (bank_read_valid[b]) begin
                    read_data_pipe[0] <= bank_read_data[b];
                    read_tag_pipe[0] <= current_req.tag;
                    read_valid_pipe[0] <= 1'b1;
                end
            end
        end
    end

    //=========================================================================
    // Response Generation
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_out <= '0;
            resp_valid <= 1'b0;
        end else begin
            resp_valid <= read_valid_pipe[3];
            resp_out.valid <= read_valid_pipe[3];
            resp_out.read_data <= read_data_pipe[3];
            resp_out.tag <= read_tag_pipe[3];
            resp_out.error <= 1'b0;      // ECC will set this
            resp_out.corrected <= 1'b0;  // ECC will set this
        end
    end

    //=========================================================================
    // Performance Counters
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_cnt <= '0;
        end else begin
            // Count reads
            if (ctrl_state == CTRL_READ) begin
                perf_cnt.total_reads <= perf_cnt.total_reads + 1;
            end

            // Count writes
            if (ctrl_state == CTRL_WRITE) begin
                perf_cnt.total_writes <= perf_cnt.total_writes + 1;
            end

            // Count row hits vs misses
            if (ctrl_state == CTRL_IDLE && ctrl_state_next == CTRL_READ ||
                ctrl_state == CTRL_IDLE && ctrl_state_next == CTRL_WRITE) begin
                perf_cnt.row_hits <= perf_cnt.row_hits + 1;
            end

            if (ctrl_state == CTRL_IDLE && ctrl_state_next == CTRL_PRECHARGE) begin
                perf_cnt.row_misses <= perf_cnt.row_misses + 1;
            end

            if (ctrl_state == CTRL_IDLE && ctrl_state_next == CTRL_ACTIVATE) begin
                perf_cnt.row_misses <= perf_cnt.row_misses + 1;
            end

            // Count refresh cycles
            if (ctrl_state == CTRL_REFRESH || ctrl_state == CTRL_WAIT_REFRESH) begin
                perf_cnt.refresh_cycles <= perf_cnt.refresh_cycles + 1;
            end

            // Count power-down cycles
            if (ctrl_state == CTRL_POWER_DOWN) begin
                perf_cnt.power_down_cycles <= perf_cnt.power_down_cycles + 1;
            end
        end
    end

    assign perf_counters = perf_cnt;

    //=========================================================================
    // Assertions
    //=========================================================================

    `ifdef SVA_ENABLE
    // Verify tRCD timing
    property p_trcd_timing;
        @(posedge clk) disable iff (!rst_n)
        (ctrl_state == CTRL_ACTIVATE) |->
            ##[tRCD:$] (ctrl_state == CTRL_READ || ctrl_state == CTRL_WRITE);
    endproperty
    assert property (p_trcd_timing) else
        $error("tRCD timing violation");

    // Verify no commands during power-down
    property p_power_down_no_cmd;
        @(posedge clk) disable iff (!rst_n)
        (power_state == PWR_POWER_DOWN) |->
            !(|{bank_cmd_valid[0], bank_cmd_valid[1], bank_cmd_valid[2], bank_cmd_valid[3],
                bank_cmd_valid[4], bank_cmd_valid[5], bank_cmd_valid[6], bank_cmd_valid[7]});
    endproperty
    assert property (p_power_down_no_cmd) else
        $error("Command issued during power-down");
    `endif

endmodule : dram_controller
