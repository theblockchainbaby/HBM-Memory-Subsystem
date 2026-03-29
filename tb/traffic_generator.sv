//=============================================================================
// Traffic Generator Module
//
// This module generates synthetic memory traffic patterns for testing:
// - Sequential access pattern
// - Random access pattern
// - Bank-conflicting pattern (all accesses to same bank)
// - Strided access pattern
// - Burst pattern with configurable length
//=============================================================================

`include "hbm_params.vh"

module traffic_generator
#(
    parameter int SEED = 12345
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Control interface
    input  logic                        start,
    input  logic                        stop,
    output logic                        done,
    output logic                        busy,

    // Configuration
    input  logic [2:0]                  pattern_type,   // Traffic pattern selection
    input  logic [31:0]                 num_transactions,
    input  logic [ADDR_WIDTH-1:0]       start_addr,
    input  logic [ADDR_WIDTH-1:0]       addr_range,
    input  logic [7:0]                  burst_length,   // For burst patterns
    input  logic [7:0]                  read_write_ratio, // 0=all write, 255=all read
    input  logic [15:0]                 stride,         // For strided pattern

    // AXI Write Address Channel
    output logic                        awvalid,
    input  logic                        awready,
    output logic [ADDR_WIDTH-1:0]       awaddr,
    output logic [7:0]                  awlen,
    output logic [2:0]                  awsize,
    output logic [1:0]                  awburst,

    // AXI Write Data Channel
    output logic                        wvalid,
    input  logic                        wready,
    output logic [WIDE_BUS_WIDTH-1:0]   wdata,
    output logic [WIDE_BUS_WIDTH/8-1:0] wstrb,
    output logic                        wlast,

    // AXI Write Response Channel
    input  logic                        bvalid,
    output logic                        bready,
    input  logic [1:0]                  bresp,

    // AXI Read Address Channel
    output logic                        arvalid,
    input  logic                        arready,
    output logic [ADDR_WIDTH-1:0]       araddr,
    output logic [7:0]                  arlen,
    output logic [2:0]                  arsize,
    output logic [1:0]                  arburst,

    // AXI Read Data Channel
    input  logic                        rvalid,
    output logic                        rready,
    input  logic [WIDE_BUS_WIDTH-1:0]   rdata,
    input  logic [1:0]                  rresp,
    input  logic                        rlast,

    // Statistics
    output logic [31:0]                 writes_completed,
    output logic [31:0]                 reads_completed,
    output logic [31:0]                 errors_detected
);

    //=========================================================================
    // Pattern Types
    //=========================================================================

    localparam logic [2:0] PATTERN_SEQUENTIAL   = 3'b000;
    localparam logic [2:0] PATTERN_RANDOM       = 3'b001;
    localparam logic [2:0] PATTERN_BANK_CONFLICT= 3'b010;
    localparam logic [2:0] PATTERN_STRIDED      = 3'b011;
    localparam logic [2:0] PATTERN_BURST        = 3'b100;
    localparam logic [2:0] PATTERN_MIXED        = 3'b101;

    //=========================================================================
    // State Machine
    //=========================================================================

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_GEN_ADDR,
        ST_WRITE_ADDR,
        ST_WRITE_DATA,
        ST_WRITE_RESP,
        ST_READ_ADDR,
        ST_READ_DATA,
        ST_NEXT,
        ST_DONE
    } state_t;

    state_t state, state_next;

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Transaction counters
    logic [31:0] transaction_count;
    logic [31:0] write_count;
    logic [31:0] read_count;
    logic [31:0] error_count;

    // Current transaction
    logic [ADDR_WIDTH-1:0] current_addr;
    logic                  current_is_write;
    logic [7:0]            current_burst_count;
    logic [WIDE_BUS_WIDTH-1:0] current_data;

    // Random number generator (LFSR)
    logic [31:0] lfsr;
    logic [31:0] random_val;

    // Sequential address tracking
    logic [ADDR_WIDTH-1:0] seq_addr;

    // Expected read data (for verification)
    logic [WIDE_BUS_WIDTH-1:0] expected_data;

    // Bank conflict tracking
    logic [BANK_ADDR_WIDTH-1:0] conflict_bank;

    //=========================================================================
    // LFSR Random Number Generator
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= SEED;
        end else begin
            // Galois LFSR with polynomial x^32 + x^22 + x^2 + x + 1
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        end
    end

    assign random_val = lfsr;

    //=========================================================================
    // State Machine
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= state_next;
        end
    end

    always_comb begin
        state_next = state;

        case (state)
            ST_IDLE: begin
                if (start) begin
                    state_next = ST_GEN_ADDR;
                end
            end

            ST_GEN_ADDR: begin
                if (transaction_count >= num_transactions || stop) begin
                    state_next = ST_DONE;
                end else if (current_is_write) begin
                    state_next = ST_WRITE_ADDR;
                end else begin
                    state_next = ST_READ_ADDR;
                end
            end

            ST_WRITE_ADDR: begin
                if (awvalid && awready) begin
                    state_next = ST_WRITE_DATA;
                end
            end

            ST_WRITE_DATA: begin
                if (wvalid && wready && wlast) begin
                    state_next = ST_WRITE_RESP;
                end
            end

            ST_WRITE_RESP: begin
                if (bvalid && bready) begin
                    state_next = ST_NEXT;
                end
            end

            ST_READ_ADDR: begin
                if (arvalid && arready) begin
                    state_next = ST_READ_DATA;
                end
            end

            ST_READ_DATA: begin
                if (rvalid && rready && rlast) begin
                    state_next = ST_NEXT;
                end
            end

            ST_NEXT: begin
                state_next = ST_GEN_ADDR;
            end

            ST_DONE: begin
                if (start) begin
                    state_next = ST_GEN_ADDR;  // Allow restart
                end
            end

            default: state_next = ST_IDLE;
        endcase
    end

    //=========================================================================
    // Address Generation
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_addr <= '0;
            seq_addr <= '0;
            conflict_bank <= '0;
            current_is_write <= 1'b0;
            current_burst_count <= '0;
        end else begin
            if (state == ST_IDLE && start) begin
                seq_addr <= start_addr;
                conflict_bank <= random_val[BANK_ADDR_WIDTH-1:0];
            end

            if (state == ST_GEN_ADDR) begin
                // Determine read/write
                current_is_write <= (random_val[7:0] >= read_write_ratio);

                // Generate address based on pattern
                case (pattern_type)
                    PATTERN_SEQUENTIAL: begin
                        current_addr <= seq_addr;
                        seq_addr <= seq_addr + (WIDE_BUS_WIDTH / 8);
                        if (seq_addr + (WIDE_BUS_WIDTH / 8) > start_addr + addr_range) begin
                            seq_addr <= start_addr;
                        end
                    end

                    PATTERN_RANDOM: begin
                        current_addr <= start_addr +
                                       (random_val % addr_range) &
                                       ~((WIDE_BUS_WIDTH/8) - 1);  // Align to bus width
                    end

                    PATTERN_BANK_CONFLICT: begin
                        // Force all accesses to same bank
                        current_addr[BANK_ADDR_WIDTH-1:0] <= conflict_bank;
                        current_addr[ADDR_WIDTH-1:BANK_ADDR_WIDTH] <=
                            (random_val[ADDR_WIDTH-BANK_ADDR_WIDTH-1:0] % (addr_range >> BANK_ADDR_WIDTH));
                    end

                    PATTERN_STRIDED: begin
                        current_addr <= seq_addr;
                        seq_addr <= seq_addr + stride;
                        if (seq_addr + stride > start_addr + addr_range) begin
                            seq_addr <= start_addr;
                        end
                    end

                    PATTERN_BURST: begin
                        current_addr <= seq_addr;
                        current_burst_count <= burst_length - 1;
                    end

                    PATTERN_MIXED: begin
                        // Mix of sequential and random
                        if (random_val[0]) begin
                            current_addr <= seq_addr;
                            seq_addr <= seq_addr + (WIDE_BUS_WIDTH / 8);
                        end else begin
                            current_addr <= start_addr +
                                           (random_val % addr_range) &
                                           ~((WIDE_BUS_WIDTH/8) - 1);
                        end
                    end

                    default: begin
                        current_addr <= seq_addr;
                    end
                endcase
            end
        end
    end

    //=========================================================================
    // Data Generation
    //=========================================================================

    // Generate pseudo-random data based on address (for verification)
    always_comb begin
        // Simple pattern: XOR of address with random bits
        for (int i = 0; i < WIDE_BUS_WIDTH/32; i++) begin
            current_data[i*32 +: 32] = {current_addr, 8'h00} ^ (lfsr << i);
        end
    end

    //=========================================================================
    // Transaction Counter
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            transaction_count <= '0;
            write_count <= '0;
            read_count <= '0;
            error_count <= '0;
        end else begin
            if (state == ST_IDLE && start) begin
                transaction_count <= '0;
                write_count <= '0;
                read_count <= '0;
                error_count <= '0;
            end

            // Count completed transactions
            if (state == ST_WRITE_RESP && bvalid && bready) begin
                transaction_count <= transaction_count + 1;
                write_count <= write_count + 1;
                if (bresp != 2'b00) begin
                    error_count <= error_count + 1;
                end
            end

            if (state == ST_READ_DATA && rvalid && rready && rlast) begin
                transaction_count <= transaction_count + 1;
                read_count <= read_count + 1;
                if (rresp != 2'b00) begin
                    error_count <= error_count + 1;
                end
            end
        end
    end

    //=========================================================================
    // AXI Output Generation
    //=========================================================================

    // Write Address Channel
    assign awvalid = (state == ST_WRITE_ADDR);
    assign awaddr = current_addr;
    assign awlen = (pattern_type == PATTERN_BURST) ? burst_length - 1 : 8'h00;
    assign awsize = 3'b110;  // 64 bytes (512 bits)
    assign awburst = 2'b01;  // INCR

    // Write Data Channel
    logic [7:0] write_beat_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_beat_count <= '0;
        end else begin
            if (state == ST_WRITE_ADDR && awvalid && awready) begin
                write_beat_count <= '0;
            end else if (state == ST_WRITE_DATA && wvalid && wready) begin
                write_beat_count <= write_beat_count + 1;
            end
        end
    end

    assign wvalid = (state == ST_WRITE_DATA);
    assign wdata = current_data ^ {WIDE_BUS_WIDTH/32{write_beat_count}};
    assign wstrb = {(WIDE_BUS_WIDTH/8){1'b1}};  // All bytes valid
    assign wlast = (pattern_type == PATTERN_BURST) ?
                   (write_beat_count >= burst_length - 1) : 1'b1;

    // Write Response Channel
    assign bready = (state == ST_WRITE_RESP);

    // Read Address Channel
    assign arvalid = (state == ST_READ_ADDR);
    assign araddr = current_addr;
    assign arlen = (pattern_type == PATTERN_BURST) ? burst_length - 1 : 8'h00;
    assign arsize = 3'b110;
    assign arburst = 2'b01;

    // Read Data Channel
    assign rready = (state == ST_READ_DATA);

    //=========================================================================
    // Status Outputs
    //=========================================================================

    assign done = (state == ST_DONE);
    assign busy = (state != ST_IDLE && state != ST_DONE);
    assign writes_completed = write_count;
    assign reads_completed = read_count;
    assign errors_detected = error_count;

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SIMULATION
    always @(posedge clk) begin
        if (rst_n && state == ST_GEN_ADDR && state_next != ST_DONE) begin
            $display("[%0t] TrafficGen: Transaction %0d - %s addr=0x%06h pattern=%0d",
                     $time, transaction_count,
                     current_is_write ? "WRITE" : "READ",
                     current_addr, pattern_type);
        end

        if (rst_n && state == ST_DONE && state != ST_DONE) begin
            $display("[%0t] TrafficGen: Complete - Writes=%0d Reads=%0d Errors=%0d",
                     $time, write_count, read_count, error_count);
        end
    end
    `endif

endmodule : traffic_generator
