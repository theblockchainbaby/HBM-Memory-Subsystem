//=============================================================================
// Power Management Unit
//
// This module implements power state management for the HBM subsystem:
// - Multiple power states: Active, Idle, Standby, Power-Down, Self-Refresh
// - Activity monitoring for automatic state transitions
// - Wake-up latency management
// - Per-bank power state tracking
// - Power consumption estimation
//=============================================================================

`include "hbm_params.vh"

module power_manager
(
    input  logic                        clk,
    input  logic                        rst_n,

    // Activity monitoring
    input  logic                        request_pending,    // Any pending memory request
    input  logic                        refresh_pending,    // Refresh needed
    input  bank_state_t                 bank_states [NUM_BANKS],

    // Power state output
    output power_state_t                current_power_state,
    output power_state_t                bank_power_states [NUM_BANKS],

    // Control interface
    input  logic                        force_active,       // Force active state
    input  logic                        force_power_down,   // Force power-down
    input  logic                        force_self_refresh, // Force self-refresh

    // Configuration
    input  logic [15:0]                 idle_timeout,       // Cycles before entering idle
    input  logic [15:0]                 standby_timeout,    // Cycles in idle before standby
    input  logic [15:0]                 powerdown_timeout,  // Cycles in standby before power-down

    // Wake-up signaling
    output logic                        wake_up_in_progress,
    output logic [7:0]                  wake_up_cycles_remaining,

    // Power estimation outputs
    output logic [31:0]                 active_cycles,
    output logic [31:0]                 idle_cycles,
    output logic [31:0]                 standby_cycles,
    output logic [31:0]                 powerdown_cycles,
    output logic [31:0]                 self_refresh_cycles,
    output logic [31:0]                 estimated_energy    // Arbitrary units
);

    //=========================================================================
    // Power Consumption Model (relative units)
    //=========================================================================

    localparam int POWER_ACTIVE      = 100;  // Full power during active operation
    localparam int POWER_IDLE        = 50;   // Reduced power, quick wake-up
    localparam int POWER_STANDBY     = 20;   // Clock gated, moderate wake-up
    localparam int POWER_POWER_DOWN  = 5;    // Very low power, slow wake-up
    localparam int POWER_SELF_REFRESH = 8;   // Low power with refresh

    //=========================================================================
    // Internal Signals
    //=========================================================================

    power_state_t pwr_state, pwr_state_next;
    power_state_t bank_pwr_state [NUM_BANKS];

    // Timeout counters
    logic [15:0] idle_counter;
    logic [15:0] standby_counter;
    logic [15:0] powerdown_counter;

    // Wake-up management
    logic [7:0]  wakeup_counter;
    logic        waking_up;

    // Activity detection
    logic        any_bank_active;
    logic        activity_detected;

    // Statistics
    logic [31:0] active_cnt;
    logic [31:0] idle_cnt;
    logic [31:0] standby_cnt;
    logic [31:0] powerdown_cnt;
    logic [31:0] selfrefresh_cnt;
    logic [63:0] energy_accumulator;

    //=========================================================================
    // Activity Detection
    //=========================================================================

    always_comb begin
        any_bank_active = 1'b0;
        for (int b = 0; b < NUM_BANKS; b++) begin
            if (bank_states[b] != BANK_IDLE) begin
                any_bank_active = 1'b1;
            end
        end
        activity_detected = request_pending || any_bank_active || refresh_pending;
    end

    //=========================================================================
    // Main Power State Machine
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwr_state <= PWR_ACTIVE;
        end else begin
            pwr_state <= pwr_state_next;
        end
    end

    // Next state logic
    always_comb begin
        pwr_state_next = pwr_state;

        // Handle forced states
        if (force_active) begin
            pwr_state_next = PWR_ACTIVE;
        end else if (force_power_down && !activity_detected && !waking_up) begin
            pwr_state_next = PWR_POWER_DOWN;
        end else if (force_self_refresh && !activity_detected && !waking_up) begin
            pwr_state_next = PWR_SELF_REFRESH;
        end else begin
            case (pwr_state)
                PWR_ACTIVE: begin
                    if (!activity_detected && idle_counter >= idle_timeout) begin
                        pwr_state_next = PWR_IDLE;
                    end
                end

                PWR_IDLE: begin
                    if (activity_detected || waking_up) begin
                        pwr_state_next = PWR_ACTIVE;
                    end else if (standby_counter >= standby_timeout) begin
                        pwr_state_next = PWR_STANDBY;
                    end
                end

                PWR_STANDBY: begin
                    if (activity_detected || waking_up) begin
                        pwr_state_next = PWR_ACTIVE;
                    end else if (powerdown_counter >= powerdown_timeout) begin
                        pwr_state_next = PWR_POWER_DOWN;
                    end
                end

                PWR_POWER_DOWN: begin
                    if (activity_detected || refresh_pending) begin
                        pwr_state_next = PWR_ACTIVE;  // Will trigger wake-up
                    end
                end

                PWR_SELF_REFRESH: begin
                    if (activity_detected && !refresh_pending) begin
                        pwr_state_next = PWR_ACTIVE;  // Will trigger wake-up
                    end
                end

                default: pwr_state_next = PWR_ACTIVE;
            endcase
        end
    end

    //=========================================================================
    // Timeout Counters
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_counter <= '0;
            standby_counter <= '0;
            powerdown_counter <= '0;
        end else begin
            // Idle counter
            if (pwr_state == PWR_ACTIVE && !activity_detected) begin
                idle_counter <= idle_counter + 1;
            end else begin
                idle_counter <= '0;
            end

            // Standby counter
            if (pwr_state == PWR_IDLE && !activity_detected) begin
                standby_counter <= standby_counter + 1;
            end else begin
                standby_counter <= '0;
            end

            // Power-down counter
            if (pwr_state == PWR_STANDBY && !activity_detected) begin
                powerdown_counter <= powerdown_counter + 1;
            end else begin
                powerdown_counter <= '0;
            end
        end
    end

    //=========================================================================
    // Wake-Up Management
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wakeup_counter <= '0;
            waking_up <= 1'b0;
        end else begin
            if (!waking_up && activity_detected &&
                (pwr_state == PWR_POWER_DOWN || pwr_state == PWR_SELF_REFRESH)) begin
                // Start wake-up sequence
                waking_up <= 1'b1;
                case (pwr_state)
                    PWR_POWER_DOWN:   wakeup_counter <= tXP;
                    PWR_SELF_REFRESH: wakeup_counter <= tXS;
                    PWR_STANDBY:      wakeup_counter <= tCKE;
                    default:          wakeup_counter <= 1;
                endcase
            end else if (waking_up) begin
                if (wakeup_counter > 0) begin
                    wakeup_counter <= wakeup_counter - 1;
                end else begin
                    waking_up <= 1'b0;
                end
            end
        end
    end

    assign wake_up_in_progress = waking_up;
    assign wake_up_cycles_remaining = wakeup_counter;

    //=========================================================================
    // Per-Bank Power State (simplified - follows global state)
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                bank_pwr_state[b] <= PWR_ACTIVE;
            end
        end else begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                // Banks can be individually in different states based on activity
                if (bank_states[b] != BANK_IDLE) begin
                    bank_pwr_state[b] <= PWR_ACTIVE;
                end else begin
                    bank_pwr_state[b] <= pwr_state;
                end
            end
        end
    end

    //=========================================================================
    // Statistics and Power Estimation
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_cnt <= '0;
            idle_cnt <= '0;
            standby_cnt <= '0;
            powerdown_cnt <= '0;
            selfrefresh_cnt <= '0;
            energy_accumulator <= '0;
        end else begin
            // Count cycles in each state
            case (pwr_state)
                PWR_ACTIVE: begin
                    active_cnt <= active_cnt + 1;
                    energy_accumulator <= energy_accumulator + POWER_ACTIVE;
                end
                PWR_IDLE: begin
                    idle_cnt <= idle_cnt + 1;
                    energy_accumulator <= energy_accumulator + POWER_IDLE;
                end
                PWR_STANDBY: begin
                    standby_cnt <= standby_cnt + 1;
                    energy_accumulator <= energy_accumulator + POWER_STANDBY;
                end
                PWR_POWER_DOWN: begin
                    powerdown_cnt <= powerdown_cnt + 1;
                    energy_accumulator <= energy_accumulator + POWER_POWER_DOWN;
                end
                PWR_SELF_REFRESH: begin
                    selfrefresh_cnt <= selfrefresh_cnt + 1;
                    energy_accumulator <= energy_accumulator + POWER_SELF_REFRESH;
                end
            endcase
        end
    end

    //=========================================================================
    // Output Assignments
    //=========================================================================

    assign current_power_state = power_state_t'(waking_up ? PWR_ACTIVE : pwr_state);

    always_comb begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            bank_power_states[b] = power_state_t'(bank_pwr_state[b]);
        end
    end

    assign active_cycles = active_cnt;
    assign idle_cycles = idle_cnt;
    assign standby_cycles = standby_cnt;
    assign powerdown_cycles = powerdown_cnt;
    assign self_refresh_cycles = selfrefresh_cnt;
    assign estimated_energy = energy_accumulator[31:0];  // Lower 32 bits

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SVA_ENABLE
    power_state_t prev_state;

    always @(posedge clk) begin
        if (rst_n && pwr_state != prev_state) begin
            $display("[%0t] PowerManager: State transition %s -> %s",
                     $time, prev_state.name(), pwr_state.name());
            prev_state <= pwr_state;
        end
    end

    initial prev_state = PWR_ACTIVE;
    `endif

    //=========================================================================
    // Assertions
    //=========================================================================

    `ifdef SVA_ENABLE
    // Cannot transition directly from power-down to active without wake-up
    property p_wakeup_required;
        @(posedge clk) disable iff (!rst_n)
        (pwr_state == PWR_POWER_DOWN && pwr_state_next == PWR_ACTIVE) |->
            (waking_up || activity_detected);
    endproperty
    assert property (p_wakeup_required) else
        $error("Invalid power state transition without wake-up");

    // During wake-up, should not accept commands
    property p_no_cmd_during_wakeup;
        @(posedge clk) disable iff (!rst_n)
        waking_up |-> (current_power_state == PWR_ACTIVE);
    endproperty
    // Note: Current design allows commands during wake-up, but they'll be delayed
    `endif

endmodule : power_manager
