`timescale 1ns / 1ps

/**
 * Testbench: tb_systolic_array
 * Description: Self-checking testbench for the 4x4 Weight-Stationary Systolic Array.
 *              Verifies:
 *                1. 4-cycle weight pre-loading across all 16 PEs.
 *                2. Skewed activation injection.
 *                3. Cycle-accurate partial sum collection.
 *                4. Matrix multiplication accuracy against expected matrix product C = A x B.
 */
module tb_systolic_array;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam time CLK_PERIOD = 10ns;

    logic                                            clk;
    logic                                            rst_n;
    logic                                            en;
    logic                                            clr;
    logic [ARRAY_SIZE-1:0]                           weight_en;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       w_in;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]    a_in;
    logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]     c_in;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]    a_out;
    logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]     c_out;

    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;

    // Instantiate DUT
    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clr(clr),
        .weight_en(weight_en),
        .w_in(w_in),
        .a_in(a_in),
        .c_in(c_in),
        .a_out(a_out),
        .c_out(c_out)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Watchdog Timer for Deadlock Prevention
    initial begin
        #1_000_000; // 1 ms timeout
        $display("[FATAL] Watchdog timeout expired in tb_systolic_array! Simulation deadlocked.");
        $fatal(1, "tb_systolic_array deadlock detected.");
    end

    // Test Matrices
    logic signed [DATA_WIDTH-1:0] B [4][4];
    logic signed [DATA_WIDTH-1:0] A [4][4];
    logic signed [ACC_WIDTH-1:0]  expected_C [4][4];

    // Recorded Matrix C
    logic signed [ACC_WIDTH-1:0] actual_C [4][4];

    initial begin
        // Initialize Matrix B
        B[0][0] =  8'sd1; B[0][1] =  8'sd2; B[0][2] =  8'sd3; B[0][3] =  8'sd4;
        B[1][0] =  8'sd2; B[1][1] =  8'sd1; B[1][2] =  8'sd0; B[1][3] = -8'sd1;
        B[2][0] = -8'sd1; B[2][1] = -8'sd2; B[2][2] =  8'sd1; B[2][3] =  8'sd2;
        B[3][0] =  8'sd0; B[3][1] =  8'sd3; B[3][2] = -8'sd2; B[3][3] =  8'sd1;

        // Initialize Matrix A
        A[0][0] =  8'sd2; A[0][1] =  8'sd1; A[0][2] =  8'sd3; A[0][3] =  8'sd0;
        A[1][0] =  8'sd1; A[1][1] = -8'sd2; A[1][2] =  8'sd0; A[1][3] =  8'sd4;
        A[2][0] =  8'sd3; A[2][1] =  8'sd0; A[2][2] = -8'sd1; A[2][3] =  8'sd2;
        A[3][0] = -8'sd1; A[3][1] =  8'sd1; A[3][2] =  8'sd2; A[3][3] = -8'sd3;

        // Expected Result Matrix C = A x B
        expected_C[0][0] =  32'sd1; expected_C[0][1] = -32'sd1;  expected_C[0][2] =  32'sd9; expected_C[0][3] =  32'sd13;
        expected_C[1][0] = -32'sd3; expected_C[1][1] =  32'sd12; expected_C[1][2] = -32'sd5; expected_C[1][3] =  32'sd10;
        expected_C[2][0] =  32'sd4; expected_C[2][1] =  32'sd14; expected_C[2][2] =  32'sd4; expected_C[2][3] =  32'sd12;
        expected_C[3][0] = -32'sd1; expected_C[3][1] = -32'sd14; expected_C[3][2] =  32'sd5; expected_C[3][3] = -32'sd4;
        $dumpfile("systolic_waves.vcd");
        $dumpvars(0, tb_systolic_array);

        $display("================================================================");
        $display("   4x4 Systolic Array Matrix Multiplication Verification");
        $display("================================================================");

        // 1. Reset
        rst_n     = 0;
        en        = 0;
        clr       = 0;
        weight_en = '0;
        w_in      = '0;
        a_in      = '0;
        c_in      = '0;

        #(CLK_PERIOD * 2);
        @(negedge clk);
        rst_n = 1;

        // 2. Load Weights B into array row-by-row (4 cycles)
        $display("[INFO] Loading 4x4 weights B into stationary registers...");
        for (int r = 0; r < 4; r++) begin
            @(negedge clk);
            weight_en                 = (1 << r);
            w_in[0*DATA_WIDTH +: DATA_WIDTH] = B[r][0];
            w_in[1*DATA_WIDTH +: DATA_WIDTH] = B[r][1];
            w_in[2*DATA_WIDTH +: DATA_WIDTH] = B[r][2];
            w_in[3*DATA_WIDTH +: DATA_WIDTH] = B[r][3];
        end

        @(negedge clk);
        weight_en = '0;
        en        = 1;

        // 3. Feed Skewed Activations
        $display("[INFO] Streaming skewed activations A into array...");
        fork
            // Feeder thread
            begin
                for (int t = 0; t < 16; t++) begin
                    @(negedge clk);
                    for (int k = 0; k < 4; k++) begin
                        int a_row;
                        a_row = t - k;
                        if (a_row >= 0 && a_row < 4) begin
                            a_in[k*DATA_WIDTH +: DATA_WIDTH] = A[a_row][k];
                        end else begin
                            a_in[k*DATA_WIDTH +: DATA_WIDTH] = 8'sd0;
                        end
                    end
                    c_in = '0;
                end
            end

            // Sampler thread
            begin
                for (int t = 0; t < 16; t++) begin
                    @(negedge clk);
                    for (int j = 0; j < 4; j++) begin
                        int i;
                        i = t - 4 - j;
                        if (i >= 0 && i < 4) begin
                            actual_C[i][j] = c_out[j*ACC_WIDTH +: ACC_WIDTH];
                        end
                    end
                end
            end
        join

        // 4. Validate All 16 Elements of C
        $display("----------------------------------------------------------------");
        $display(" Verifying Result Matrix C against Golden Reference:");
        $display("----------------------------------------------------------------");
        for (int r = 0; r < 4; r++) begin
            for (int col = 0; col < 4; col++) begin
                test_count++;
                if (actual_C[r][col] === expected_C[r][col]) begin
                    $display("[PASS] C[%0d][%0d] = %0d (exp: %0d)",
                             r, col, actual_C[r][col], expected_C[r][col]);
                    pass_count++;
                end else begin
                    $display("[FAIL] C[%0d][%0d] = %0d (exp: %0d)",
                             r, col, actual_C[r][col], expected_C[r][col]);
                    fail_count++;
                end
            end
        end

        $display("================================================================");
        $display(" SYSTOLIC ARRAY MATRIX TEST: Total: %0d | PASSED: %0d | FAILED: %0d",
                 test_count, pass_count, fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display(">>> ALL 16 MATRIX OUTPUTS COMPUTED WITH 100%% ACCURACY! <<<");
        end else begin
            $display(">>> MATRIX MULTIPLICATION MISMATCH! <<<");
        end

        $finish;
    end

endmodule
