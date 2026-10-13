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
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    w_in;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    a_in;
    logic signed [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]     c_in;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0]    a_out;
    logic signed [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]     c_out;

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

    // Test Matrices
    logic signed [DATA_WIDTH-1:0] B [4][4] = '{
        '{ 8'sd1,  8'sd2,  8'sd3,  8'sd4 },
        '{ 8'sd2,  8'sd1,  8'sd0, -8'sd1 },
        '{-8'sd1, -8'sd2,  8'sd1,  8'sd2 },
        '{ 8'sd0,  8'sd3, -8'sd2,  8'sd1 }
    };

    logic signed [DATA_WIDTH-1:0] A [4][4] = '{
        '{ 8'sd2,  8'sd1,  8'sd3,  8'sd0 },
        '{ 8'sd1, -8'sd2,  8'sd0,  8'sd4 },
        '{ 8'sd3,  8'sd0, -8'sd1,  8'sd2 },
        '{-8'sd1,  8'sd1,  8'sd2, -8'sd3 }
    };

    logic signed [ACC_WIDTH-1:0] expected_C [4][4] = '{
        '{ 32'sd1, -32'sd1,  32'sd9, 32'sd13 },
        '{-32'sd3,  32'sd12, -32'sd5, 32'sd10 },
        '{ 32'sd4,  32'sd14,  32'sd4, 32'sd12 },
        '{-32'sd1, -32'sd14,  32'sd5, -32'sd4 }
    };

    // Recorded Matrix C
    logic signed [ACC_WIDTH-1:0] actual_C [4][4];

    initial begin
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
            weight_en    = (1 << r);
            w_in[0]      = B[r][0];
            w_in[1]      = B[r][1];
            w_in[2]      = B[r][2];
            w_in[3]      = B[r][3];
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
                            a_in[k] = A[a_row][k];
                        end else begin
                            a_in[k] = 8'sd0;
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
                            actual_C[i][j] = c_out[j];
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
