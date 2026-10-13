`timescale 1ns / 1ps

/**
 * Module: int8_accelerator_top
 * Description: Top-Level Synthesizable Integration of the INT8 Systolic Array Accelerator IP.
 *              Includes:
 *                - 4x4 Weight-Stationary Systolic Array
 *                - FSM Accelerator Controller
 *                - Row-by-row Weight Configuration Port with direct handshake tracking
 *                - AXI-Stream-inspired Activation Input Port
 *                - AXI-Stream-inspired Result Output Port with full backpressure
 *              Uses flattened vector ports for 100% universal EDA synthesis compatibility.
 */
module int8_accelerator_top #(
    parameter int ARRAY_SIZE = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                                            clk,
    input  logic                                            rst_n,

    // Weight Configuration Port (4 rows x 4 cols flattened: 32 bits)
    input  logic                                            s_weight_valid,
    output logic                                            s_weight_ready,
    input  logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       s_weight_data,

    // Activation Input Stream (Row-by-row stream of 4x4 matrix A: 32 bits)
    input  logic                                            s_axis_tvalid,
    output logic                                            s_axis_tready,
    input  logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0]       s_axis_tdata,
    input  logic                                            s_axis_tlast,

    // Result Output Stream (Row-by-row stream of 4x4 matrix C: 128 bits)
    output logic                                            m_axis_tvalid,
    input  logic                                            m_axis_tready,
    output logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]        m_axis_tdata,
    output logic                                            m_axis_tlast,

    // Accelerator Status
    output logic                                            busy,
    output logic                                            done
);

    // Controller signals
    logic                   start_compute;
    logic                   compute_ready;
    logic                   array_en;
    logic                   array_clr;
    logic [4:0]             feed_cycle;
    logic                   feeding_active;
    logic                   ctrl_busy;
    logic                   ctrl_done;

    // Weight loading tracking
    logic [1:0]             weight_row_cnt;
    logic                   weights_loaded;
    logic [ARRAY_SIZE-1:0]  weight_en_comb;

    // Buffer to hold Activation Matrix A (4 rows x 4 cols)
    logic signed [DATA_WIDTH-1:0] A_matrix [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0];
    logic [1:0]                   act_load_idx;
    logic                         act_loaded;

    // Skewed array input signals
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] a_in_skewed;
    logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]  c_in_boundary;
    logic signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] a_out_unused;
    logic signed [(ARRAY_SIZE*ACC_WIDTH)-1:0]  c_out_array;

    // Result storage matrix (4 rows x 4 cols)
    logic signed [ACC_WIDTH-1:0]  result_matrix [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0];
    logic [1:0]                   out_stream_idx;
    logic                         out_streaming;

    // Boundary partial sums are tied to zero
    assign c_in_boundary = '0;

    // -------------------------------------------------------------
    // Weight Configuration Port Handshake
    // -------------------------------------------------------------
    assign s_weight_ready = !ctrl_busy && !out_streaming;

    // Combinational one-hot weight enable to PEs
    always_comb begin
        weight_en_comb = '0;
        if (s_weight_valid && s_weight_ready) begin
            case (weight_row_cnt)
                2'd0: weight_en_comb = 4'b0001;
                2'd1: weight_en_comb = 4'b0010;
                2'd2: weight_en_comb = 4'b0100;
                2'd3: weight_en_comb = 4'b1000;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_row_cnt <= '0;
            weights_loaded <= 1'b0;
        end else if (s_weight_valid && s_weight_ready) begin
            if (weight_row_cnt == ARRAY_SIZE - 1) begin
                weight_row_cnt <= '0;
                weights_loaded <= 1'b1;
            end else begin
                weight_row_cnt <= weight_row_cnt + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------
    // Activation Stream Buffer Handshake
    // -------------------------------------------------------------
    assign s_axis_tready = compute_ready && !act_loaded && !ctrl_busy && !out_streaming;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_load_idx <= '0;
            act_loaded   <= 1'b0;
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    A_matrix[r][c] <= '0;
                end
            end
        end else if (s_axis_tvalid && s_axis_tready) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A_matrix[act_load_idx][c] <= s_axis_tdata[c*DATA_WIDTH +: DATA_WIDTH];
            end

            if (act_load_idx == ARRAY_SIZE - 1 || s_axis_tlast) begin
                act_load_idx <= '0;
                act_loaded   <= 1'b1;
            end else begin
                act_load_idx <= act_load_idx + 1'b1;
            end
        end else if (ctrl_done) begin
            act_loaded <= 1'b0;
        end
    end

    // Compute triggers once both weights and activations are buffered
    assign start_compute = weights_loaded && act_loaded && compute_ready && !ctrl_busy && !out_streaming;

    // -------------------------------------------------------------
    // Activation Skewing Logic
    // Row k of array gets A[t - k][k] when 0 <= t - k < 4, else 0
    // -------------------------------------------------------------
    always_comb begin
        a_in_skewed = '0;
        if (feeding_active) begin
            for (int k = 0; k < ARRAY_SIZE; k++) begin
                if (feed_cycle >= k && feed_cycle < (k + ARRAY_SIZE)) begin
                    case (feed_cycle - k)
                        5'd0: a_in_skewed[k*DATA_WIDTH +: DATA_WIDTH] = A_matrix[0][k];
                        5'd1: a_in_skewed[k*DATA_WIDTH +: DATA_WIDTH] = A_matrix[1][k];
                        5'd2: a_in_skewed[k*DATA_WIDTH +: DATA_WIDTH] = A_matrix[2][k];
                        5'd3: a_in_skewed[k*DATA_WIDTH +: DATA_WIDTH] = A_matrix[3][k];
                        default: a_in_skewed[k*DATA_WIDTH +: DATA_WIDTH] = '0;
                    endcase
                end
            end
        end
    end

    // -------------------------------------------------------------
    // Instantiate Accelerator Controller
    // -------------------------------------------------------------
    accelerator_controller #(
        .ARRAY_SIZE(ARRAY_SIZE)
    ) u_controller (
        .clk               (clk),
        .rst_n             (rst_n),
        .start_weight_load (1'b0),
        .start_compute     (start_compute),
        .weight_load_ready (),
        .compute_ready     (compute_ready),
        .array_en          (array_en),
        .array_clr         (array_clr),
        .weight_en         (),
        .weight_row_idx    (),
        .feed_cycle        (feed_cycle),
        .feeding_active    (feeding_active),
        .busy              (ctrl_busy),
        .done              (ctrl_done)
    );

    // -------------------------------------------------------------
    // Instantiate 4x4 Systolic Array
    // -------------------------------------------------------------
    systolic_array #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_systolic_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (array_en),
        .clr       (array_clr),
        .weight_en (weight_en_comb),
        .w_in      (s_weight_data),
        .a_in      (a_in_skewed),
        .c_in      (c_in_boundary),
        .a_out     (a_out_unused),
        .c_out     (c_out_array)
    );

    // -------------------------------------------------------------
    // Output Result De-skewing & Capture
    // Output C[i][j] arrives at c_out_array[j] at cycle (i + 4 + j)
    // -------------------------------------------------------------
    genvar r_res, c_res;
    generate
        for (r_res = 0; r_res < ARRAY_SIZE; r_res++) begin : gen_res_row
            for (c_res = 0; c_res < ARRAY_SIZE; c_res++) begin : gen_res_col
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        result_matrix[r_res][c_res] <= '0;
                    end else if (array_en) begin
                        if (feed_cycle == (r_res + 4 + c_res)) begin
                            result_matrix[r_res][c_res] <= c_out_array[c_res*ACC_WIDTH +: ACC_WIDTH];
                        end
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------
    // Output Streamer FSM with Backpressure Handling
    // -------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_streaming  <= 1'b0;
            out_stream_idx <= '0;
        end else begin
            if (ctrl_done) begin
                out_streaming  <= 1'b1;
                out_stream_idx <= '0;
            end else if (out_streaming) begin
                if (m_axis_tready && m_axis_tvalid) begin
                    if (out_stream_idx == ARRAY_SIZE - 1) begin
                        out_streaming  <= 1'b0;
                        out_stream_idx <= '0;
                    end else begin
                        out_stream_idx <= out_stream_idx + 1'b1;
                    end
                end
            end
        end
    end

    // Assign Output Stream Signals
    assign m_axis_tvalid = out_streaming;
    assign m_axis_tlast  = out_streaming && (out_stream_idx == ARRAY_SIZE - 1);

    genvar out_c;
    generate
        for (out_c = 0; out_c < ARRAY_SIZE; out_c++) begin : gen_out_stream
            assign m_axis_tdata[out_c*ACC_WIDTH +: ACC_WIDTH] = result_matrix[out_stream_idx][out_c];
        end
    endgenerate

    assign busy = ctrl_busy || out_streaming || act_loaded;
    assign done = ctrl_done;

endmodule
