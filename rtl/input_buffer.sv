`timescale 1ns / 1ps

/**
 * Module: input_buffer
 * Description: Synthesizable Parameterized FIFO Buffer with Valid/Ready Handshaking.
 *              Guarantees zero data loss under backpressure (m_ready low).
 *              Supports simultaneous read and write operations.
 */
module input_buffer #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 16
) (
    input  logic                   clk,
    input  logic                   rst_n,      // Asynchronous active-low reset
    input  logic                   clr,        // Synchronous clear / flush

    // Upstream / Producer Interface
    input  logic                   s_valid,
    output logic                   s_ready,
    input  logic [DATA_WIDTH-1:0]  s_data,

    // Downstream / Consumer Interface
    output logic                   m_valid,
    input  logic                   m_ready,
    output logic [DATA_WIDTH-1:0]  m_data,

    // Status flags
    output logic                   full,
    output logic                   empty,
    output logic [$clog2(DEPTH):0] count
);

    localparam int ADDR_WIDTH = $clog2(DEPTH);

    // Storage memory
    logic [DATA_WIDTH-1:0] mem [DEPTH-1:0];

    // Pointers and counter
    logic [ADDR_WIDTH-1:0] wr_ptr;
    logic [ADDR_WIDTH-1:0] rd_ptr;
    logic [ADDR_WIDTH:0]   occupancy;

    // Transaction handshakes
    wire wr_en = s_valid && s_ready;
    wire rd_en = m_valid && m_ready;

    // Handshake and status assignments
    assign full    = (occupancy == DEPTH);
    assign empty   = (occupancy == 0);
    assign s_ready = !full || rd_en; // Can accept new data if reading simultaneously
    assign m_valid = !empty;
    assign m_data  = mem[rd_ptr];
    assign count   = occupancy;

    // Sequential logic for memory write, pointer increment, and occupancy tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            occupancy <= '0;
        end else if (clr) begin
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            occupancy <= '0;
        end else begin
            // Memory write
            if (wr_en) begin
                mem[wr_ptr] <= s_data;
                wr_ptr      <= (wr_ptr == DEPTH - 1) ? '0 : wr_ptr + 1'b1;
            end

            // Memory read pointer update
            if (rd_en) begin
                rd_ptr <= (rd_ptr == DEPTH - 1) ? '0 : rd_ptr + 1'b1;
            end

            // Occupancy update
            case ({wr_en, rd_en})
                2'b10: occupancy <= occupancy + 1'b1; // Write only
                2'b01: occupancy <= occupancy - 1'b1; // Read only
                default: occupancy <= occupancy;      // Both or neither: occupancy unchanged
            endcase
        end
    end

endmodule
