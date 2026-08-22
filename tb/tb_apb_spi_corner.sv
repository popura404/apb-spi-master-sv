`timescale 1ns/1ps
`default_nettype none

// Target exact PCLK collisions not reached reliably by traffic-level tests.
// Hierarchical observations only confirm that each intended race was exercised.
module tb_apb_spi_corner;
    localparam [7:0] CTRL=8'h00, DIVIDER=8'h04, LENGTH=8'h0c,
        COMMAND=8'h10, TXDATA=8'h18, RXDATA=8'h1c,
        FIFO_LEVEL=8'h20, IRQ_STATUS=8'h24, IRQ_ENABLE=8'h28;
    reg pclk = 0;
    always #5 pclk = !pclk;
    reg presetn=0, psel=0, penable=0, pwrite=0;
    reg [7:0] paddr=0;
    reg [31:0] pwdata=0;
    wire [31:0] prdata;
    wire pready, pslverr, irq, spi_sclk, spi_mosi;
    wire [0:0] spi_cs_n;
    wire spi_miso = 1'b0;

    apb_spi_master #(.FIFO_DEPTH(2), .NUM_CS(1)) dut (.*);

    integer checks=0, races=0, serial_edges=0;
    reg monitor_edges=0;
    always @(spi_sclk)
        if (monitor_edges && !spi_cs_n[0]) serial_edges=serial_edges+1;

    task automatic check(input bit condition, input string message);
        begin
            checks=checks+1;
            if (!condition) $fatal(1, "%s at %0t", message, $time);
        end
    endtask

    // collision: 0 ordinary; 1 DONE/W1C; 2 final edge ABORT; 3 hold ABORT;
    // 4 DONE handoff ABORT; 5 full TX write/pop; 6 empty RX read/push.
    task automatic apb(input bit wr, input [7:0] address, input [31:0] data,
                       input bit expect_error, input integer collision,
                       output reg [31:0] result);
        begin
            @(negedge pclk);
            psel=1; penable=0; pwrite=wr; paddr=address; pwdata=data;
            #1; check(pslverr === 0, "PSLVERR during setup");
            @(negedge pclk); penable=1;
            #1;
            check(pready === 1 && pslverr === expect_error,
                  $sformatf("APB address %02x error %b expected %b", address, pslverr, expect_error));
            result=prdata;
            case (collision)
                1: check(dut.irq_events[0] && dut.irq_clear[0], "Missed DONE/W1C collision");
                2: check(dut.command_abort && dut.engine.edge_index == 15 &&
                         dut.engine.half_count == 0 && dut.engine.busy,
                         "Missed final-edge ABORT collision");
                3: check(dut.command_abort && dut.engine.finish_pending,
                         "Missed final-edge hold ABORT collision");
                4: check(dut.command_abort && dut.engine_done,
                         "Missed DONE handoff ABORT collision");
                5: check(dut.tx_full && dut.engine_start,
                         "Missed full TX software-write/hardware-pop collision");
                6: check(dut.rx_empty && dut.rx_push,
                         "Missed empty RX software-read/hardware-push collision");
                default: begin end
            endcase
            if (collision != 0) races=races+1;
            @(negedge pclk);
            psel=0; penable=0; pwrite=0; paddr=0; pwdata=0;
        end
    endtask

    task automatic write_reg(input [7:0] address, input [31:0] data);
        reg [31:0] ignored;
        apb(1, address, data, 0, 0, ignored);
    endtask

    task automatic expect_reg(input [7:0] address, input [31:0] expected);
        reg [31:0] actual;
        begin
            apb(0, address, 0, 0, 0, actual);
            check(actual === expected,
                  $sformatf("Register %02x got %08x expected %08x", address, actual, expected));
        end
    endtask

    task automatic prepare(input integer length_value);
        begin
            monitor_edges=0;
            @(negedge pclk); presetn=0; psel=0; penable=0;
            repeat (2) @(negedge pclk);
            presetn=1;
            write_reg(CTRL,17); // Mode 0, MSB first, loopback, enabled.
            write_reg(DIVIDER,1);
            write_reg(LENGTH,length_value);
            write_reg(IRQ_ENABLE,31);
            serial_edges=0;
            monitor_edges=1;
        end
    endtask

    task automatic test_done_clear;
        reg [31:0] ignored;
        begin
            prepare(1);
            write_reg(TXDATA,8'h96);
            write_reg(COMMAND,1);
            wait (serial_edges == 16);
            apb(1, IRQ_STATUS,1,0,1,ignored);
            expect_reg(IRQ_STATUS,1);
            check(irq === 1, "DONE lost to coincident W1C");
            expect_reg(RXDATA,8'h96);
            write_reg(IRQ_STATUS,1);
            check(irq === 0, "Later W1C failed to clear DONE");
            $display("PASS corner: DONE takes priority over simultaneous W1C");
        end
    endtask

    task automatic test_final_abort(input integer target_edges, input integer collision);
        reg [31:0] ignored;
        begin
            prepare(1);
            write_reg(TXDATA,8'h69);
            write_reg(TXDATA,8'hcc); // Queued data must also be discarded.
            write_reg(COMMAND,1);
            wait (serial_edges == target_edges);
            apb(1, COMMAND,4,0,collision,ignored);
            check(spi_cs_n === 1 && spi_sclk === 0, "Final ABORT did not idle pins");
            expect_reg(IRQ_STATUS,16);
            expect_reg(FIFO_LEVEL,0);
            repeat (24) @(negedge pclk);
            expect_reg(IRQ_STATUS,16);
            expect_reg(FIFO_LEVEL,0);
            $display("PASS corner: final ABORT collision phase %0d",collision);
        end
    endtask

    task automatic test_full_write_pop;
        reg [31:0] ignored;
        begin
            prepare(2);
            write_reg(TXDATA,8'h11);
            write_reg(TXDATA,8'h22);
            write_reg(COMMAND,1);
            write_reg(TXDATA,8'h33); // Refill the slot consumed by byte one.
            wait (serial_edges == 16);
            @(posedge pclk); // Align the access with the next-byte launch.
            apb(1, TXDATA,8'hff,1,5,ignored);
            wait (spi_cs_n[0] == 1);
            expect_reg(IRQ_STATUS,3); // DONE plus TX_OVERFLOW.
            expect_reg(FIFO_LEVEL,32'h00020001);
            expect_reg(RXDATA,8'h11);
            expect_reg(RXDATA,8'h22);
            write_reg(LENGTH,1);
            write_reg(COMMAND,1);
            wait (spi_cs_n[0] == 1);
            expect_reg(RXDATA,8'h33); // Failed 0xff write never entered FIFO.
            expect_reg(FIFO_LEVEL,0);
            $display("PASS corner: full TX write rejected despite simultaneous hardware pop");
        end
    endtask

    task automatic test_empty_read_push;
        reg [31:0] actual;
        begin
            prepare(1);
            write_reg(TXDATA,8'ha5);
            write_reg(COMMAND,1);
            wait (serial_edges == 16);
            apb(0, RXDATA,0,1,6,actual);
            check(actual === 0, "Empty read returned incoming byte prematurely");
            expect_reg(IRQ_STATUS,5); // DONE plus RX_UNDERFLOW.
            expect_reg(FIFO_LEVEL,32'h00010000);
            expect_reg(RXDATA,8'ha5);
            expect_reg(FIFO_LEVEL,0);
            $display("PASS corner: empty RX read rejected despite simultaneous hardware push");
        end
    endtask

    initial begin
        test_done_clear();
        test_final_abort(14,2);
        test_final_abort(15,3);
        test_final_abort(16,4);
        test_full_write_pop();
        test_empty_read_push();
        $display("PASS tb_apb_spi_corner: %0d verified collisions, %0d checks",races,checks);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1,"APB corner test timeout");
    end
endmodule

`default_nettype wire
