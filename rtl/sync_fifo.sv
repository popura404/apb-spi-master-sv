`timescale 1ns / 1ps
`default_nettype none

// First-word fall-through FIFO. DEPTH must be a power of two, at least two.
module sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  wire logic                   clk,
    input  wire logic                   rst_n,
    input  wire logic                   clear,
    input  wire logic                   push,
    input  wire logic                   pop,
    input  wire logic [WIDTH-1:0]       din,
    output      logic [WIDTH-1:0]       dout,
    output      logic                   empty,
    output      logic                   full,
    output      logic [$clog2(DEPTH):0] level
);

    localparam int PTR_WIDTH = $clog2(DEPTH);

    logic [WIDTH-1:0] memory [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] write_pointer;
    logic [PTR_WIDTH-1:0] read_pointer;

    logic push_accept;
    logic pop_accept;

    assign push_accept = push && !full;
    assign pop_accept  = pop && !empty;
    assign empty = (level == 0);
    assign full  = (level == DEPTH);
    assign dout  = empty ? {WIDTH{1'b0}} : memory[read_pointer];

    // Keep storage free of reset logic so FPGA tools can infer distributed RAM.
    // Reset/clear only invalidate entries by resetting the pointers and count.
    always_ff @(posedge clk) begin
        if (rst_n && !clear && push_accept)
            memory[write_pointer] <= din;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer <= {PTR_WIDTH{1'b0}};
            read_pointer  <= {PTR_WIDTH{1'b0}};
            level         <= {(PTR_WIDTH+1){1'b0}};
        end else if (clear) begin
            write_pointer <= {PTR_WIDTH{1'b0}};
            read_pointer  <= {PTR_WIDTH{1'b0}};
            level         <= {(PTR_WIDTH+1){1'b0}};
        end else begin
            if (push_accept)
                write_pointer <= write_pointer + 1'b1;
            if (pop_accept)
                read_pointer <= read_pointer + 1'b1;

            case ({push_accept, pop_accept})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: begin end
            endcase
        end
    end

endmodule

`default_nettype wire
