//=============================================================================
// HBM Parameters Package
//
// This package defines all timing parameters, configuration constants, and
// data types used throughout the HBM memory subsystem. Parameters are based
// on typical HBM2/HBM2E specifications scaled for simulation purposes.
//=============================================================================

package hbm_params_pkg;

    //=========================================================================
    // System Configuration Parameters
    //=========================================================================

    // Clock and timing base (assuming 1GHz memory clock for HBM)
    parameter int CLK_PERIOD_NS = 1;  // 1ns clock period = 1GHz

    // Memory organization
    parameter int NUM_BANKS        = 8;      // Number of memory banks
    parameter int NUM_ROWS         = 16384;  // Rows per bank (14-bit address)
    parameter int NUM_COLS         = 64;     // Columns per row (6-bit address)
    parameter int DATA_WIDTH       = 64;     // Base data width per bank
    parameter int WIDE_BUS_WIDTH   = 512;    // Wide bus interface width (HBM-style)
    parameter int BURST_LENGTH     = 4;      // Burst length for read/write

    // Address field widths
    parameter int ROW_ADDR_WIDTH   = $clog2(NUM_ROWS);  // 14 bits
    parameter int COL_ADDR_WIDTH   = $clog2(NUM_COLS);  // 6 bits
    parameter int BANK_ADDR_WIDTH  = $clog2(NUM_BANKS); // 3 bits

    // Total address width
    parameter int ADDR_WIDTH = ROW_ADDR_WIDTH + COL_ADDR_WIDTH + BANK_ADDR_WIDTH;

    //=========================================================================
    // DRAM Timing Parameters (in clock cycles)
    // Based on HBM2 specifications, scaled for simulation
    //=========================================================================

    // Row access timing
    parameter int tRCD  = 14;   // Row to Column Delay (ACT to R/W)
    parameter int tRP   = 14;   // Row Precharge time
    parameter int tRAS  = 33;   // Row Active Strobe (minimum row active time)
    parameter int tRC   = 47;   // Row Cycle time (tRAS + tRP)
    parameter int tRRD  = 4;    // Row to Row Delay (different banks)
    parameter int tFAW  = 16;   // Four Activate Window

    // Column access timing
    parameter int tCAS  = 14;   // Column Access Strobe (CL - CAS Latency)
    parameter int tCCD  = 4;    // Column to Column Delay
    parameter int tWTR  = 8;    // Write to Read turnaround
    parameter int tRTW  = 4;    // Read to Write turnaround
    parameter int tWR   = 15;   // Write Recovery time

    // Data timing
    parameter int tDQSCK = 1;   // DQS output access time from CK
    parameter int tBURST = BURST_LENGTH / 2;  // Burst transfer time (DDR)

    // Refresh timing
    parameter int tRFC   = 350;     // Refresh Cycle time
    parameter int tREFI  = 7800;    // Refresh Interval (7.8us at 1GHz)

    // Power management timing
    parameter int tCKE   = 5;       // CKE minimum pulse width
    parameter int tXP    = 6;       // Exit power-down to valid command
    parameter int tXS    = 10;      // Exit self-refresh to valid command
    parameter int tPD    = 5;       // Power-down entry delay

    //=========================================================================
    // ECC Configuration
    //=========================================================================

    parameter int ECC_DATA_WIDTH    = 64;     // Data width for ECC protection
    parameter int ECC_PARITY_WIDTH  = 8;      // SECDED requires 8 bits for 64-bit data
    parameter int ECC_TOTAL_WIDTH   = ECC_DATA_WIDTH + ECC_PARITY_WIDTH;

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
    function automatic logic [BANK_ADDR_WIDTH-1:0] get_bank_addr(
        input logic [ADDR_WIDTH-1:0] addr
    );
        // Bank bits are at lower portion for interleaving
        return addr[BANK_ADDR_WIDTH-1:0];
    endfunction

    // Extract row address from system address
    function automatic logic [ROW_ADDR_WIDTH-1:0] get_row_addr(
        input logic [ADDR_WIDTH-1:0] addr
    );
        return addr[BANK_ADDR_WIDTH + COL_ADDR_WIDTH +: ROW_ADDR_WIDTH];
    endfunction

    // Extract column address from system address
    function automatic logic [COL_ADDR_WIDTH-1:0] get_col_addr(
        input logic [ADDR_WIDTH-1:0] addr
    );
        return addr[BANK_ADDR_WIDTH +: COL_ADDR_WIDTH];
    endfunction

    // Compose full address from components
    function automatic logic [ADDR_WIDTH-1:0] compose_addr(
        input logic [BANK_ADDR_WIDTH-1:0] bank,
        input logic [ROW_ADDR_WIDTH-1:0]  row,
        input logic [COL_ADDR_WIDTH-1:0]  col
    );
        return {row, col, bank};
    endfunction

endpackage : hbm_params_pkg
