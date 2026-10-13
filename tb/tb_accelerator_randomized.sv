`timescale 1ns / 1ps

/**
 * Testbench: tb_accelerator_randomized
 * Description: High-volume randomized regression testbench for int8_accelerator_top.
 *              Executes 100 consecutive full 4x4 matrix multiplications (1,600 output elements).
 *              Computes expected matrix product in software on-the-fly and asserts bit-exact match.
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
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    s_weight_data;
    logic                                            s_axis_tvalid;
    logic                                            s_axis_tready;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    s_axis_tdata;
    logic                                            s_axis_tlast;
    logic                                            m_axis_tvalid;
    logic                                            m_axis_tready;
    logic signed [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]     m_axis_tdata;
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
            // 1. Generate randomized 4x4 weights and activations
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    W_test[r][c] = get_rand_int8();
                    A_test[r][c] = get_rand_int8();
                end
            end
            compute_golden();

            // 2. Load Weights into accelerator
            for (int r = 0; r < 4; r++) begin
                @(negedge clk);
                s_weight_valid = 1;
                for (int c = 0; c < 4; c++) begin
                    s_weight_data[c] = W_test[r][c];
                end
            end
            @(negedge clk);
            s_weight_valid = 0;

            // 3. Stream Activations
            for (int r = 0; r < 4; r++) begin
                @(negedge clk);
                s_axis_tvalid = 1;
                s_axis_tlast  = (r == 3);
                for (int c = 0; c < 4; c++) begin
                    s_axis_tdata[c] = A_test[r][c];
                end
            end
            @(negedge clk);
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;

            // 4. Wait for output stream and validate all 16 results
            while (!m_axis_tvalid) @(posedge clk);

            begin
                int matrix_errors;
                matrix_errors = 0;

                for (int r = 0; r < 4; r++) begin
                    @(negedge clk);
                    m_axis_tready = 1;
                    for (int c = 0; c < 4; c++) begin
                        total_elements_checked++;
                        if (m_axis_tdata[c] !== expected_C[r][c]) begin
                            $display("[FAIL] Matrix %0d Mismatch at [%0d][%0d]: Got %0d, Exp %0d",
                                     m, r, c, m_axis_tdata[c], expected_C[r][c]);
                            total_failures++;
                            matrix_errors++;
                        end
                    end
                end
                @(negedge clk);
                m_axis_tready = 0;

                if (matrix_errors == 0) begin
                    total_matrices_passed++;
                    if ((m + 1) % 20 == 0) begin
                        $display("[INFO] Successfully validated %0d / %0d full 4x4 matrix multiplications...",
                                 m + 1, NUM_MATRICES);
                    end
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
            $display(">>> REGRESSION FAILURES DETECTED! <<<");
        end

        $finish;
    end

endmodule
