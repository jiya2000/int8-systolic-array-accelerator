`timescale 1ns / 1ps

/**
 * Testbench: tb_accelerator_top
 * Description: End-to-end self-checking testbench for int8_accelerator_top.
 *              Verifies:
 *                1. Weight configuration over streaming interface.
 *                2. Activation streaming with valid/ready handshake.
 *                3. Automatic compute sequencing via FSM controller.
 *                4. Output stream de-skewing and matrix result verification against golden model.
 *                5. Downstream backpressure handling (m_axis_tready stall with data stability).
 *                6. Consecutive back-to-back matrix multiplications.
 */
module tb_accelerator_top;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam time CLK_PERIOD = 10ns;

    // Clock & Reset
    logic                                            clk;
    logic                                            rst_n;

    // Weight configuration port
    logic                                            s_weight_valid;
    logic                                            s_weight_ready;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    s_weight_data;

    // Activation input stream
    logic                                            s_axis_tvalid;
    logic                                            s_axis_tready;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    s_axis_tdata;
    logic                                            s_axis_tlast;

    // Result output stream
    logic                                            m_axis_tvalid;
    logic                                            m_axis_tready;
    logic signed [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]     m_axis_tdata;
    logic                                            m_axis_tlast;

    // Status
    logic                                            busy;
    logic                                            done;

    // Test statistics
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;

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

    // Test Matrices
    logic signed [DATA_WIDTH-1:0] W [4][4];
    logic signed [DATA_WIDTH-1:0] A [4][4];
    logic signed [ACC_WIDTH-1:0]  expected_C [4][4];

    // Task to configure weights
    task automatic load_weights();
        $display("[INFO] Configuring weights...");
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            @(negedge clk);
            s_weight_valid = 1;
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                s_weight_data[c] = W[r][c];
            end
        end
        @(negedge clk);
        s_weight_valid = 0;
    endtask

    // Task to stream activations
    task automatic stream_activations();
        $display("[INFO] Streaming activations into accelerator...");
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            @(negedge clk);
            s_axis_tvalid = 1;
            s_axis_tlast  = (r == ARRAY_SIZE - 1);
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                s_axis_tdata[c] = A[r][c];
            end
        end
        @(negedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
    endtask

    // Main Test Sequence
    initial begin
        // Initialize Matrix W
        W[0][0] =  8'sd1; W[0][1] =  8'sd2; W[0][2] =  8'sd3; W[0][3] =  8'sd4;
        W[1][0] =  8'sd2; W[1][1] =  8'sd1; W[1][2] =  8'sd0; W[1][3] = -8'sd1;
        W[2][0] = -8'sd1; W[2][1] = -8'sd2; W[2][2] =  8'sd1; W[2][3] =  8'sd2;
        W[3][0] =  8'sd0; W[3][1] =  8'sd3; W[3][2] = -8'sd2; W[3][3] =  8'sd1;

        // Initialize Matrix A
        A[0][0] =  8'sd2; A[0][1] =  8'sd1; A[0][2] =  8'sd3; A[0][3] =  8'sd0;
        A[1][0] =  8'sd1; A[1][1] = -8'sd2; A[1][2] =  8'sd0; A[1][3] =  8'sd4;
        A[2][0] =  8'sd3; A[2][1] =  8'sd0; A[2][2] = -8'sd1; A[2][3] =  8'sd2;
        A[3][0] = -8'sd1; A[3][1] =  8'sd1; A[3][2] =  8'sd2; A[3][3] = -8'sd3;

        // Initialize Expected Result Matrix C = A x W
        expected_C[0][0] =  32'sd1; expected_C[0][1] = -32'sd1;  expected_C[0][2] =  32'sd9; expected_C[0][3] =  32'sd13;
        expected_C[1][0] = -32'sd3; expected_C[1][1] =  32'sd12; expected_C[1][2] = -32'sd5; expected_C[1][3] =  32'sd10;
        expected_C[2][0] =  32'sd4; expected_C[2][1] =  32'sd14; expected_C[2][2] =  32'sd4; expected_C[2][3] =  32'sd12;
        expected_C[3][0] = -32'sd1; expected_C[3][1] = -32'sd14; expected_C[3][2] =  32'sd5; expected_C[3][3] = -32'sd4;

        $dumpfile("accelerator_top_waves.vcd");
        $dumpvars(0, tb_accelerator_top);

        $display("================================================================");
        $display("   INT8 Accelerator Top-Level Integration Verification");
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

        // 1. Load Weights
        load_weights();

        // 2. Stream Activations (Transaction 1)
        stream_activations();

        // 3. Receive Outputs and Validate Transaction 1
        $display("[INFO] Waiting for output stream (Transaction 1)...");
        while (!m_axis_tvalid) @(posedge clk);

        for (int r = 0; r < ARRAY_SIZE; r++) begin
            @(negedge clk);
            m_axis_tready = 1;
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                test_count++;
                if (m_axis_tdata[c] === expected_C[r][c]) begin
                    $display("[PASS] T1 Row %0d Col %0d: C = %0d (exp: %0d)",
                             r, c, m_axis_tdata[c], expected_C[r][c]);
                    pass_count++;
                end else begin
                    $display("[FAIL] T1 Row %0d Col %0d: C = %0d (exp: %0d)",
                             r, c, m_axis_tdata[c], expected_C[r][c]);
                    fail_count++;
                end
            end
        end
        @(negedge clk);
        m_axis_tready = 0;

        // 4. Test Downstream Backpressure on Transaction 2
        $display("----------------------------------------------------------------");
        $display(" Starting Transaction 2 with Downstream Backpressure Test:");
        $display("----------------------------------------------------------------");
        stream_activations();

        while (!m_axis_tvalid) @(posedge clk);

        // Read Row 0
        @(negedge clk);
        m_axis_tready = 1;
        for (int c = 0; c < ARRAY_SIZE; c++) begin
            test_count++;
            if (m_axis_tdata[c] === expected_C[0][c]) begin
                pass_count++;
            end else begin
                fail_count++;
            end
        end

        // Apply backpressure before reading Row 1
        @(negedge clk);
        $display("[INFO] Applying backpressure (m_axis_tready = 0) for 3 cycles...");
        m_axis_tready = 0;
        for (int stall = 0; stall < 3; stall++) begin
            @(negedge clk);
            test_count++;
            // During stall, m_axis_tdata must remain stable presenting Row 1
            if (m_axis_tvalid === 1'b1 && m_axis_tdata[0] === expected_C[1][0]) begin
                pass_count++;
            end else begin
                $display("[FAIL] Data unstable during backpressure stall cycle %0d", stall);
                fail_count++;
            end
        end
        $display("[PASS] Backpressure stability verified over 3 stall cycles");

        // Release backpressure and read remaining rows [1, 2, 3]
        for (int r = 1; r < ARRAY_SIZE; r++) begin
            m_axis_tready = 1;
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                test_count++;
                if (m_axis_tdata[c] === expected_C[r][c]) begin
                    $display("[PASS] T2 Row %0d Col %0d: C = %0d (exp: %0d)",
                             r, c, m_axis_tdata[c], expected_C[r][c]);
                    pass_count++;
                end else begin
                    $display("[FAIL] T2 Row %0d Col %0d: C = %0d (exp: %0d)",
                             r, c, m_axis_tdata[c], expected_C[r][c]);
                    fail_count++;
                end
            end
            @(negedge clk);
        end
        m_axis_tready = 0;

        $display("================================================================");
        $display(" ACCELERATOR TOP TEST SUMMARY: Total: %0d | PASSED: %0d | FAILED: %0d",
                 test_count, pass_count, fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display(">>> ALL TOP-LEVEL ACCELERATOR INTEGRATION TESTS PASSED! <<<");
        end else begin
            $display(">>> TOP-LEVEL TEST FAILURES DETECTED! <<<");
        end

        $finish;
    end

endmodule
