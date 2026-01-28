//=============================================================================
// Wide Bus Interface Module
//
// This module implements a high-bandwidth wide bus interface typical of HBM:
// - Aggregates data from multiple memory banks (512-bit wide bus)
// - Implements burst mode operation
// - Handles data alignment and lane management
// - Provides AXI-like interface to system
//=============================================================================

module wide_bus_interface
    import hbm_params_pkg::*;
(
    input  logic                        clk,
    input  logic                        rst_n,

    // AXI-like System Interface (512-bit wide)
    // Write Address Channel
    input  logic                        awvalid,
    output logic                        awready,
    input  logic [ADDR_WIDTH-1:0]       awaddr,
    input  logic [7:0]                  awlen,      // Burst length - 1
    input  logic [2:0]                  awsize,     // Beat size
    input  logic [1:0]                  awburst,    // Burst type

    // Write Data Channel
    input  logic                        wvalid,
    output logic                        wready,
    input  logic [WIDE_BUS_WIDTH-1:0]   wdata,
    input  logic [WIDE_BUS_WIDTH/8-1:0] wstrb,
    input  logic                        wlast,

    // Write Response Channel
    output logic                        bvalid,
    input  logic                        bready,
    output logic [1:0]                  bresp,

    // Read Address Channel
    input  logic                        arvalid,
    output logic                        arready,
    input  logic [ADDR_WIDTH-1:0]       araddr,
    input  logic [7:0]                  arlen,
    input  logic [2:0]                  arsize,
    input  logic [1:0]                  arburst,

    // Read Data Channel
    output logic                        rvalid,
    input  logic                        rready,
    output logic [WIDE_BUS_WIDTH-1:0]   rdata,
    output logic [1:0]                  rresp,
    output logic                        rlast,

    // Memory-side Interface (to bank interleaver)
    output logic                        mem_req_valid,
    input  logic                        mem_req_ready,
    output logic                        mem_req_write,
    output logic [ADDR_WIDTH-1:0]       mem_req_addr,
    output logic [DATA_WIDTH-1:0]       mem_req_wdata,
    output logic [7:0]                  mem_req_tag,

    // Memory Response Interface
    input  logic                        mem_resp_valid,
    input  logic [DATA_WIDTH-1:0]       mem_resp_rdata,
    input  logic [7:0]                  mem_resp_tag,
    input  logic                        mem_resp_error,

    // Statistics
    output logic [31:0]                 total_bursts,
    output logic [31:0]                 total_beats,
    output logic [63:0]                 total_bytes_transferred
);

    //=========================================================================
    // Local Parameters
    //=========================================================================

    localparam int LANES = WIDE_BUS_WIDTH / DATA_WIDTH;  // 512/64 = 8 lanes
    localparam int LANE_WIDTH = DATA_WIDTH;

    // Burst types
    localparam logic [1:0] BURST_FIXED = 2'b00;
    localparam logic [1:0] BURST_INCR  = 2'b01;
    localparam logic [1:0] BURST_WRAP  = 2'b10;

    // Response codes
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    //=========================================================================
    // Internal Types
    //=========================================================================

    typedef enum logic [2:0] {
        WR_IDLE,
        WR_ADDR,
        WR_DATA,
        WR_ISSUE,
        WR_RESP
    } write_state_t;

    typedef enum logic [2:0] {
        RD_IDLE,
        RD_ADDR,
        RD_ISSUE,
        RD_COLLECT,
        RD_DATA
    } read_state_t;

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Write state machine
    write_state_t wr_state, wr_state_next;
    logic [ADDR_WIDTH-1:0] wr_addr_reg;
    logic [7:0]            wr_len_reg;
    logic [7:0]            wr_beat_count;
    logic [2:0]            wr_size_reg;
    logic [1:0]            wr_burst_reg;
    logic [WIDE_BUS_WIDTH-1:0] wr_data_buffer;

    // Write data decomposition
    logic [DATA_WIDTH-1:0] wr_lane_data [LANES];
    logic [2:0]            wr_lane_idx;
    logic [7:0]            wr_tag_counter;

    // Read state machine
    read_state_t rd_state, rd_state_next;
    logic [ADDR_WIDTH-1:0] rd_addr_reg;
    logic [7:0]            rd_len_reg;
    logic [7:0]            rd_beat_count;
    logic [2:0]            rd_size_reg;
    logic [1:0]            rd_burst_reg;

    // Read data collection
    logic [DATA_WIDTH-1:0] rd_lane_data [LANES];
    logic [LANES-1:0]      rd_lane_valid;
    logic [2:0]            rd_lane_idx;
    logic [7:0]            rd_tag_counter;
    logic [WIDE_BUS_WIDTH-1:0] rd_data_buffer;
    logic                  rd_data_ready;

    // Outstanding request tracking
    logic [7:0]            outstanding_reads;
    logic [7:0]            outstanding_writes;

    // Statistics
    logic [31:0] burst_cnt;
    logic [31:0] beat_cnt;
    logic [63:0] bytes_cnt;

    //=========================================================================
    // Write Address Channel
    //=========================================================================

    assign awready = (wr_state == WR_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr_reg <= '0;
            wr_len_reg <= '0;
            wr_size_reg <= '0;
            wr_burst_reg <= '0;
        end else if (awvalid && awready) begin
            wr_addr_reg <= awaddr;
            wr_len_reg <= awlen;
            wr_size_reg <= awsize;
            wr_burst_reg <= awburst;
        end
    end

    //=========================================================================
    // Write Data Channel
    //=========================================================================

    assign wready = (wr_state == WR_DATA);

    // Decompose wide data into lanes
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            wr_lane_data[i] = wdata[i*LANE_WIDTH +: LANE_WIDTH];
        end
    end

    //=========================================================================
    // Write State Machine
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state <= WR_IDLE;
        end else begin
            wr_state <= wr_state_next;
        end
    end

    always_comb begin
        wr_state_next = wr_state;

        case (wr_state)
            WR_IDLE: begin
                if (awvalid) begin
                    wr_state_next = WR_ADDR;
                end
            end

            WR_ADDR: begin
                wr_state_next = WR_DATA;
            end

            WR_DATA: begin
                if (wvalid) begin
                    wr_state_next = WR_ISSUE;
                end
            end

            WR_ISSUE: begin
                // Issue all lane writes
                if (wr_lane_idx == LANES - 1 && mem_req_ready) begin
                    if (wlast || wr_beat_count >= wr_len_reg) begin
                        wr_state_next = WR_RESP;
                    end else begin
                        wr_state_next = WR_DATA;
                    end
                end
            end

            WR_RESP: begin
                if (bready) begin
                    wr_state_next = WR_IDLE;
                end
            end

            default: wr_state_next = WR_IDLE;
        endcase
    end

    // Write lane index and beat tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_lane_idx <= '0;
            wr_beat_count <= '0;
            wr_data_buffer <= '0;
        end else begin
            case (wr_state)
                WR_ADDR: begin
                    wr_lane_idx <= '0;
                    wr_beat_count <= '0;
                end

                WR_DATA: begin
                    if (wvalid) begin
                        wr_data_buffer <= wdata;
                        wr_lane_idx <= '0;
                    end
                end

                WR_ISSUE: begin
                    if (mem_req_ready) begin
                        if (wr_lane_idx < LANES - 1) begin
                            wr_lane_idx <= wr_lane_idx + 1;
                        end else begin
                            wr_beat_count <= wr_beat_count + 1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    //=========================================================================
    // Write Response Channel
    //=========================================================================

    assign bvalid = (wr_state == WR_RESP);
    assign bresp = RESP_OKAY;  // Always OK for now

    //=========================================================================
    // Read Address Channel
    //=========================================================================

    assign arready = (rd_state == RD_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_reg <= '0;
            rd_len_reg <= '0;
            rd_size_reg <= '0;
            rd_burst_reg <= '0;
        end else if (arvalid && arready) begin
            rd_addr_reg <= araddr;
            rd_len_reg <= arlen;
            rd_size_reg <= arsize;
            rd_burst_reg <= arburst;
        end
    end

    //=========================================================================
    // Read State Machine
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state <= RD_IDLE;
        end else begin
            rd_state <= rd_state_next;
        end
    end

    always_comb begin
        rd_state_next = rd_state;

        case (rd_state)
            RD_IDLE: begin
                if (arvalid) begin
                    rd_state_next = RD_ADDR;
                end
            end

            RD_ADDR: begin
                rd_state_next = RD_ISSUE;
            end

            RD_ISSUE: begin
                // Issue all lane reads
                if (rd_lane_idx == LANES - 1 && mem_req_ready) begin
                    rd_state_next = RD_COLLECT;
                end
            end

            RD_COLLECT: begin
                // Wait for all lane data to arrive
                if (&rd_lane_valid) begin
                    rd_state_next = RD_DATA;
                end
            end

            RD_DATA: begin
                if (rready) begin
                    if (rd_beat_count >= rd_len_reg) begin
                        rd_state_next = RD_IDLE;
                    end else begin
                        rd_state_next = RD_ISSUE;
                    end
                end
            end

            default: rd_state_next = RD_IDLE;
        endcase
    end

    // Read lane index and beat tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_lane_idx <= '0;
            rd_beat_count <= '0;
            rd_lane_valid <= '0;
        end else begin
            case (rd_state)
                RD_ADDR: begin
                    rd_lane_idx <= '0;
                    rd_beat_count <= '0;
                    rd_lane_valid <= '0;
                end

                RD_ISSUE: begin
                    if (mem_req_ready) begin
                        if (rd_lane_idx < LANES - 1) begin
                            rd_lane_idx <= rd_lane_idx + 1;
                        end
                    end
                end

                RD_COLLECT: begin
                    // Mark lanes as valid when data arrives
                    if (mem_resp_valid) begin
                        rd_lane_valid[mem_resp_tag[2:0]] <= 1'b1;
                    end
                end

                RD_DATA: begin
                    if (rready) begin
                        rd_beat_count <= rd_beat_count + 1;
                        rd_lane_valid <= '0;
                        rd_lane_idx <= '0;
                    end
                end

                default: ;
            endcase
        end
    end

    // Collect read data from lanes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < LANES; i++) begin
                rd_lane_data[i] <= '0;
            end
        end else if (rd_state == RD_COLLECT && mem_resp_valid) begin
            rd_lane_data[mem_resp_tag[2:0]] <= mem_resp_rdata;
        end
    end

    // Assemble wide read data
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            rd_data_buffer[i*LANE_WIDTH +: LANE_WIDTH] = rd_lane_data[i];
        end
    end

    //=========================================================================
    // Read Data Channel
    //=========================================================================

    assign rvalid = (rd_state == RD_DATA);
    assign rdata = rd_data_buffer;
    assign rresp = RESP_OKAY;
    assign rlast = (rd_beat_count >= rd_len_reg);

    //=========================================================================
    // Memory Request Interface
    //=========================================================================

    // Tag counter for request tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_tag_counter <= '0;
            rd_tag_counter <= '0;
        end else begin
            if (wr_state == WR_ISSUE && mem_req_ready) begin
                wr_tag_counter <= wr_tag_counter + 1;
            end
            if (rd_state == RD_ISSUE && mem_req_ready) begin
                rd_tag_counter <= rd_tag_counter + 1;
            end
        end
    end

    // Generate memory requests
    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = '0;
        mem_req_wdata = '0;
        mem_req_tag = '0;

        if (wr_state == WR_ISSUE) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            // Address increments by lane
            mem_req_addr = wr_addr_reg + (wr_beat_count * LANES + wr_lane_idx) * (DATA_WIDTH/8);
            mem_req_wdata = wr_data_buffer[wr_lane_idx * LANE_WIDTH +: LANE_WIDTH];
            mem_req_tag = {wr_tag_counter[4:0], wr_lane_idx};
        end else if (rd_state == RD_ISSUE) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b0;
            mem_req_addr = rd_addr_reg + (rd_beat_count * LANES + rd_lane_idx) * (DATA_WIDTH/8);
            mem_req_wdata = '0;
            mem_req_tag = {rd_tag_counter[4:0], rd_lane_idx};  // Lane ID in lower bits
        end
    end

    //=========================================================================
    // Statistics
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_cnt <= '0;
            beat_cnt <= '0;
            bytes_cnt <= '0;
        end else begin
            // Count bursts
            if ((wr_state == WR_ADDR) || (rd_state == RD_ADDR)) begin
                burst_cnt <= burst_cnt + 1;
            end

            // Count beats
            if ((wr_state == WR_DATA && wvalid) || (rd_state == RD_DATA && rready)) begin
                beat_cnt <= beat_cnt + 1;
                bytes_cnt <= bytes_cnt + WIDE_BUS_WIDTH/8;
            end
        end
    end

    assign total_bursts = burst_cnt;
    assign total_beats = beat_cnt;
    assign total_bytes_transferred = bytes_cnt;

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SVA_ENABLE
    always @(posedge clk) begin
        if (rst_n) begin
            if (awvalid && awready) begin
                $display("[%0t] WideBus: Write burst addr=0x%06h len=%0d",
                         $time, awaddr, awlen + 1);
            end
            if (arvalid && arready) begin
                $display("[%0t] WideBus: Read burst addr=0x%06h len=%0d",
                         $time, araddr, arlen + 1);
            end
        end
    end
    `endif

    //=========================================================================
    // Assertions
    //=========================================================================

    `ifdef SVA_ENABLE
    // Write data must be valid during write state
    property p_wvalid_in_wr_data;
        @(posedge clk) disable iff (!rst_n)
        (wr_state == WR_DATA) |-> ##[0:100] wvalid;
    endproperty

    // Read response must complete
    property p_read_completes;
        @(posedge clk) disable iff (!rst_n)
        (rd_state == RD_ISSUE) |-> ##[1:1000] (rd_state == RD_DATA || rd_state == RD_IDLE);
    endproperty
    `endif

endmodule : wide_bus_interface
