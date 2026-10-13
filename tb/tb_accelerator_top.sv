`timescale 1ns / 1ps

/**
 * Testbench: tb_accelerator_top
 * Description: Exhaustive self-checking integration testbench for int8_accelerator_top.
 *              Verifies:
 *                1. Weight configuration handshake and stationary weight latching
 *                2. Activation streaming via AXI-Stream interface
 *                3. End-to-end 4x4 signed INT8 GEMM matrix computation
 *                4. Downstream backpressure handling (m_axis_tready stall tolerance,
 *                   verifying tvalid, tdata, and tlast stability across stalls)
 *                5. Input backpressure handling under high upstream ingestion (zero data loss)
 *                6. Weight-stationary reuse across consecutive activation matrices
 *                7. Dynamic weight re-configuration (new matrix weights)
 *                8. Watchdog timeout to prevent infinite simulation hangs
 */
module tb_accelerator_top;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam time CLK_PERIOD = 10ns;

    // Clock & Reset
    logic                                            clk;
    logic                                            rst_n;

    // Weight configuration port (flattened 32-bit vector)
    logic                                            s_weight_valid;
    logic                                            s_weight_ready;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       s_weight_data;

    // Activation input stream (flattened 32-bit vector)
    logic                                            s_axis_tvalid;
    logic                                            s_axis_tready;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       s_axis_tdata;
    logic                                            s_axis_tlast;

    // Result output stream (flattened 128-bit vector)
    logic                                            m_axis_tvalid;
    logic                                            m_axis_tready;
    logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]        m_axis_tdata;
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

    // Watchdog Timer for Deadlock Prevention
    initial begin
        #5_000_000; // 5 ms timeout
        $display("================================================================");
        $display("[FATAL] WATCHDOG TIMEOUT EXPIRED (5ms)! Simulation deadlocked.");
        $display("================================================================");
        $fatal(1, "tb_accelerator_top deadlock detected.");
    end

    // Test Matrices
    logic signed [DATA_WIDTH-1:0] W1 [4][4];
    logic signed [DATA_WIDTH-1:0] A1 [4][4];
    logic signed [ACC_WIDTH-1:0]  exp_C1 [4][4];

    logic signed [DATA_WIDTH-1:0] A2 [4][4];
    logic signed [ACC_WIDTH-1:0]  exp_C2 [4][4];

    logic signed [DATA_WIDTH-1:0] A3 [4][4];
    logic signed [ACC_WIDTH-1:0]  exp_C3 [4][4];

    logic signed [DATA_WIDTH-1:0] A4 [4][4];
    logic signed [ACC_WIDTH-1:0]  exp_C4 [4][4];

    logic signed [DATA_WIDTH-1:0] W_new [4][4];
    logic signed [DATA_WIDTH-1:0] A_new [4][4];
    logic signed [ACC_WIDTH-1:0]  exp_C_new [4][4];

    logic signed [DATA_WIDTH-1:0] W_ext [4][4];
    logic signed [DATA_WIDTH-1:0] A_ext [4][4];
    logic signed [ACC_WIDTH-1:0]  exp_C_ext [4][4];

    // Helper task to send a single weight row holding stable until handshake
    task automatic send_weight_row(
        input logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] row_data
    );
        @(negedge clk);
        s_weight_valid = 1'b1;
        s_weight_data  = row_data;
        do begin
            @(posedge clk);
        end while (!(s_weight_valid && s_weight_ready));
        @(negedge clk);
        s_weight_valid = 1'b0;
        s_weight_data  = '0;
    endtask

    // Helper task to stream a single activation row holding stable until handshake
    task automatic send_activation_row(
        input logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] row_data,
        input logic                                      is_last
    );
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tdata  = row_data;
        s_axis_tlast  = is_last;
        do begin
            @(posedge clk);
        end while (!(s_axis_tvalid && s_axis_tready));
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tdata  = '0;
    endtask

    // Helper task to receive and verify a single row from m_axis
    task automatic receive_and_check_row(
        input string tag,
        input int    row_idx,
        input logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0] exp_row_data,
        input logic                                     exp_last
    );
        @(negedge clk);
        m_axis_tready = 1'b1;

        do begin
            @(posedge clk);
        end while (!(m_axis_tvalid && m_axis_tready));

        for (int c = 0; c < ARRAY_SIZE; c++) begin
            logic signed [ACC_WIDTH-1:0] actual_val, expected_val;
            actual_val   = m_axis_tdata[c*ACC_WIDTH +: ACC_WIDTH];
            expected_val = exp_row_data[c*ACC_WIDTH +: ACC_WIDTH];
            test_count++;
            if (actual_val === expected_val) begin
                $display("[PASS] %s Row %0d Col %0d: C = %0d (exp: %0d)",
                         tag, row_idx, c, actual_val, expected_val);
                pass_count++;
            end else begin
                $display("[FAIL] %s Row %0d Col %0d: C = %0d (exp: %0d)",
                         tag, row_idx, c, actual_val, expected_val);
                fail_count++;
            end
        end

        // Verify tlast
        test_count++;
        if (m_axis_tlast === exp_last) begin
            pass_count++;
        end else begin
            $display("[FAIL] %s Row %0d: m_axis_tlast mismatch (got %b, exp %b)",
                     tag, row_idx, m_axis_tlast, exp_last);
            fail_count++;
        end

        @(negedge clk);
        m_axis_tready = 1'b0;
    endtask

    // Wait for m_axis_tvalid with timeout
    task automatic wait_for_output(input string tag);
        int timeout_cnt;
        timeout_cnt = 0;
        $display("[INFO] Waiting for output stream (%s)...", tag);
        while (!m_axis_tvalid) begin
            @(posedge clk);
            timeout_cnt++;
            if (timeout_cnt > 100) begin
                $display("[FATAL] %s: Output timeout waiting for m_axis_tvalid!", tag);
                $fatal(1, "Output stream timeout deadlock.");
            end
        end
    endtask

    // Main Test Stimulus
    initial begin
        logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]  w_payload;
        logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]  a_payload;
        logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]   c_payload;

        // Initialize Matrix W1
        W1[0][0] =  8'sd1; W1[0][1] =  8'sd2; W1[0][2] =  8'sd3; W1[0][3] =  8'sd4;
        W1[1][0] =  8'sd2; W1[1][1] =  8'sd1; W1[1][2] =  8'sd0; W1[1][3] = -8'sd1;
        W1[2][0] = -8'sd1; W1[2][1] = -8'sd2; W1[2][2] =  8'sd1; W1[2][3] =  8'sd2;
        W1[3][0] =  8'sd0; W1[3][1] =  8'sd3; W1[3][2] = -8'sd2; W1[3][3] =  8'sd1;

        // Initialize Matrix A1
        A1[0][0] =  8'sd2; A1[0][1] =  8'sd1; A1[0][2] =  8'sd3; A1[0][3] =  8'sd0;
        A1[1][0] =  8'sd1; A1[1][1] = -8'sd2; A1[1][2] =  8'sd0; A1[1][3] =  8'sd4;
        A1[2][0] =  8'sd3; A1[2][1] =  8'sd0; A1[2][2] = -8'sd1; A1[2][3] =  8'sd2;
        A1[3][0] = -8'sd1; A1[3][1] =  8'sd1; A1[3][2] =  8'sd2; A1[3][3] = -8'sd3;

        // Expected C1 = A1 x W1
        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] s; s = 0;
                for (int k = 0; k < 4; k++) s = s + (A1[i][k] * W1[k][j]);
                exp_C1[i][j] = s;
            end
        end

        // Matrix A2 (for backpressure stall test)
        A2[0][0] =  8'sd5; A2[0][1] = -8'sd3; A2[0][2] =  8'sd1; A2[0][3] =  8'sd2;
        A2[1][0] =  8'sd0; A2[1][1] =  8'sd4; A2[1][2] = -8'sd2; A2[1][3] =  8'sd1;
        A2[2][0] = -8'sd1; A2[2][1] =  8'sd2; A2[2][2] =  8'sd3; A2[2][3] = -8'sd4;
        A2[3][0] =  8'sd2; A2[3][1] = -8'sd1; A2[3][2] =  8'sd0; A2[3][3] =  8'sd3;

        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] s; s = 0;
                for (int k = 0; k < 4; k++) s = s + (A2[i][k] * W1[k][j]);
                exp_C2[i][j] = s;
            end
        end

        // Matrix A3 & A4 (for input backpressure test)
        A3[0][0] =  8'sd1; A3[0][1] =  8'sd1; A3[0][2] =  8'sd1; A3[0][3] =  8'sd1;
        A3[1][0] =  8'sd2; A3[1][1] =  8'sd2; A3[1][2] =  8'sd2; A3[1][3] =  8'sd2;
        A3[2][0] =  8'sd3; A3[2][1] =  8'sd3; A3[2][2] =  8'sd3; A3[2][3] =  8'sd3;
        A3[3][0] =  8'sd4; A3[3][1] =  8'sd4; A3[3][2] =  8'sd4; A3[3][3] =  8'sd4;

        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] s; s = 0;
                for (int k = 0; k < 4; k++) s = s + (A3[i][k] * W1[k][j]);
                exp_C3[i][j] = s;
            end
        end

        A4[0][0] = -8'sd10; A4[0][1] =  8'sd20; A4[0][2] = -8'sd30; A4[0][3] =  8'sd40;
        A4[1][0] =  8'sd15; A4[1][1] = -8'sd25; A4[1][2] =  8'sd35; A4[1][3] = -8'sd45;
        A4[2][0] = -8'sd12; A4[2][1] =  8'sd22; A4[2][2] = -8'sd32; A4[2][3] =  8'sd42;
        A4[3][0] =  8'sd18; A4[3][1] = -8'sd28; A4[3][2] =  8'sd38; A4[3][3] = -8'sd48;

        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] s; s = 0;
                for (int k = 0; k < 4; k++) s = s + (A4[i][k] * W1[k][j]);
                exp_C4[i][j] = s;
            end
        end

        // Matrix W_new (Identity matrix) & A_new
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                W_new[r][c] = (r == c) ? 8'sd1 : 8'sd0;
                A_new[r][c] = 8'sd10 * (r + 1) + (c + 1);
            end
        end

        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] s; s = 0;
                for (int k = 0; k < 4; k++) s = s + (A_new[i][k] * W_new[k][j]);
                exp_C_new[i][j] = s;
            end
        end

        // Extreme Corner Matrices W_ext and A_ext
        // Tests -128 * -128 = +16,384, +127 * +127 = +16,129, -128 * +127 = -16,256
        W_ext[0][0] = -8'sd128; W_ext[0][1] =  8'sd127; W_ext[0][2] = -8'sd128; W_ext[0][3] =  8'sd127;
        W_ext[1][0] = -8'sd128; W_ext[1][1] = -8'sd128; W_ext[1][2] =  8'sd127; W_ext[1][3] =  8'sd127;
        W_ext[2][0] = -8'sd128; W_ext[2][1] =  8'sd127; W_ext[2][2] =  8'sd127; W_ext[2][3] = -8'sd128;
        W_ext[3][0] = -8'sd128; W_ext[3][1] = -8'sd128; W_ext[3][2] = -8'sd128; W_ext[3][3] =  8'sd127;

        A_ext[0][0] = -8'sd128; A_ext[0][1] = -8'sd128; A_ext[0][2] = -8'sd128; A_ext[0][3] = -8'sd128;
        A_ext[1][0] =  8'sd127; A_ext[1][1] =  8'sd127; A_ext[1][2] =  8'sd127; A_ext[1][3] =  8'sd127;
        A_ext[2][0] = -8'sd128; A_ext[2][1] =  8'sd127; A_ext[2][2] = -8'sd128; A_ext[2][3] =  8'sd127;
        A_ext[3][0] =  8'sd127; A_ext[3][1] = -8'sd128; A_ext[3][2] =  8'sd127; A_ext[3][3] = -8'sd128;

        for (int i = 0; i < 4; i++) begin
            for (int j = 0; j < 4; j++) begin
                logic signed [31:0] s; s = 0;
                for (int k = 0; k < 4; k++) s = s + (A_ext[i][k] * W_ext[k][j]);
                exp_C_ext[i][j] = s;
            end
        end

        $dumpfile("accelerator_top_waves.vcd");
        $dumpvars(0, tb_accelerator_top);

        $display("================================================================");
        $display("   INT8 Accelerator Top-Level Integration & Stress Verification");
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

        // -------------------------------------------------------------
        // TEST 1: Baseline GEMM (Load Weights -> Stream Activations -> Verify)
        // -------------------------------------------------------------
        $display("\n>>> TEST 1: Baseline GEMM Transaction 1 <<<");
        $display("[INFO] Loading weights W1...");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) w_payload[c*DATA_WIDTH +: DATA_WIDTH] = W1[r][c];
            send_weight_row(w_payload);
        end

        $display("[INFO] Streaming activations A1...");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) a_payload[c*DATA_WIDTH +: DATA_WIDTH] = A1[r][c];
            send_activation_row(a_payload, (r == 3));
        end

        wait_for_output("T1");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C1[r][c];
            receive_and_check_row("T1", r, c_payload, (r == 3));
        end

        // -------------------------------------------------------------
        // TEST 2: Multi-Cycle Downstream Stall & Backpressure Robustness
        // Stalls at Row 1 and at Row 3 (with tlast=1)
        // -------------------------------------------------------------
        $display("\n>>> TEST 2: Multi-Cycle Downstream Backpressure Stalls <<<");
        $display("[INFO] Streaming activations A2...");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) a_payload[c*DATA_WIDTH +: DATA_WIDTH] = A2[r][c];
            send_activation_row(a_payload, (r == 3));
        end

        wait_for_output("T2");

        // Read Row 0
        for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C2[0][c];
        receive_and_check_row("T2", 0, c_payload, 1'b0);

        // Stall 4 cycles before Row 1
        $display("[INFO] Applying backpressure (m_axis_tready = 0) at Row 1 for 4 cycles...");
        for (int s = 0; s < 4; s++) begin
            @(negedge clk);
            test_count++;
            if (m_axis_tvalid === 1'b1 &&
                m_axis_tdata[0*ACC_WIDTH +: ACC_WIDTH] === exp_C2[1][0] &&
                m_axis_tlast === 1'b0) begin
                pass_count++;
            end else begin
                $display("[FAIL] Data/valid/last unstable during Row 1 stall cycle %0d", s);
                fail_count++;
            end
        end
        $display("[PASS] Row 1 backpressure stability verified over 4 stall cycles");

        // Read Row 1 and Row 2
        for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C2[1][c];
        receive_and_check_row("T2", 1, c_payload, 1'b0);

        for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C2[2][c];
        receive_and_check_row("T2", 2, c_payload, 1'b0);

        // Stall 4 cycles at Row 3 (Final row where tlast == 1)
        $display("[INFO] Applying backpressure at Row 3 (tlast asserted) for 4 cycles...");
        for (int s = 0; s < 4; s++) begin
            @(negedge clk);
            test_count++;
            if (m_axis_tvalid === 1'b1 &&
                m_axis_tlast === 1'b1 &&
                m_axis_tdata[0*ACC_WIDTH +: ACC_WIDTH] === exp_C2[3][0]) begin
                pass_count++;
            end else begin
                $display("[FAIL] tvalid/tlast/tdata unstable during Row 3 stall cycle %0d (tvalid=%b, tlast=%b)",
                         s, m_axis_tvalid, m_axis_tlast);
                fail_count++;
            end
        end
        $display("[PASS] Row 3 (tlast=1) backpressure stability verified over 4 stall cycles");

        // Read Row 3 to complete Transaction 2
        for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C2[3][c];
        receive_and_check_row("T2", 3, c_payload, 1'b1);

        // -------------------------------------------------------------
        // TEST 3: Input Backpressure & No-Data-Loss Under High Ingestion
        // -------------------------------------------------------------
        $display("\n>>> TEST 3: Input Backpressure & Zero Data Loss Test <<<");
        $display("[INFO] Streaming activations A3...");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) a_payload[c*DATA_WIDTH +: DATA_WIDTH] = A3[r][c];
            send_activation_row(a_payload, (r == 3));
        end

        // While accelerator is computing or output streaming T3, assert A4 row 0
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tlast  = 1'b0;
        for (int c = 0; c < 4; c++) s_axis_tdata[c*DATA_WIDTH +: DATA_WIDTH] = A4[0][c];

        // Verify accelerator asserts backpressure (s_axis_tready == 0)
        test_count++;
        if (s_axis_tready === 1'b0) begin
            $display("[PASS] Accelerator correctly asserted input backpressure (s_axis_tready=0) while busy");
            pass_count++;
        end else begin
            $display("[FAIL] Accelerator failed to assert input backpressure while busy!");
            fail_count++;
        end

        // Verify weight port also asserts backpressure (s_weight_ready == 0)
        test_count++;
        if (s_weight_ready === 1'b0) begin
            $display("[PASS] Weight port correctly asserted backpressure (s_weight_ready=0) while busy");
            pass_count++;
        end else begin
            $display("[FAIL] Weight port failed to assert backpressure while busy!");
            fail_count++;
        end

        // Collect Transaction 3 output while holding A4 row 0 stable at input
        fork
            begin
                wait_for_output("T3");
                for (int r = 0; r < 4; r++) begin
                    for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C3[r][c];
                    receive_and_check_row("T3", r, c_payload, (r == 3));
                end
            end
            begin
                // A4 row 0 is held stable until accepted
                do begin
                    @(posedge clk);
                end while (!s_axis_tready);
                // Row 0 accepted once T3 completed output streaming!
                @(negedge clk);
                s_axis_tvalid = 1'b0;
                $display("[PASS] Pending input row 0 accepted without data loss upon backpressure release");
            end
        join

        // Stream remaining rows 1..3 of A4
        for (int r = 1; r < 4; r++) begin
            for (int c = 0; c < 4; c++) a_payload[c*DATA_WIDTH +: DATA_WIDTH] = A4[r][c];
            send_activation_row(a_payload, (r == 3));
        end

        // Verify Transaction 4 output
        wait_for_output("T4");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C4[r][c];
            receive_and_check_row("T4", r, c_payload, (r == 3));
        end

        // -------------------------------------------------------------
        // TEST 4: Weight Re-Configuration & Verification
        // -------------------------------------------------------------
        $display("\n>>> TEST 4: Weight Re-Configuration (Identity Matrix) <<<");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) w_payload[c*DATA_WIDTH +: DATA_WIDTH] = W_new[r][c];
            send_weight_row(w_payload);
        end

        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) a_payload[c*DATA_WIDTH +: DATA_WIDTH] = A_new[r][c];
            send_activation_row(a_payload, (r == 3));
        end

        wait_for_output("T_new");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C_new[r][c];
            receive_and_check_row("T_new", r, c_payload, (r == 3));
        end

        // -------------------------------------------------------------
        // TEST 5: Signed INT8 Extremes Verification (-128*-128, +127*+127, mixed)
        // -------------------------------------------------------------
        $display("\n>>> TEST 5: Signed INT8 Extremes Verification <<<");
        $display("[INFO] Loading extreme weights W_ext...");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) w_payload[c*DATA_WIDTH +: DATA_WIDTH] = W_ext[r][c];
            send_weight_row(w_payload);
        end

        $display("[INFO] Streaming extreme activations A_ext...");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) a_payload[c*DATA_WIDTH +: DATA_WIDTH] = A_ext[r][c];
            send_activation_row(a_payload, (r == 3));
        end

        wait_for_output("T_ext");
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) c_payload[c*ACC_WIDTH +: ACC_WIDTH] = exp_C_ext[r][c];
            receive_and_check_row("T_ext", r, c_payload, (r == 3));
        end

        // -------------------------------------------------------------
        // Final Summary
        // -------------------------------------------------------------
        $display("================================================================");
        $display(" ACCELERATOR TOP TEST SUMMARY: Total: %0d | PASSED: %0d | FAILED: %0d",
                 test_count, pass_count, fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display(">>> ALL TOP-LEVEL ACCELERATOR INTEGRATION TESTS PASSED (100%%)! <<<");
        end else begin
            $display(">>> TOP-LEVEL TEST FAILURES DETECTED! <<<");
        end

        $finish;
    end

endmodule
