`timescale 1ns/1ps
`default_nettype none

module tb_sync_fifo;
    parameter DEPTH = 4;
    localparam WIDTH = 8;
    reg clk = 1'b0;
    always #5 clk = !clk;
    reg rst_n = 1'b0;
    reg clear = 1'b0;
    reg push = 1'b0;
    reg pop = 1'b0;
    reg [WIDTH-1:0] din = 0;
    wire [WIDTH-1:0] dout;
    wire empty, full;
    wire [$clog2(DEPTH):0] level;

    sync_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (.*);

    reg [7:0] expected [0:DEPTH-1];
    integer count = 0;
    integer read_index = 0;
    integer write_index = 0;
    integer cases_run = 0;
    reg [31:0] random_state = 32'hc04912ad;

    task automatic check_outputs;
        begin
            if (level !== count || empty !== (count == 0) || full !== (count == DEPTH))
                $fatal(1, "FIFO flags/count: got %0d expected %0d", level, count);
            if (dout !== ((count == 0) ? 8'h00 : expected[read_index]))
                $fatal(1, "FIFO head mismatch at operation %0d", cases_run);
        end
    endtask

    task automatic step(input bit do_push, input bit do_pop,
                        input [7:0] value, input bit do_clear);
        bit accepted_push, accepted_pop;
        begin
            @(negedge clk);
            push = do_push;
            pop = do_pop;
            din = value;
            clear = do_clear;
            check_outputs();
            accepted_push = do_push && count < DEPTH;
            accepted_pop = do_pop && count > 0;
            if (do_clear) begin
                count = 0;
                read_index = 0;
                write_index = 0;
            end else begin
                if (accepted_push) begin
                    expected[write_index] = value;
                    write_index = (write_index+1) % DEPTH;
                end
                if (accepted_pop)
                    read_index = (read_index+1) % DEPTH;
                count = count + int'(accepted_push) - int'(accepted_pop);
            end
            @(posedge clk); #1;
            cases_run = cases_run+1;
            check_outputs();
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        step(0, 1, 0, 0); // Underflow is ignored.
        step(1, 1, 8'h3c, 0); // At empty only push succeeds.
        for (i = 1; i < DEPTH; i = i+1) step(1, 0, i, 0);
        step(1, 0, 8'hff, 0); // Overflow is ignored.
        step(1, 1, 8'hee, 0); // At full only pop succeeds.
        step(1, 1, 8'h65, 0); // Both succeed away from boundaries.
        for (i = 0; i < DEPTH; i = i+1) step(0, 1, 0, 0);
        for (i = 0; i < 2000; i = i+1) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            step(random_state[31], random_state[27], random_state[15:8],
                 random_state[6:0] == 7'h7f);
        end
        step(1, 1, 8'hff, 1); // Clear has priority over both operations.
        @(negedge clk); rst_n = 0;
        #1; check_outputs();
        $display("PASS tb_sync_fifo: DEPTH=%0d, %0d operations", DEPTH, cases_run);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FIFO unit test timeout");
    end
endmodule

`default_nettype wire
