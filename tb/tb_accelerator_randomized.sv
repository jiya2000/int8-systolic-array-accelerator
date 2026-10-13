`timescale 1ns / 1ps

/**
 * Testbench: tb_accelerator_randomized
 * Description: 100-Matrix Randomized Stress Testbench for INT8 Systolic Array Accelerator.
 *              Generates 100 pseudo-random 4x4 matrix pairs (A, W) in software,
 *              streams them into the hardware accelerator, and validates every single
 *              output element (1,600 total elements) against a golden software multiplier.
 */
module tb_accelerator_randomized;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam int NUM_MATRICES = 100;
    localparam time CLK_PERIOD = 10ns;

    logic                                            clk;
    logic                                            rst_n;
    logic                                            s_weight_valid;
    logic                                            s_weight_ready;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       s_weight_data;
    logic                                            s_axis_tvalid;
    logic                                            s_axis_tready;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       s_axis_tdata;
    logic                                            s_axis_tlast;
    logic                                            m_axis_tvalid;
    logic                                            m_axis_tready;
    logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]        m_axis_tdata;
    logic                                            m_axis_tlast;
    logic                                            busy;
    logic                                            done;

    int total_matrices_passed = 0;
    int total_elements_checked = 0;
    int total_failures = 0;

    int seed = 32'hDEAD_BEEF;

    // Instantiate DUT
    int8_accelerator_top #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_weight_valid (s_weight_valid),
        .s_weight_ready (s_weight_ready),
        .s_weight_data  (s_weight_data),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tlast   (m_axis_tlast),
        .busy           (busy),
        .done           (done)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Storage for randomized matrices
    logic signed [DATA_WIDTH-1:0] W_test [4][4];
    logic signed [DATA_WIDTH-1:0] A_test [4][4];
    logic signed [ACC_WIDTH-1:0]  expected_C [4][4];

    // Watchdog Timer to catch deadlocks and fail fast
    initial begin
        #60_000_000; // 60 ms maximum run time limit
        $display("================================================================");
        $display("[FATAL] WATCHDOG TIMEOUT EXPIRED (60ms)! Simulation deadlocked.");
        $display("================================================================");
        $fatal(1, "Deadlock watchdog fired.");
    end

    // Simple pseudo-random INT8 generator
    function automatic logic signed [7:0] get_rand_int8();
        seed = seed * 1103515245 + 12345;
        return seed[15:8]; // Returns signed 8-bit value [-128..127]
    endfunction

    // Compute expected matrix product in software
    task automatic compute_golden();
        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] sum;
                sum = 0;
                for (int k = 0; k < 4; k++) begin
                    sum = sum + (A_test[i][k] * W_test[k][j]);
                end
                expected_C[i][j] = sum;
            end
        end
    endtask

    // Driver task: Send weight row with strict valid/ready handshake and stability hold
    task automatic send_weight_row(
        input logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] row_data
    );
        @(negedge clk);
        s_weight_valid = 1'b1;
        s_weight_data  = row_data;
        // Hold valid and data stable until a posedge clk where valid and ready are both high
        do begin
            @(posedge clk);
        end while (!(s_weight_valid && s_weight_ready));
        @(negedge clk);
        s_weight_valid = 1'b0;
        s_weight_data  = '0;
    endtask

    // Driver task: Stream activation row with strict valid/ready handshake and stability hold
    task automatic send_activation_row(
        input logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] row_data,
        input logic                                      is_last
    );
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tdata  = row_data;
        s_axis_tlast  = is_last;
        // Hold valid, last, and data stable until a posedge clk where valid and ready are both high
        do begin
            @(posedge clk);
        end while (!(s_axis_tvalid && s_axis_tready));
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tdata  = '0;
    endtask

    // Output collection task with timeout and random backpressure stall tests
    task automatic collect_output_matrix(
        input  int m_idx,
        output int err_count
    );
        int wait_cycles;
        err_count = 0;
        wait_cycles = 0;

        // Wait for m_axis_tvalid with timeout
        while (!m_axis_tvalid) begin
            @(posedge clk);
            wait_cycles++;
            if (wait_cycles > 100) begin
                $display("[FATAL] Matrix %0d output timeout: m_axis_tvalid failed to assert within 100 cycles!", m_idx);
                $fatal(1, "Output stream timeout deadlock.");
            end
        end

        // Collect each of the 4 rows
        for (int r = 0; r < 4; r++) begin
            // In 25% of matrix rows, introduce a randomized multi-cycle downstream stall (1-3 cycles)
            if ((seed[3:0] < 4) && (m_idx % 2 == 0)) begin
                int stall_cycles;
                logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0] captured_stalled_data;
                stall_cycles = (seed[6:4] % 3) + 1; // 1 to 3 cycles
                @(negedge clk);
                m_axis_tready = 1'b0;
                captured_stalled_data = m_axis_tdata;
                for (int s = 0; s < stall_cycles; s++) begin
                    @(negedge clk);
                    // Verify stability during stall: valid must stay high, data and last must remain frozen
                    if (!m_axis_tvalid) begin
                        $display("[FAIL] Matrix %0d Row %0d: m_axis_tvalid dropped during stall cycle %0d!", m_idx, r, s);
                        err_count++;
                    end
                    if (m_axis_tdata !== captured_stalled_data) begin
                        $display("[FAIL] Matrix %0d Row %0d: m_axis_tdata unstable during stall cycle %0d!", m_idx, r, s);
                        err_count++;
                    end
                    if (r == 3 && !m_axis_tlast) begin
                        $display("[FAIL] Matrix %0d Row 3: m_axis_tlast dropped during stall cycle %0d!", m_idx, r, s);
                        err_count++;
                    end
                end
            end

            // Assert m_axis_tready to accept the row on posedge clk
            @(negedge clk);
            m_axis_tready = 1'b1;

            // Wait until rising-edge handshake where valid and ready are both high
            do begin
                @(posedge clk);
            end while (!(m_axis_tvalid && m_axis_tready));

            // Validate data on the handshake edge
            for (int c = 0; c < 4; c++) begin
                logic signed [ACC_WIDTH-1:0] actual_val;
                actual_val = m_axis_tdata[c*ACC_WIDTH +: ACC_WIDTH];
                total_elements_checked++;
                if (actual_val !== expected_C[r][c]) begin
                    $display("[FAIL] Matrix %0d Mismatch at [%0d][%0d]: Got %0d, Exp %0d",
                             m_idx, r, c, actual_val, expected_C[r][c]);
                    err_count++;
                    total_failures++;
                end
            end

            // Check tlast signal on last row
            if (r == 3 && m_axis_tlast !== 1'b1) begin
                $display("[FAIL] Matrix %0d Row 3: Expected m_axis_tlast=1 on last row!", m_idx);
                err_count++;
                total_failures++;
            end

            @(negedge clk);
            m_axis_tready = 1'b0;
        end
    endtask

    // Main Test Stimulus
    initial begin
        $display("================================================================");
        $display("   INT8 Accelerator: 100-Matrix Randomized Regression Suite");
        $display("================================================================");

        rst_n          = 0;
        s_weight_valid = 0;
        s_axis_tvalid  = 0;
        s_axis_tlast   = 0;
        m_axis_tready  = 0;
        s_weight_data  = '0;
        s_axis_tdata   = '0;

        #(CLK_PERIOD * 2);
        @(negedge clk);
        rst_n = 1;

        for (int m = 0; m < NUM_MATRICES; m++) begin
            int matrix_errors;
            logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] row_payload;

            // 1. Generate randomized 4x4 weights and activations
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    W_test[r][c] = get_rand_int8();
                    A_test[r][c] = get_rand_int8();
                end
            end
            compute_golden();

            // 2. Load Weights using handshake driver with optional random bubble
            for (int r = 0; r < 4; r++) begin
                if ((seed[2:0] == 3'b001) && (r > 0)) begin
                    @(negedge clk); // 1-cycle bubble
                end
                for (int c = 0; c < 4; c++) begin
                    row_payload[c*DATA_WIDTH +: DATA_WIDTH] = W_test[r][c];
                end
                send_weight_row(row_payload);
            end

            // 3. Stream Activations using handshake driver with optional random bubble
            for (int r = 0; r < 4; r++) begin
                if ((seed[3:1] == 3'b010) && (r > 0)) begin
                    @(negedge clk); // 1-cycle bubble
                end
                for (int c = 0; c < 4; c++) begin
                    row_payload[c*DATA_WIDTH +: DATA_WIDTH] = A_test[r][c];
                end
                send_activation_row(row_payload, (r == 3));
            end

            // 4. Wait for output stream and validate all 16 results under stall conditions
            collect_output_matrix(m, matrix_errors);

            if (matrix_errors == 0) begin
                total_matrices_passed++;
                if ((m + 1) % 20 == 0) begin
                    $display("[INFO] Successfully validated %0d / %0d full 4x4 matrix multiplications...",
                             m + 1, NUM_MATRICES);
                end
            end
        end

        $display("================================================================");
        $display(" RANDOMIZED REGRESSION SUMMARY:");
        $display("   Total 4x4 Matrices Tested: %0d", NUM_MATRICES);
        $display("   Total Output Elements Checked: %0d", total_elements_checked);
        $display("   Total Matrix Multiplies Passed: %0d / %0d", total_matrices_passed, NUM_MATRICES);
        $display("   Total Element Failures: %0d", total_failures);
        $display("================================================================");

        if (total_failures == 0) begin
            $display(">>> ALL 100 RANDOMIZED MATRICES (1,600 ELEMENTS) PASSED BIT-ACCURATELY! <<<");
        end else begin
            $display(">>> RANDOMIZED REGRESSION FAILURES DETECTED! <<<");
        end

        $finish;
    end

endmodule
