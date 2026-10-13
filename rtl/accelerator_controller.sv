`timescale 1ns / 1ps

/**
 * Module: accelerator_controller
 * Description: FSM Controller for the 4x4 INT8 Systolic Array Accelerator.
 *              Sequences weight configuration, activation skewing,
 *              systolic compute, and result retirement.
 */
module accelerator_controller #(
    parameter int ARRAY_SIZE = 4
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // High-level transaction commands
    input  logic                   start_weight_load,
    input  logic                   start_compute,
    output logic                   weight_load_ready,
    output logic                   compute_ready,

    // Systolic Array Controls
    output logic                   array_en,
    output logic                   array_clr,
    output logic [ARRAY_SIZE-1:0]  weight_en,
    output logic [1:0]             weight_row_idx,

    // Feeder cycle count
    output logic [4:0]             feed_cycle,
    output logic                   feeding_active,

    // State & Status
    output logic                   busy,
    output logic                   done
);

    typedef enum logic [1:0] {
        IDLE            = 2'b00,
        LOAD_WEIGHTS    = 2'b01,
        FEED_AND_DRAIN  = 2'b10,
        COMPLETE        = 2'b11
    } state_t;

    state_t state, next_state;

    // Cycle counter
    logic [4:0] cycle_cnt;

    // Execution schedule:
    // Activations fed from cycle 0 to 6.
    // Last element C[3][3] retires at cycle 10.
    // Cycle 11: all results registered.
    localparam int TOTAL_COMPUTE_CYCLES = 12;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            cycle_cnt <= '0;
        end else begin
            state <= next_state;
            if (state != next_state) begin
                cycle_cnt <= '0;
            end else if (state == LOAD_WEIGHTS || state == FEED_AND_DRAIN) begin
                cycle_cnt <= cycle_cnt + 1'b1;
            end
        end
    end

    // Next-state logic
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (start_weight_load) begin
                    next_state = LOAD_WEIGHTS;
                end else if (start_compute) begin
                    next_state = FEED_AND_DRAIN;
                end
            end

            LOAD_WEIGHTS: begin
                if (cycle_cnt >= ARRAY_SIZE - 1) begin
                    next_state = IDLE;
                end
            end

            FEED_AND_DRAIN: begin
                if (cycle_cnt >= TOTAL_COMPUTE_CYCLES) begin
                    next_state = COMPLETE;
                end
            end

            COMPLETE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Status
    assign busy              = (state != IDLE);
    assign weight_load_ready = (state == IDLE || state == LOAD_WEIGHTS);
    assign compute_ready     = (state == IDLE);
    assign done              = (state == COMPLETE);

    assign array_en          = (state == FEED_AND_DRAIN);
    assign array_clr         = (state == IDLE && start_compute);

    // One-hot weight write-enable decode
    always_comb begin
        weight_en = '0;
        if (state == LOAD_WEIGHTS) begin
            case (cycle_cnt[1:0])
                2'd0: weight_en = 4'b0001;
                2'd1: weight_en = 4'b0010;
                2'd2: weight_en = 4'b0100;
                2'd3: weight_en = 4'b1000;
            endcase
        end
    end

    assign weight_row_idx = cycle_cnt[1:0];
    assign feed_cycle     = cycle_cnt;
    assign feeding_active = (state == FEED_AND_DRAIN && cycle_cnt < 7);

endmodule
