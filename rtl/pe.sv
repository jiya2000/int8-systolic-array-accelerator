`timescale 1ns / 1ps

/**
 * Module: pe
 * Description: Synthesizable Processing Element (PE) for a Weight-Stationary Systolic Array.
 *              Implements signed INT8 multiplication with 32-bit partial-sum accumulation.
 *              Strictly enforces control priority:
 *                1. Asynchronous active-low reset (rst_n)
 *                2. Weight write-enable (weight_en): loads weight, holds a_out & c_out
 *                3. Datapath enable (en):
 *                   - If clr == 1: a_out <= a_in, c_out <= 0
 *                   - If clr == 0: a_out <= a_in, c_out <= c_in + (a_in * weight_reg)
 *                4. Stall (en == 0): all registers hold state
 */
module pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                          clk,
    input  logic                          rst_n,      // Asynchronous active-low reset
    input  logic                          weight_en,  // Weight configuration enable (highest active priority)
    input  logic                          en,         // Datapath compute enable
    input  logic                          clr,        // Synchronous accumulator clear
    input  logic signed [DATA_WIDTH-1:0]  w_in,       // Stationary weight to load
    input  logic signed [DATA_WIDTH-1:0]  a_in,       // Activation input (West port)
    input  logic signed [ACC_WIDTH-1:0]   c_in,       // Partial sum input (North port)
    output logic signed [DATA_WIDTH-1:0]  a_out,      // Registered activation (East port)
    output logic signed [ACC_WIDTH-1:0]   c_out       // Registered partial sum (South port)
);

    // Stationary weight storage
    logic signed [DATA_WIDTH-1:0] weight_reg;

    // Intermediate 16-bit signed product (for 8x8 signed operands)
    localparam int PROD_WIDTH = DATA_WIDTH * 2;
    logic signed [PROD_WIDTH-1:0] mult_result;
    logic signed [ACC_WIDTH-1:0]  mult_ext;
    logic signed [ACC_WIDTH-1:0]  next_c;

    // Combinational datapath: signed multiplication and accumulation
    always_comb begin
        mult_result = a_in * weight_reg;
        mult_ext    = $signed(mult_result); // Automatic sign-extension to ACC_WIDTH

        if (clr) begin
            next_c = '0;
        end else begin
            next_c = c_in + mult_ext; // Two's complement modular accumulation
        end
    end

    // Sequential state updates strictly implementing control priority
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Condition 1: Asynchronous Reset
            weight_reg <= '0;
            a_out      <= '0;
            c_out      <= '0;
        end else if (weight_en) begin
            // Condition 2: Weight Configuration Phase (holds datapath)
            weight_reg <= w_in;
        end else if (en) begin
            // Condition 4 & 5: Compute Phase
            a_out <= a_in;
            c_out <= next_c;
        end
        // Condition 3 (en == 0): All registers implicitly hold their values
    end

endmodule
