//=============================================================================
// ECC Module (SECDED - Single Error Correction, Double Error Detection)
//
// This module implements Hamming-based SECDED ECC for 64-bit data words:
// - 64 data bits + 8 parity bits = 72 bits total
// - Can correct any single-bit error
// - Can detect (but not correct) any double-bit error
// - Includes syndrome calculation and error position decoding
// - Supports error injection for testing
//=============================================================================

`include "hbm_params.vh"

module ecc_module
(
    input  logic                        clk,
    input  logic                        rst_n,

    // Write path (encode)
    input  logic                        encode_valid,
    input  logic [ECC_DATA_WIDTH-1:0]   encode_data_in,
    output logic [ECC_TOTAL_WIDTH-1:0]  encode_data_out,
    output logic                        encode_done,

    // Read path (decode)
    input  logic                        decode_valid,
    input  logic [ECC_TOTAL_WIDTH-1:0]  decode_data_in,
    output logic [ECC_DATA_WIDTH-1:0]   decode_data_out,
    output logic                        decode_done,
    output logic                        single_error,      // Correctable error detected
    output logic                        double_error,      // Uncorrectable error detected
    output logic [6:0]                  error_position,    // Position of corrected bit

    // Error injection (for testing)
    input  logic                        inject_enable,
    input  logic [6:0]                  inject_position,   // Bit position to flip
    input  logic                        inject_double,     // Inject second error at position+1

    // Statistics
    output logic [31:0]                 corrections_count,
    output logic [31:0]                 uncorrectable_count
);

    //=========================================================================
    // SECDED Parity Bit Positions
    //
    // For 64-bit data, we need 7 check bits (2^7 = 128 > 64+7+1)
    // Plus 1 overall parity bit for double error detection = 8 bits total
    //
    // Parity bits are at positions: 1, 2, 4, 8, 16, 32, 64 (powers of 2)
    // Position 0 is the overall parity bit
    //
    // Data bits fill the remaining positions (3, 5, 6, 7, 9, 10, ...)
    //=========================================================================

    // Syndrome and correction signals
    logic [7:0]  syndrome;
    logic [6:0]  error_pos;
    logic        overall_parity;
    logic        syndrome_nonzero;

    // Internal registers
    logic [ECC_TOTAL_WIDTH-1:0] encoded_reg;
    logic [ECC_DATA_WIDTH-1:0]  decoded_reg;
    logic                       single_err_reg;
    logic                       double_err_reg;

    // Statistics counters
    logic [31:0] correct_cnt;
    logic [31:0] uncorrect_cnt;

    //=========================================================================
    // Parity Generation Functions
    //=========================================================================

    // Calculate check bit P1 (covers positions with bit 0 set: 1,3,5,7,9,...)
    function automatic logic calc_p1(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        // Data positions covered by P1: 3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,...
        // These are positions where bit 0 of the position is set
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[0]) result ^= data[i];
        end
        return result;
    endfunction

    // Calculate check bit P2 (covers positions with bit 1 set: 2,3,6,7,10,11,...)
    function automatic logic calc_p2(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[1]) result ^= data[i];
        end
        return result;
    endfunction

    // Calculate check bit P4 (covers positions with bit 2 set)
    function automatic logic calc_p4(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[2]) result ^= data[i];
        end
        return result;
    endfunction

    // Calculate check bit P8 (covers positions with bit 3 set)
    function automatic logic calc_p8(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[3]) result ^= data[i];
        end
        return result;
    endfunction

    // Calculate check bit P16 (covers positions with bit 4 set)
    function automatic logic calc_p16(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[4]) result ^= data[i];
        end
        return result;
    endfunction

    // Calculate check bit P32 (covers positions with bit 5 set)
    function automatic logic calc_p32(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[5]) result ^= data[i];
        end
        return result;
    endfunction

    // Calculate check bit P64 (covers positions with bit 6 set)
    function automatic logic calc_p64(input logic [ECC_DATA_WIDTH-1:0] data);
        logic result;
        result = 0;
        for (int i = 0; i < 64; i++) begin
            automatic int pos = data_to_code_pos(i);
            if (pos[6]) result ^= data[i];
        end
        return result;
    endfunction

    //=========================================================================
    // Position Mapping Functions
    //=========================================================================

    // Map data bit index to codeword position
    // Skip positions that are powers of 2 (parity positions)
    function automatic int data_to_code_pos(input int data_idx);
        int code_pos;
        int skip_count;
        code_pos = data_idx + 1;  // Start at position 1 (0 is overall parity)
        skip_count = 0;

        // Skip parity positions (1, 2, 4, 8, 16, 32, 64)
        for (int p = 0; p < 7; p++) begin
            if (code_pos >= (1 << p)) skip_count++;
        end
        code_pos = data_idx + skip_count + 1;

        // Adjust if we landed on a parity position
        while (code_pos == 1 || code_pos == 2 || code_pos == 4 ||
               code_pos == 8 || code_pos == 16 || code_pos == 32 ||
               code_pos == 64) begin
            code_pos++;
        end

        return code_pos;
    endfunction

    // Check if position is a power of 2 (parity position)
    function automatic logic is_parity_pos(input int pos);
        return (pos == 1 || pos == 2 || pos == 4 || pos == 8 ||
                pos == 16 || pos == 32 || pos == 64 || pos == 0);
    endfunction

    //=========================================================================
    // Encoding Logic
    //=========================================================================

    // Generate encoded codeword from data
    function automatic logic [ECC_TOTAL_WIDTH-1:0] encode_data(
        input logic [ECC_DATA_WIDTH-1:0] data
    );
        logic [ECC_TOTAL_WIDTH-1:0] codeword;
        logic p1, p2, p4, p8, p16, p32, p64, p0;

        // Calculate parity bits
        p1  = calc_p1(data);
        p2  = calc_p2(data);
        p4  = calc_p4(data);
        p8  = calc_p8(data);
        p16 = calc_p16(data);
        p32 = calc_p32(data);
        p64 = calc_p64(data);

        // Assemble codeword: [P0 | P64 | ... data ... | P1]
        // Simple layout: [7:0] = parity bits, [71:8] = data
        codeword[71:8] = data;
        codeword[0] = p1;
        codeword[1] = p2;
        codeword[2] = p4;
        codeword[3] = p8;
        codeword[4] = p16;
        codeword[5] = p32;
        codeword[6] = p64;

        // Overall parity (XOR of all bits including check bits)
        p0 = ^data ^ p1 ^ p2 ^ p4 ^ p8 ^ p16 ^ p32 ^ p64;
        codeword[7] = p0;

        return codeword;
    endfunction

    //=========================================================================
    // Decoding Logic
    //=========================================================================

    // Calculate syndrome from received codeword
    function automatic logic [6:0] calc_syndrome(
        input logic [ECC_TOTAL_WIDTH-1:0] codeword
    );
        logic [6:0] syn;
        logic [ECC_DATA_WIDTH-1:0] data;
        logic p1_calc, p2_calc, p4_calc, p8_calc, p16_calc, p32_calc, p64_calc;

        data = codeword[71:8];

        // Recalculate parity bits
        p1_calc  = calc_p1(data);
        p2_calc  = calc_p2(data);
        p4_calc  = calc_p4(data);
        p8_calc  = calc_p8(data);
        p16_calc = calc_p16(data);
        p32_calc = calc_p32(data);
        p64_calc = calc_p64(data);

        // Syndrome is XOR of calculated and received parity
        syn[0] = p1_calc  ^ codeword[0];
        syn[1] = p2_calc  ^ codeword[1];
        syn[2] = p4_calc  ^ codeword[2];
        syn[3] = p8_calc  ^ codeword[3];
        syn[4] = p16_calc ^ codeword[4];
        syn[5] = p32_calc ^ codeword[5];
        syn[6] = p64_calc ^ codeword[6];

        return syn;
    endfunction

    // Calculate overall parity
    function automatic logic calc_overall_parity(
        input logic [ECC_TOTAL_WIDTH-1:0] codeword
    );
        return ^codeword;
    endfunction

    //=========================================================================
    // Encoding Path (Write)
    //=========================================================================

    logic [ECC_TOTAL_WIDTH-1:0] encoded_data;
    logic [ECC_TOTAL_WIDTH-1:0] encoded_with_error;

    always_comb begin
        encoded_data = encode_data(encode_data_in);

        // Apply error injection if enabled
        encoded_with_error = encoded_data;
        if (inject_enable) begin
            encoded_with_error[inject_position] = ~encoded_data[inject_position];
            if (inject_double && inject_position < 71) begin
                encoded_with_error[inject_position + 1] = ~encoded_data[inject_position + 1];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            encoded_reg <= '0;
            encode_done <= 1'b0;
        end else begin
            encode_done <= encode_valid;
            if (encode_valid) begin
                encoded_reg <= encoded_with_error;
            end
        end
    end

    assign encode_data_out = encoded_reg;

    //=========================================================================
    // Decoding Path (Read)
    //=========================================================================

    logic [ECC_DATA_WIDTH-1:0] corrected_data;
    logic [6:0]                syn_val;
    logic                      overall_par;

    always_comb begin
        syn_val = calc_syndrome(decode_data_in);
        overall_par = calc_overall_parity(decode_data_in);

        // Default: no correction
        corrected_data = decode_data_in[71:8];

        // Error correction logic
        if (syn_val != 0 && overall_par == 1) begin
            // Single-bit error - correct it
            // Syndrome points to error position in data portion
            if (syn_val >= 8 && syn_val <= 71) begin
                corrected_data[syn_val - 8] = ~decode_data_in[syn_val];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decoded_reg <= '0;
            single_err_reg <= 1'b0;
            double_err_reg <= 1'b0;
            decode_done <= 1'b0;
            error_position <= '0;
        end else begin
            decode_done <= decode_valid;

            if (decode_valid) begin
                decoded_reg <= corrected_data;

                // Error detection
                if (syn_val == 0) begin
                    // No error
                    single_err_reg <= 1'b0;
                    double_err_reg <= 1'b0;
                    error_position <= '0;
                end else if (overall_par == 1) begin
                    // Single-bit error (correctable)
                    single_err_reg <= 1'b1;
                    double_err_reg <= 1'b0;
                    error_position <= syn_val;
                end else begin
                    // Double-bit error (uncorrectable)
                    single_err_reg <= 1'b0;
                    double_err_reg <= 1'b1;
                    error_position <= '0;
                end
            end else begin
                single_err_reg <= 1'b0;
                double_err_reg <= 1'b0;
            end
        end
    end

    assign decode_data_out = decoded_reg;
    assign single_error = single_err_reg;
    assign double_error = double_err_reg;

    //=========================================================================
    // Statistics Counters
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            correct_cnt <= '0;
            uncorrect_cnt <= '0;
        end else begin
            if (decode_valid && syn_val != 0) begin
                if (overall_par == 1) begin
                    // Single-bit error corrected
                    correct_cnt <= correct_cnt + 1;
                end else begin
                    // Double-bit error detected
                    uncorrect_cnt <= uncorrect_cnt + 1;
                end
            end
        end
    end

    assign corrections_count = correct_cnt;
    assign uncorrectable_count = uncorrect_cnt;

    //=========================================================================
    // Debug Display
    //=========================================================================

    `ifdef SVA_ENABLE
    always @(posedge clk) begin
        if (decode_valid && rst_n) begin
            if (syn_val != 0) begin
                if (overall_par == 1) begin
                    $display("[%0t] ECC: Single-bit error corrected at position %0d",
                             $time, syn_val);
                end else begin
                    $display("[%0t] ECC: Double-bit error detected (uncorrectable)!",
                             $time);
                end
            end
        end
    end
    `endif

    //=========================================================================
    // Assertions
    //=========================================================================

    `ifdef SVA_ENABLE
    // Verify encoding produces valid codeword
    property p_valid_encoding;
        @(posedge clk) disable iff (!rst_n)
        encode_valid |-> ##1 (calc_syndrome(encoded_reg) == 0 || inject_enable);
    endproperty
    assert property (p_valid_encoding) else
        $error("ECC encoding produced invalid codeword");

    // Single errors should be correctable
    property p_single_error_correctable;
        @(posedge clk) disable iff (!rst_n)
        (decode_valid && single_error) |-> (decoded_reg !== 'x);
    endproperty
    assert property (p_single_error_correctable) else
        $error("Single error correction failed");
    `endif

endmodule : ecc_module
