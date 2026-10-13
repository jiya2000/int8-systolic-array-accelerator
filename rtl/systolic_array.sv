`timescale 1ns / 1ps

/**
 * Module: systolic_array
 * Description: Synthesizable Parameterized 2D Weight-Stationary Systolic Array.
 *              Default configuration: 4x4 Processing Elements (PEs).
 *              Activations flow West-to-East.
 *              Partial sums flow North-to-South.
 *              Weights are pre-loaded per row.
 */
module systolic_array #(
    parameter int ARRAY_SIZE = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic                                            en,          // Global compute enable
    input  logic                                            clr,         // Global accumulator clear
    input  logic [ARRAY_SIZE-1:0]                           weight_en,   // Per-row weight write enable
    input  logic signed [DATA_WIDTH-1:0]                    w_in  [ARRAY_SIZE-1:0], // Weight columns [0..3]
    input  logic signed [DATA_WIDTH-1:0]                    a_in  [ARRAY_SIZE-1:0], // West activation inputs [0..3]
    input  logic signed [ACC_WIDTH-1:0]                     c_in  [ARRAY_SIZE-1:0], // North partial sum inputs [0..3]
    output logic signed [DATA_WIDTH-1:0]                    a_out [ARRAY_SIZE-1:0], // East activation outputs [0..3]
    output logic signed [ACC_WIDTH-1:0]                     c_out [ARRAY_SIZE-1:0]  // South partial sum outputs [0..3]
);

    // Internal activation interconnect: [row][col] where col extends from 0 to ARRAY_SIZE
    logic signed [DATA_WIDTH-1:0] a_wire [ARRAY_SIZE-1:0][ARRAY_SIZE:0];

    // Internal partial sum interconnect: [row][col] where row extends from 0 to ARRAY_SIZE
    logic signed [ACC_WIDTH-1:0]  c_wire [ARRAY_SIZE:0][ARRAY_SIZE-1:0];

    // Connect boundary inputs and outputs
    genvar r, c;
    generate
        // Boundary West and East connections
        for (r = 0; r < ARRAY_SIZE; r++) begin : gen_west_east_boundary
            assign a_wire[r][0]          = a_in[r];
            assign a_out[r]              = a_wire[r][ARRAY_SIZE];
        end

        // Boundary North and South connections
        for (c = 0; c < ARRAY_SIZE; c++) begin : gen_north_south_boundary
            assign c_wire[0][c]          = c_in[c];
            assign c_out[c]              = c_wire[ARRAY_SIZE][c];
        end

        // 2D Processing Element Grid
        for (r = 0; r < ARRAY_SIZE; r++) begin : gen_rows
            for (c = 0; c < ARRAY_SIZE; c++) begin : gen_cols
                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .weight_en (weight_en[r]),
                    .en        (en),
                    .clr       (clr),
                    .w_in      (w_in[c]),
                    .a_in      (a_wire[r][c]),
                    .c_in      (c_wire[r][c]),
                    .a_out     (a_wire[r][c+1]),
                    .c_out     (c_wire[r+1][c])
                );
            end
        end
    endgenerate

endmodule
