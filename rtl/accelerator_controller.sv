`timescale 1ns / 1ps

/**
 * Module: accelerator_controller
 * Description: FSM Controller for the 4x4 INT8 Systolic Array Accelerator.
 *              Sequences weight configuration with valid/ready handshake flow control,
 *              activation skewing, systolic compute, and result retirement.
 */
module accelerator_controller #(
    parameter int ARRAY_SIZE = 4
) (
    input  logic                                clk,
    input  logic                                rst_n,

    // Weight Configuration Handshake Port
    input  logic                                weight_valid,
    output logic                                weight_ready,
    output logic                                weights_loaded,
    output logic [ARRAY_SIZE-1:0]               weight_en,

    // Compute Trigger & Handshake
    input  logic                                start_compute,
    output logic                                compute_ready,

    // Systolic Array Controls
    output logic                                array_en,
    output logic                                array_clr,

    // Feeder cycle count & window
    output logic [4:0]                          feed_cycle,
    output logic                                feeding_active,

    // State & Status
    output logic                                busy,
    output logic                                done
);

    typedef enum logic [1:0] {
        IDLE            = 2'b00,
        LOAD_WEIGHTS    = 2'b01,
        FEED_AND_DRAIN  = 2'b10,
        COMPLETE        = 2'b11
    } state_t;

    state_t state, next_state;

    // Cycle counter for compute and drain
    logic [4:0] cycle_cnt;

    // Row counter for weight configuration
    logic [$clog2(ARRAY_SIZE)-1:0] weight_row_cnt;
    logic                          weights_loaded_reg;

    // Handshake detection
    wire weight_handshake = weight_valid && weight_ready;

    // Execution schedule:
    // Activations fed from cycle 0 to 6.
    // Last element C[3][3] emerges at South port at cycle 10 and is latched at cycle 11.
    // TOTAL_COMPUTE_CYCLES = 11: at cycle 11, all elements are captured in result_matrix.
    localparam int TOTAL_COMPUTE_CYCLES = 11;

    // Sequential state updates
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= IDLE;
            cycle_cnt          <= '0;
            weight_row_cnt     <= '0;
            weights_loaded_reg <= 1'b0;
        end else begin
            state <= next_state;

            // Compute cycle counter
            if (state != next_state) begin
                cycle_cnt <= '0;
            end else if (state == FEED_AND_DRAIN) begin
                cycle_cnt <= cycle_cnt + 1'b1;
            end

            // Weight configuration row counter and loaded status
            case (state)
                IDLE: begin
                    if (weight_handshake) begin
                        // First row accepted on transition to LOAD_WEIGHTS
                        weight_row_cnt     <= weight_row_cnt + 1'b1;
                        weights_loaded_reg <= 1'b0;
                    end
                end

                LOAD_WEIGHTS: begin
                    if (weight_handshake) begin
                        if (weight_row_cnt == ARRAY_SIZE - 1) begin
                            weight_row_cnt     <= '0;
                            weights_loaded_reg <= 1'b1; // All rows successfully latched
                        end else begin
                            weight_row_cnt     <= weight_row_cnt + 1'b1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    // Next-state logic
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (weight_handshake) begin
                    next_state = LOAD_WEIGHTS;
                end else if (start_compute) begin
                    next_state = FEED_AND_DRAIN;
                end
            end

            LOAD_WEIGHTS: begin
                if (weight_handshake && (weight_row_cnt == ARRAY_SIZE - 1)) begin
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

    // Status assignments
    assign busy           = (state != IDLE) || (state == IDLE && weight_valid);
    assign weight_ready   = (state == IDLE || state == LOAD_WEIGHTS);
    assign compute_ready  = (state == IDLE && !weight_valid);
    assign done           = (state == COMPLETE);
    assign weights_loaded = weights_loaded_reg;

    // Systolic array controls
    assign array_en       = (state == FEED_AND_DRAIN);
    assign array_clr      = 1'b0;

    // Weight write-enable decode: one-hot active ONLY on valid handshake cycles
    always_comb begin
        weight_en = '0;
        if ((state == IDLE || state == LOAD_WEIGHTS) && weight_handshake) begin
            weight_en = (1'b1 << weight_row_cnt);
        end
    end

    assign feed_cycle     = cycle_cnt;
    assign feeding_active = (state == FEED_AND_DRAIN && cycle_cnt < 7);

endmodule
