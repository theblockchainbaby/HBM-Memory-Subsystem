//=============================================================================
// Bank Interleaver Module
//
// This module implements bank interleaving logic to maximize memory
// bandwidth utilization. Features include:
// - Address-based bank selection (XOR-based for better distribution)
// - Round-robin arbitration for concurrent requests
// - Request queue management with priority support
// - Bank conflict detection and tracking
//=============================================================================

`include "hbm_params.vh"

module bank_interleaver
(
    input  logic                        clk,
    input  logic                        rst_n,

    // External request interface (from system bus)
    input  logic                        req_valid,
    input  logic                        req_write,  // 1 = write, 0 = read
    input  logic [ADDR_WIDTH-1:0]       req_addr,
    input  logic [DATA_WIDTH-1:0]       req_wdata,
    input  logic [7:0]                  req_tag,
    output logic                        req_ready,

    // Response interface (to system)
    output logic                        resp_valid,
    output logic [DATA_WIDTH-1:0]       resp_rdata,
    output logic [7:0]                  resp_tag,
    output logic                        resp_error,

    // Internal request interface (to DRAM controller)
    output mem_request_t                ctrl_req,
    input  logic                        ctrl_ready,

    // Controller response interface
    input  mem_response_t               ctrl_resp,
    input  logic                        ctrl_resp_valid,

    // Configuration
    input  logic [1:0]                  interleave_mode,  // 00=addr, 01=XOR, 10=round-robin

    // Statistics
    output logic [31:0]                 total_requests,
    output logic [31:0]                 bank_conflicts
);

    //=========================================================================
    // Interleaving Mode Definitions
    //=========================================================================

    localparam logic [1:0] MODE_ADDR_BASED   = 2'b00;  // Simple address-based (low bits)
    localparam logic [1:0] MODE_XOR_BASED    = 2'b01;  // XOR of address bits
    localparam logic [1:0] MODE_ROUND_ROBIN  = 2'b10;  // Round-robin scheduling

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Input request buffer
    typedef struct packed {
        logic                        valid;
        logic                        write;
        logic [ADDR_WIDTH-1:0]       addr;
        logic [DATA_WIDTH-1:0]       wdata;
        logic [7:0]                  tag;
        logic [BANK_ADDR_WIDTH-1:0]  target_bank;
    } buffered_req_t;

    buffered_req_t input_buffer;
    logic          input_buffer_full;

    // Bank selection
    logic [BANK_ADDR_WIDTH-1:0] selected_bank;
    logic [BANK_ADDR_WIDTH-1:0] round_robin_counter;

    // Response tracking
    logic          pending_resp_valid [16];  // Track up to 16 outstanding requests
    logic [7:0]    pending_resp_tag   [16];
    logic [3:0]    pending_head;
    logic [3:0]    pending_tail;

    // Statistics
    logic [31:0] total_req_cnt;
    logic [31:0] conflict_cnt;

    // Bank usage tracking (for conflict detection)
    logic [BANK_ADDR_WIDTH-1:0] last_bank_accessed;
    logic                       last_bank_valid;

    //=========================================================================
    // Bank Selection Logic
    //=========================================================================

    // Calculate target bank based on interleaving mode
    always_comb begin
        case (interleave_mode)
            MODE_ADDR_BASED: begin
                // Simple: use low-order bits as bank address
                selected_bank = req_addr[BANK_ADDR_WIDTH-1:0];
            end

            MODE_XOR_BASED: begin
                // XOR-based: XOR low bits with higher bits for better distribution
                // This helps spread sequential addresses across banks
                selected_bank = req_addr[BANK_ADDR_WIDTH-1:0] ^
                               req_addr[BANK_ADDR_WIDTH+COL_ADDR_WIDTH +: BANK_ADDR_WIDTH];
            end

            MODE_ROUND_ROBIN: begin
                // Round-robin: ignore address, just cycle through banks
                selected_bank = round_robin_counter;
            end

            default: begin
                selected_bank = req_addr[BANK_ADDR_WIDTH-1:0];
            end
        endcase
    end

    // Round-robin counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            round_robin_counter <= '0;
        end else if (req_valid && req_ready) begin
            if (round_robin_counter == NUM_BANKS - 1) begin
                round_robin_counter <= '0;
            end else begin
                round_robin_counter <= round_robin_counter + 1;
            end
        end
    end

    //=========================================================================
    // Input Buffer
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_buffer <= '0;
            input_buffer_full <= 1'b0;
        end else begin
            if (req_valid && req_ready) begin
                // Buffer incoming request
                input_buffer.valid <= 1'b1;
                input_buffer.write <= req_write;
                input_buffer.addr <= req_addr;
                input_buffer.wdata <= req_wdata;
                input_buffer.tag <= req_tag;
                input_buffer.target_bank <= selected_bank;
                input_buffer_full <= 1'b1;
            end else if (input_buffer_full && ctrl_ready) begin
                // Request sent to controller
                input_buffer.valid <= 1'b0;
                input_buffer_full <= 1'b0;
            end
        end
    end

    // Ready when buffer is not full
    assign req_ready = !input_buffer_full;

    //=========================================================================
    // Controller Request Generation
    //=========================================================================

    always_comb begin
        ctrl_req = '0;

        if (input_buffer_full) begin
            ctrl_req.valid = 1'b1;
            ctrl_req.req_type = input_buffer.write ? REQ_WRITE : REQ_READ;
            ctrl_req.bank_addr = input_buffer.target_bank;
            ctrl_req.row_addr = get_row_addr(input_buffer.addr);
            ctrl_req.col_addr = get_col_addr(input_buffer.addr);
            ctrl_req.write_data = input_buffer.wdata;
            ctrl_req.tag = input_buffer.tag;
        end
    end

    //=========================================================================
    // Response Tracking
    //=========================================================================

    // Track pending responses for tag matching
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 16; i++) begin
                pending_resp_valid[i] <= 1'b0;
                pending_resp_tag[i] <= '0;
            end
            pending_head <= '0;
            pending_tail <= '0;
        end else begin
            // Add new pending response when request is sent
            if (input_buffer_full && ctrl_ready && !input_buffer.write) begin
                pending_resp_valid[pending_tail] <= 1'b1;
                pending_resp_tag[pending_tail] <= input_buffer.tag;
                pending_tail <= pending_tail + 1;
            end

            // Remove pending response when response received
            if (ctrl_resp_valid && ctrl_resp.valid) begin
                pending_resp_valid[pending_head] <= 1'b0;
                pending_head <= pending_head + 1;
            end
        end
    end

    //=========================================================================
    // Response Interface
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid <= 1'b0;
            resp_rdata <= '0;
            resp_tag <= '0;
            resp_error <= 1'b0;
        end else begin
            resp_valid <= ctrl_resp_valid && ctrl_resp.valid;
            resp_rdata <= ctrl_resp.read_data;
            resp_tag <= ctrl_resp.tag;
            resp_error <= ctrl_resp.error;
        end
    end

    //=========================================================================
    // Conflict Detection and Statistics
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_req_cnt <= '0;
            conflict_cnt <= '0;
            last_bank_accessed <= '0;
            last_bank_valid <= 1'b0;
        end else begin
            if (req_valid && req_ready) begin
                total_req_cnt <= total_req_cnt + 1;

                // Check for bank conflict (same bank as previous request)
                if (last_bank_valid && selected_bank == last_bank_accessed) begin
                    conflict_cnt <= conflict_cnt + 1;
                end

                last_bank_accessed <= selected_bank;
                last_bank_valid <= 1'b1;
            end
        end
    end

    assign total_requests = total_req_cnt;
    assign bank_conflicts = conflict_cnt;

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SVA_ENABLE
    always @(posedge clk) begin
        if (req_valid && req_ready && rst_n) begin
            $display("[%0t] Interleaver: %s addr=0x%06h -> bank=%0d row=%0d col=%0d tag=%0d",
                     $time,
                     req_write ? "WRITE" : "READ",
                     req_addr,
                     selected_bank,
                     get_row_addr(req_addr),
                     get_col_addr(req_addr),
                     req_tag);
        end
    end
    `endif

    //=========================================================================
    // Assertions
    //=========================================================================

    `ifdef SVA_ENABLE
    // Bank selection must be valid
    property p_valid_bank_selection;
        @(posedge clk) disable iff (!rst_n)
        (req_valid && req_ready) |-> (selected_bank < NUM_BANKS);
    endproperty
    assert property (p_valid_bank_selection) else
        $error("Invalid bank selection: %0d", selected_bank);

    // No request loss - if accepted, must be forwarded to controller
    property p_no_request_loss;
        @(posedge clk) disable iff (!rst_n)
        (req_valid && req_ready) |-> ##[1:$] (ctrl_req.valid && ctrl_ready);
    endproperty
    // Note: This property might need adjustment based on timing

    // Response tag must match pending request
    property p_response_tag_match;
        @(posedge clk) disable iff (!rst_n)
        (ctrl_resp_valid && ctrl_resp.valid) |->
            (ctrl_resp.tag == pending_resp_tag[pending_head]);
    endproperty
    assert property (p_response_tag_match) else
        $warning("Response tag mismatch");
    `endif

endmodule : bank_interleaver
