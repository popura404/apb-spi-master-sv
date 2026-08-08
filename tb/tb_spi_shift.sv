`timescale 1ns/1ps
`default_nettype none

module tb_spi_shift;
    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst_n = 1'b0;
    reg abort = 1'b0;
    reg start = 1'b0;
    reg [15:0] divider = 16'd1;
    reg cpol = 1'b0;
    reg cpha = 1'b0;
    reg lsb_first = 1'b0;
    reg loopback = 1'b0;
    reg [7:0] tx_data = 8'h00;
    reg miso = 1'b0;
    wire busy, done, sclk, mosi;
    wire [7:0] rx_data;

    spi_shift dut (.*);

    integer cases_run = 0;
    reg [31:0] random_state = 32'h19ad3587;

    function automatic bit serial_bit(input [7:0] value, input integer index,
                                      input bit low_first);
        serial_bit = low_first ? value[index] : value[7-index];
    endfunction

    task automatic transfer(input [7:0] sent, input [7:0] received,
                            input integer mode, input bit low_first,
                            input bit local_loop, input integer div_value);
        integer cycle, edges, samples;
        bit previous_sclk;
        begin
            @(negedge clk);
            cpol = (mode >> 1) & 1;
            cpha = mode & 1;
            lsb_first = low_first;
            loopback = local_loop;
            divider = div_value;
            tx_data = sent;
            miso = serial_bit(received, 0, low_first);
            @(posedge clk); #1;
            if (sclk !== cpol) $fatal(1, "Idle polarity: mode %0d", mode);
            @(negedge clk); start = 1;
            @(posedge clk); #1;
            if (!busy || done || sclk !== cpol) $fatal(1, "Start state");
            previous_sclk = sclk;
            edges = 0;
            samples = 0;
            @(negedge clk); start = 0;
            for (cycle = 1; cycle <= 16*div_value; cycle = cycle+1) begin
                @(posedge clk); #1;
                if (cycle % div_value == 0) begin
                    if (sclk !== !previous_sclk)
                        $fatal(1, "Missing edge: mode %0d div %0d cycle %0d", mode, div_value, cycle);
                    if ((edges % 2) == cpha) begin
                        if (mosi !== serial_bit(sent, samples, low_first))
                            $fatal(1, "MOSI: mode %0d order %0d bit %0d", mode, low_first, samples);
                        samples = samples+1;
                    end
                    edges = edges+1;
                end else if (sclk !== previous_sclk) begin
                    $fatal(1, "Early SCLK edge");
                end
                if (!busy || done) $fatal(1, "Completion before hold interval");
                previous_sclk = sclk;
                if (cycle < 16*div_value) begin
                    @(negedge clk);
                    miso = serial_bit(received, (samples < 8) ? samples : 7, low_first);
                    // A repeated start while busy must not restart the byte.
                    start = (cycle == 4*div_value);
                end
            end
            if (edges != 16 || samples != 8 || sclk !== cpol) $fatal(1, "Byte framing");
            @(posedge clk); #1;
            if (busy || !done || rx_data !== (local_loop ? sent : received))
                $fatal(1, "RX/completion: mode %0d order %0d loop %0d got %h want %h",
                       mode, low_first, local_loop, rx_data, local_loop ? sent : received);
            @(posedge clk); #1;
            if (done) $fatal(1, "DONE pulse exceeds one cycle");
            cases_run = cases_run+1;
        end
    endtask

    task automatic abort_transfer(input integer mode, input integer delay_cycles);
        begin
            @(negedge clk);
            cpol = (mode >> 1) & 1;
            cpha = mode & 1;
            divider = 1;
            start = 1;
            @(posedge clk); #1;
            @(negedge clk); start = 0;
            repeat (delay_cycles) @(negedge clk);
            abort = 1;
            start = 1; // Abort must also beat a simultaneous start.
            @(posedge clk); #1;
            if (busy || done || sclk !== cpol) $fatal(1, "Abort priority/idle");
            @(negedge clk); abort = 0; start = 0;
            repeat (3) begin
                @(posedge clk); #1;
                if (busy || done || sclk !== cpol) $fatal(1, "Late completion after abort");
            end
            cases_run = cases_run+1;
        end
    endtask

    integer mode, order, local_loop, div_index, trial;
    integer test_divider;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (mode = 0; mode < 4; mode = mode+1)
            for (order = 0; order < 2; order = order+1)
                for (local_loop = 0; local_loop < 2; local_loop = local_loop+1)
                    for (div_index = 0; div_index < 3; div_index = div_index+1) begin
                        case (div_index)
                            0: test_divider = 1;
                            1: test_divider = 2;
                            default: test_divider = 7;
                        endcase
                        for (trial = 0; trial < 10; trial = trial+1) begin
                            random_state = random_state * 32'd1664525 + 32'd1013904223;
                            transfer(random_state[7:0], random_state[23:16], mode,
                                     order != 0, local_loop != 0, test_divider);
                        end
                    end
        for (mode = 0; mode < 4; mode = mode+1) begin
            abort_transfer(mode, 0);
            abort_transfer(mode, 5);
            abort_transfer(mode, 16); // Abort in final-edge hold interval.
        end
        transfer(8'ha6, 8'h39, 0, 0, 0, 1);
        $display("PASS tb_spi_shift: %0d transfer/abort cases", cases_run);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "SPI unit test timeout");
    end
endmodule

`default_nettype wire
