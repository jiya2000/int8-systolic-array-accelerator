`timescale 1ns / 1ps

/**
 * Testbench: tb_pe
 * Description: Exhaustive self-checking testbench for the INT8 Processing Element (Stage 1).
 *              Drives inputs on negedge clk to guarantee clean setup/hold timing.
 *              Verifies:
 *                1. Control priority hierarchy (rst_n > weight_en > en[clr/compute] > stall)
 *                2. Signed two's-complement arithmetic across all 4 quadrants
 *                3. Extreme numerical boundaries (-128*-128, +127*+127, etc.)
 *                4. 32-bit modular overflow wrapping
 *                5. Systolic datapath integrity
 */
module tb_pe;

    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam time CLK_PERIOD = 10ns;

    // DUT Signals
    logic                          clk;
    logic                          rst_n;
    logic                          weight_en;
    logic                          en;
    logic                          clr;
    logic signed [DATA_WIDTH-1:0]  w_in;
    logic signed [DATA_WIDTH-1:0]  a_in;
    logic signed [ACC_WIDTH-1:0]   c_in;
    logic signed [DATA_WIDTH-1:0]  a_out;
    logic signed [ACC_WIDTH-1:0]   c_out;

    // Test statistics
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;

    // Instantiate DUT
    pe #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .weight_en(weight_en),
        .en(en),
        .clr(clr),
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

    // Task to drive inputs cleanly on negedge and sample on the following negedge
    task automatic step_and_check(
        input string description,
        input logic                         t_weight_en,
        input logic                         t_en,
        input logic                         t_clr,
        input logic signed [DATA_WIDTH-1:0] t_w_in,
        input logic signed [DATA_WIDTH-1:0] t_a_in,
        input logic signed [ACC_WIDTH-1:0]  t_c_in,
        input logic signed [DATA_WIDTH-1:0] expected_a,
        input logic signed [ACC_WIDTH-1:0]  expected_c
    );
        // Drive on negedge
        @(negedge clk);
        weight_en = t_weight_en;
        en        = t_en;
        clr       = t_clr;
        w_in      = t_w_in;
        a_in      = t_a_in;
        c_in      = t_c_in;

        // Wait for rising edge where DUT registers the signals, then sample on next negedge
        @(negedge clk);
        test_count++;
        if (a_out === expected_a && c_out === expected_c) begin
            $display("[PASS] %s | a_out=%0d, c_out=%0d (hex: 0x%08h)",
                     description, a_out, c_out, c_out);
            pass_count++;
        end else begin
            $display("[FAIL] %s | Got a_out=%0d (exp %0d), c_out=%0d (exp %0d)",
                     description, a_out, expected_a, c_out, expected_c);
            fail_count++;
        end
    endtask

    // Main Test Sequence
    initial begin
        // Waveform dump for GTKWave visualization
        $dumpfile("pe_waves.vcd");
        $dumpvars(0, tb_pe);

        $display("================================================================");
        $display("   INT8 Processing Element (PE) Comprehensive Verification");
        $display("================================================================");

        // Initialize signals
        rst_n     = 0;
        weight_en = 0;
        en        = 0;
        clr       = 0;
        w_in      = 8'sd0;
        a_in      = 8'sd0;
        c_in      = 32'sd0;

        // -------------------------------------------------------------
        // TEST 1: Asynchronous Reset Assertion
        // -------------------------------------------------------------
        #(CLK_PERIOD * 2);
        test_count++;
        if (a_out === 8'sd0 && c_out === 32'sd0) begin
            $display("[PASS] Test 1: Asynchronous Reset Assertion (rst_n=0) | a_out=0, c_out=0");
            pass_count++;
        end else begin
            $display("[FAIL] Test 1: Reset failed | a_out=%0d, c_out=%0d", a_out, c_out);
            fail_count++;
        end

        // Release reset
        @(negedge clk);
        rst_n = 1;

        // -------------------------------------------------------------
        // TEST 2: Weight Configuration Phase & Priority over Compute
        // Set en=1 and attempt compute, but weight_en=1 MUST hold datapath
        // -------------------------------------------------------------
        step_and_check("Test 2: weight_en=1 Priority (Loads w=10, Holds Datapath)",
                       1'b1, 1'b1, 1'b0, 8'sd10, 8'sd25, 32'sd500,
                       8'sd0, 32'sd0);

        // -------------------------------------------------------------
        // TEST 3: Datapath Stall (weight_en=0, en=0)
        // -------------------------------------------------------------
        step_and_check("Test 3: Datapath Stall (en=0 holds previous state)",
                       1'b0, 1'b0, 1'b0, 8'sd0, 8'sd77, 32'sd888,
                       8'sd0, 32'sd0);

        // -------------------------------------------------------------
        // TEST 4: Normal Compute - Quadrant I (Pos x Pos)
        // w=10, a=5, c_in=20 -> c_out = (5 * 10) + 20 = 70
        // -------------------------------------------------------------
        step_and_check("Test 4: Pos x Pos (5 x 10 + 20)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd5, 32'sd20,
                       8'sd5, 32'sd70);

        // -------------------------------------------------------------
        // TEST 5: Normal Compute - Quadrant II (Pos x Neg)
        // First load w = -6
        // -------------------------------------------------------------
        step_and_check("Test 5.Load: Load w = -6",
                       1'b1, 1'b0, 1'b0, -8'sd6, 8'sd0, 32'sd0,
                       8'sd5, 32'sd70); // Datapath holds (5, 70) during weight load

        step_and_check("Test 5: Pos x Neg (8 x -6 + 100)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd8, 32'sd100,
                       8'sd8, 32'sd52);

        // -------------------------------------------------------------
        // TEST 6: Normal Compute - Quadrant III (Neg x Neg)
        // w = -6, a = -9, c_in = -40 -> c_out = (-9 * -6) + (-40) = 54 - 40 = 14
        // -------------------------------------------------------------
        step_and_check("Test 6: Neg x Neg (-9 x -6 + -40)",
                       1'b0, 1'b1, 1'b0, 8'sd0, -8'sd9, -32'sd40,
                       -8'sd9, 32'sd14);

        // -------------------------------------------------------------
        // TEST 7: Normal Compute - Quadrant IV (Neg x Pos)
        // Load w = 7
        // -------------------------------------------------------------
        step_and_check("Test 7.Load: Load w = 7",
                       1'b1, 1'b0, 1'b0, 8'sd7, 8'sd0, 32'sd0,
                       -8'sd9, 32'sd14);

        step_and_check("Test 7: Neg x Pos (-11 x 7 + 30)",
                       1'b0, 1'b1, 1'b0, 8'sd0, -8'sd11, 32'sd30,
                       -8'sd11, -32'sd47);

        // -------------------------------------------------------------
        // TEST 8: Extreme Two's Complement Corner Cases
        // Case 8A: Max Positive Limits: +127 x +127 = +16,129
        // -------------------------------------------------------------
        step_and_check("Test 8A.Load: Load w = 127",
                       1'b1, 1'b0, 1'b0, 8'sd127, 8'sd0, 32'sd0,
                       -8'sd11, -32'sd47);

        step_and_check("Test 8A: Max Pos Boundary (+127 x +127)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd127, 32'sd0,
                       8'sd127, 32'sd16129);

        // Case 8B: Extreme Negative Corner: -128 x -128 = +16,384
        step_and_check("Test 8B.Load: Load w = -128",
                       1'b1, 1'b0, 1'b0, -8'sd128, 8'sd0, 32'sd0,
                       8'sd127, 32'sd16129);

        step_and_check("Test 8B: Extreme Neg Boundary (-128 x -128)",
                       1'b0, 1'b1, 1'b0, 8'sd0, -8'sd128, 32'sd0,
                       -8'sd128, 32'sd16384);

        // Case 8C: Mixed Extremes: +127 x -128 = -16,256
        step_and_check("Test 8C: Mixed Extreme (+127 x -128)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd127, 32'sd0,
                       8'sd127, -32'sd16256);

        // -------------------------------------------------------------
        // TEST 9: Zero Multiplication Pass-Through
        // -------------------------------------------------------------
        step_and_check("Test 9A: Zero Activation (0 x -128 + 12345)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd0, 32'sd12345,
                       8'sd0, 32'sd12345);

        step_and_check("Test 9B.Load: Load w = 0",
                       1'b1, 1'b0, 1'b0, 8'sd0, 8'sd0, 32'sd0,
                       8'sd0, 32'sd12345);

        step_and_check("Test 9B: Zero Weight (88 x 0 + 54321)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd88, 32'sd54321,
                       8'sd88, 32'sd54321);

        // -------------------------------------------------------------
        // TEST 10: Synchronous Clear Priority (en=1, clr=1)
        // -------------------------------------------------------------
        step_and_check("Test 10: Synchronous Clear (clr=1 forces c_out=0, passes a_in)",
                       1'b0, 1'b1, 1'b1, 8'sd0, 8'sd42, 32'sd99999,
                       8'sd42, 32'sd0);

        // -------------------------------------------------------------
        // TEST 11: Two's-Complement 32-bit Modular Overflow Wrapping
        // -------------------------------------------------------------
        step_and_check("Test 11.Load: Load w = 10",
                       1'b1, 1'b0, 1'b0, 8'sd10, 8'sd0, 32'sd0,
                       8'sd42, 32'sd0);

        step_and_check("Test 11: 32-bit Signed Overflow Wrap-around",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd100, 32'sh7FFFFF00,
                       8'sd100, 32'sh800002E8);

        // -------------------------------------------------------------
        // TEST 12: Multi-Cycle Streaming Accumulation
        // w = 3; stream [10, 20, 30, 40]
        // -------------------------------------------------------------
        step_and_check("Test 12.Load: Load w = 3",
                       1'b1, 1'b0, 1'b0, 8'sd3, 8'sd0, 32'sd0,
                       8'sd100, 32'sh800002E8);

        step_and_check("Test 12.0: Stream Step 0 (10 x 3 + 0)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd10, 32'sd0,
                       8'sd10, 32'sd30);

        step_and_check("Test 12.1: Stream Step 1 (20 x 3 + 30)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd20, 32'sd30,
                       8'sd20, 32'sd90);

        step_and_check("Test 12.2: Stream Step 2 (30 x 3 + 90)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd30, 32'sd90,
                       8'sd30, 32'sd180);

        step_and_check("Test 12.3: Stream Step 3 (40 x 3 + 180)",
                       1'b0, 1'b1, 1'b0, 8'sd0, 8'sd40, 32'sd180,
                       8'sd40, 32'sd300);

        // -------------------------------------------------------------
        // Final Summary Banner
        // -------------------------------------------------------------
        $display("================================================================");
        $display(" PE VERIFICATION SUMMARY: Total: %0d | PASSED: %0d | FAILED: %0d",
                 test_count, pass_count, fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display(">>> ALL %0d TESTS PASSED WITH 100%% INTEGRITY! <<<", test_count);
        end else begin
            $display(">>> FAILED: %0d errors detected in PE implementation. <<<", fail_count);
        end

        $finish;
    end

endmodule
