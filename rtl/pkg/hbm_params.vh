//=============================================================================
// HBM Parameters Include File (iverilog-compatible)
//
// This file provides all parameters, types, and functions from hbm_params_pkg
// in an includable format for simulators that don't support SystemVerilog
// packages in module headers (e.g., Icarus Verilog).
//
// Usage: `include "hbm_params.vh"
//=============================================================================

`ifndef HBM_PARAMS_VH
`define HBM_PARAMS_VH

    //=========================================================================
    // System Configuration Parameters
    //=========================================================================

    // Clock and timing base (assuming 1GHz memory clock for HBM)
    localparam integer CLK_PERIOD_NS = 1;  // 1ns clock period = 1GHz

    // Memory organization
    localparam integer NUM_BANKS        = 8;      // Number of memory banks
    localparam integer NUM_ROWS         = 16384;  // Rows per bank (14-bit address)
    localparam integer NUM_COLS         = 64;     // Columns per row (6-bit address)
    localparam integer DATA_WIDTH       = 64;     // Base data width per bank
    localparam integer WIDE_BUS_WIDTH   = 512;    // Wide bus interface width (HBM-style)
    localparam integer BURST_LENGTH     = 4;      // Burst length for read/write

    // Address field widths
    localparam integer ROW_ADDR_WIDTH   = 14;  // $clog2(16384)
    localparam integer COL_ADDR_WIDTH   = 6;   // $clog2(64)
    localparam integer BANK_ADDR_WIDTH  = 3;   // $clog2(8)

    // Total address width
    localparam integer ADDR_WIDTH = ROW_ADDR_WIDTH + COL_ADDR_WIDTH + BANK_ADDR_WIDTH;

    //=========================================================================
    // DRAM Timing Parameters (in clock cycles)
    // Based on HBM2 specifications, scaled for simulation
    //=========================================================================

    // Row access timing
    localparam integer tRCD  = 14;   // Row to Column Delay (ACT to R/W)
    localparam integer tRP   = 14;   // Row Precharge time
    localparam integer tRAS  = 33;   // Row Active Strobe (minimum row active time)
    localparam integer tRC   = 47;   // Row Cycle time (tRAS + tRP)
    localparam integer tRRD  = 4;    // Row to Row Delay (different banks)
    localparam integer tFAW  = 16;   // Four Activate Window

    // Column access timing
    localparam integer tCAS  = 14;   // Column Access Strobe (CL - CAS Latency)
    localparam integer tCCD  = 4;    // Column to Column Delay
    localparam integer tWTR  = 8;    // Write to Read turnaround
    localparam integer tRTW  = 4;    // Read to Write turnaround
    localparam integer tWR   = 15;   // Write Recovery time

    // Data timing
    localparam integer tDQSCK = 1;   // DQS output access time from CK
    localparam integer tBURST = BURST_LENGTH / 2;  // Burst transfer time (DDR)

    // Refresh timing
    localparam integer tRFC   = 350;     // Refresh Cycle time
    localparam integer tREFI  = 7800;    // Refresh Interval (7.8us at 1GHz)

    // Power management timing
    localparam integer tCKE   = 5;       // CKE minimum pulse width
    localparam integer tXP    = 6;       // Exit power-down to valid command
    localparam integer tXS    = 10;      // Exit self-refresh to valid command
    localparam integer tPD    = 5;       // Power-down entry delay

    //=========================================================================
    // ECC Configuration
    //=========================================================================

    localparam integer ECC_DATA_WIDTH    = 64;     // Data width for ECC protection
    localparam integer ECC_PARITY_WIDTH  = 8;      // SECDED requires 8 bits for 64-bit data
    localparam integer ECC_TOTAL_WIDTH   = ECC_DATA_WIDTH + ECC_PARITY_WIDTH;

    //=========================================================================
    // Power States
    //=========================================================================

    typedef enum logic [2:0] {
        PWR_ACTIVE      = 3'b000,  // Fully active, normal operation
        PWR_IDLE        = 3'b001,  // Idle, ready for quick activation
        PWR_STANDBY     = 3'b010,  // Clock gated, faster wake-up
        PWR_POWER_DOWN  = 3'b011,  // Deep power-down, slow wake-up
        PWR_SELF_REFRESH = 3'b100  // Self-refresh mode
    } power_state_t;

    //=========================================================================
    // DRAM Command Types
    //=========================================================================

    typedef enum logic [3:0] {
        CMD_NOP         = 4'b0000,  // No operation
        CMD_ACTIVATE    = 4'b0001,  // Activate row (open row)
        CMD_READ        = 4'b0010,  // Read with auto-precharge option
        CMD_WRITE       = 4'b0011,  // Write with auto-precharge option
        CMD_PRECHARGE   = 4'b0100,  // Precharge (close row)
        CMD_REFRESH     = 4'b0101,  // Auto refresh
        CMD_SELF_REF    = 4'b0110,  // Self refresh enter
        CMD_POWER_DOWN  = 4'b0111,  // Power-down enter
        CMD_WAKE_UP     = 4'b1000,  // Exit from power-down/self-refresh
        CMD_MODE_SET    = 4'b1001   // Mode register set
    } dram_cmd_t;

    //=========================================================================
    // Bank States
    //=========================================================================

    typedef enum logic [2:0] {
        BANK_IDLE       = 3'b000,  // Bank precharged, no active row
        BANK_ACTIVATING = 3'b001,  // Row being activated (tRCD)
        BANK_ACTIVE     = 3'b010,  // Row open, ready for R/W
        BANK_READING    = 3'b011,  // Read in progress
        BANK_WRITING    = 3'b100,  // Write in progress
        BANK_PRECHARGING= 3'b101,  // Precharge in progress (tRP)
        BANK_REFRESHING = 3'b110   // Refresh in progress
    } bank_state_t;

    //=========================================================================
    // Request Types
    //=========================================================================

    typedef enum logic [1:0] {
        REQ_READ        = 2'b00,
        REQ_WRITE       = 2'b01,
        REQ_REFRESH     = 2'b10,
        REQ_NOP         = 2'b11
    } request_type_t;

    //=========================================================================
    // Memory Request Structure
    //=========================================================================

    typedef struct packed {
        logic                          valid;
        request_type_t                 req_type;
        logic [BANK_ADDR_WIDTH-1:0]    bank_addr;
        logic [ROW_ADDR_WIDTH-1:0]     row_addr;
        logic [COL_ADDR_WIDTH-1:0]     col_addr;
        logic [DATA_WIDTH-1:0]         write_data;
        logic [7:0]                    tag;  // Request ID for tracking
    } mem_request_t;

    //=========================================================================
    // Memory Response Structure
    //=========================================================================

    typedef struct packed {
        logic                          valid;
        logic                          error;      // ECC uncorrectable error
        logic                          corrected;  // ECC corrected error
        logic [DATA_WIDTH-1:0]         read_data;
        logic [7:0]                    tag;  // Request ID for tracking
    } mem_response_t;

    //=========================================================================
    // Performance Counter Structure
    //=========================================================================

    typedef struct packed {
        logic [31:0] total_reads;
        logic [31:0] total_writes;
        logic [31:0] row_hits;
        logic [31:0] row_misses;
        logic [31:0] bank_conflicts;
        logic [63:0] total_latency_cycles;
        logic [31:0] ecc_corrections;
        logic [31:0] ecc_errors;
        logic [31:0] refresh_cycles;
        logic [31:0] power_down_cycles;
    } perf_counters_t;

    //=========================================================================
    // Utility Functions
    //=========================================================================

    // Extract bank address from system address
    function automatic [BANK_ADDR_WIDTH-1:0] get_bank_addr(
        input [ADDR_WIDTH-1:0] addr
    );
        // Bank bits are at lower portion for interleaving
        get_bank_addr = addr[BANK_ADDR_WIDTH-1:0];
    endfunction

    // Extract row address from system address
    function automatic [ROW_ADDR_WIDTH-1:0] get_row_addr(
        input [ADDR_WIDTH-1:0] addr
    );
        get_row_addr = addr[BANK_ADDR_WIDTH + COL_ADDR_WIDTH +: ROW_ADDR_WIDTH];
    endfunction

    // Extract column address from system address
    function automatic [COL_ADDR_WIDTH-1:0] get_col_addr(
        input [ADDR_WIDTH-1:0] addr
    );
        get_col_addr = addr[BANK_ADDR_WIDTH +: COL_ADDR_WIDTH];
    endfunction

    // Compose full address from components
    function automatic [ADDR_WIDTH-1:0] compose_addr(
        input [BANK_ADDR_WIDTH-1:0] bank,
        input [ROW_ADDR_WIDTH-1:0]  row,
        input [COL_ADDR_WIDTH-1:0]  col
    );
        compose_addr = {row, col, bank};
    endfunction

`endif // HBM_PARAMS_VH
