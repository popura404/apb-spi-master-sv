`timescale 1ns/1ps

// Black-box regression: APB master and an independent, edge-driven SPI slave.
module tb_apb_spi_master;
    parameter integer FIFO_DEPTH = 16;
    parameter integer NUM_CS = 4;
    localparam [7:0] CTRL=8'h00, DIVIDER=8'h04, CS_SELECT=8'h08,
        LENGTH=8'h0c, COMMAND=8'h10, STATUS=8'h14, TXDATA=8'h18,
        RXDATA=8'h1c, FIFO_LEVEL=8'h20, IRQ_STATUS=8'h24, IRQ_ENABLE=8'h28;
    reg pclk = 0;
    always #5 pclk = ~pclk;
    reg presetn=0, psel=0, penable=0, pwrite=0;
    reg [7:0] paddr=0;
    reg [31:0] pwdata=0;
    wire [31:0] prdata;
    wire pready, pslverr, irq, spi_sclk, spi_mosi;
    reg spi_miso=0;
    wire [NUM_CS-1:0] spi_cs_n;
    apb_spi_master #(.FIFO_DEPTH(FIFO_DEPTH), .NUM_CS(NUM_CS)) dut (
        .pclk(pclk), .presetn(presetn), .paddr(paddr), .psel(psel),
        .penable(penable), .pwrite(pwrite), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr), .irq(irq),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n)
    );

    integer checks=0, apb_count=0, completed_transfers=0, verified_bytes=0;
    integer seed=1, unused;
    reg [31:0] random_state;
    reg [7:0] expected_tx [0:1023];
    reg [7:0] expected_rx [0:1023];
    reg slave_enabled=0, slave_cpol=0, slave_cpha=0, slave_lsb=0;
    reg slave_loopback=0;
    integer slave_divider=2, slave_select=0, slave_length=0;
    integer slave_samples=0, slave_edges=0, slave_asserts=0, slave_deasserts=0;
    integer completion_hold_cycles=0;
    time previous_edge_time=0, last_trailing_time=0;
    reg [NUM_CS-1:0] previous_cs={NUM_CS{1'b1}};
    reg [NUM_CS-1:0] selected_cs;
    integer bit_index, byte_index, edge_index;
    reg expected_bit;
    string vcd_path;

    task automatic check(input reg condition, input string message);
        begin
            checks=checks+1;
            if (condition !== 1'b1) begin
                $display("FAIL time=%0t seed=%0d: %s", $time, seed, message);
                $fatal(1);
            end
        end
    endtask

    function automatic [31:0] next_random;
        begin
            random_state = (random_state * 32'd1664525) + 32'd1013904223;
            next_random = random_state;
        end
    endfunction

    task automatic idle_cycles(input integer count);
        repeat(count) @(negedge pclk);
    endtask

    task automatic apb(input reg wr, input [7:0] addr, input [31:0] data,
                       input reg expect_error, output reg [31:0] result);
        begin
            @(negedge pclk);
            psel=1; penable=0; pwrite=wr; paddr=addr; pwdata=data;
            #1;
            check(pslverr === 1'b0, "PSLVERR asserted in APB setup");
            @(negedge pclk);
            penable=1;
            #1;
            check(pready === 1'b1, "zero-wait-state APB access stalled");
            check(pslverr === expect_error,
                  $sformatf("APB %s address=%02x data=%08x expected_error=%0b actual=%0b",
                            wr ? "write" : "read", addr, data, expect_error, pslverr));
            result=prdata;
            @(negedge pclk);
            psel=0; penable=0; pwrite=0; paddr=0; pwdata=0;
            apb_count=apb_count+1;
        end
    endtask

    task automatic write_reg(input [7:0] addr, input [31:0] data);
        reg [31:0] ignored;
        apb(1, addr, data, 0, ignored);
    endtask

    task automatic bad_write(input [7:0] addr, input [31:0] data);
        reg [31:0] ignored;
        apb(1, addr, data, 1, ignored);
    endtask

    task automatic read_reg(input [7:0] addr, output reg [31:0] data);
        apb(0, addr, 0, 0, data);
    endtask

    task automatic expect_reg(input [7:0] addr, input [31:0] expected,
                              input [31:0] mask);
        reg [31:0] actual;
        begin
            read_reg(addr, actual);
            check((actual & mask) === (expected & mask),
                  $sformatf("register %02x expected=%08x actual=%08x mask=%08x",
                            addr, expected, actual, mask));
        end
    endtask

    task automatic bad_read(input [7:0] addr);
        reg [31:0] actual;
        begin
            apb(0, addr, 0, 1, actual);
            check(actual === 0, "failed read must return zero");
        end
    endtask

    task automatic reset_dut;
        begin
            slave_enabled=0;
            @(negedge pclk);
            presetn=0; psel=0; penable=0; pwrite=0; paddr=0; pwdata=0;
            spi_miso=0;
            idle_cycles(3);
            presetn=1;
            idle_cycles(2);
            check(spi_cs_n === {NUM_CS{1'b1}}, "reset CS idle");
            check(spi_sclk === 0, "reset SCLK idle");
            check(irq === 0, "reset IRQ clear");
            expect_reg(CTRL,0,32'hffffffff);
            expect_reg(DIVIDER,2,32'hffffffff);
            expect_reg(CS_SELECT,0,32'hffffffff);
            expect_reg(LENGTH,1,32'hffffffff);
            expect_reg(STATUS,10,32'hffffffff);
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            expect_reg(IRQ_STATUS,0,32'hffffffff);
            expect_reg(IRQ_ENABLE,0,32'hffffffff);
        end
    endtask

    task automatic prepare(input integer mode, input integer lsb,
                           input integer divider_value, input integer cs_index,
                           input integer length_value, input integer loopback_value);
        begin
            slave_enabled=0;
            write_reg(COMMAND,2);
            write_reg(IRQ_STATUS,31);
            write_reg(IRQ_ENABLE,0);
            write_reg(CTRL,1 | ((mode >> 1) << 1) | ((mode & 1) << 2)
                              | (lsb << 3) | (loopback_value << 4));
            write_reg(DIVIDER,divider_value);
            write_reg(CS_SELECT,cs_index);
            write_reg(LENGTH,length_value);
            slave_cpol=(mode >> 1) & 1;
            slave_cpha=mode & 1;
            slave_lsb=lsb;
            slave_loopback=loopback_value;
            slave_divider=divider_value;
            slave_select=cs_index;
            slave_length=length_value;
        end
    endtask

    task automatic patterns(input integer count);
        integer k;
        reg [31:0] value;
        begin
            for (k=0;k<count;k=k+1) begin
                value=next_random(); expected_tx[k]=value[23:16] ^ k;
                value=next_random(); expected_rx[k]=value[15:8] ^ (8'ha7+k);
            end
        end
    endtask

    task automatic arm_slave;
        begin
            slave_samples=0; slave_edges=0; slave_asserts=0; slave_deasserts=0;
            previous_edge_time=0; last_trailing_time=0;
            selected_cs={NUM_CS{1'b1}};
            selected_cs[slave_select]=0;
            slave_enabled=1;
        end
    endtask

    // Only external SPI pins are observed. Change MISO on the non-sampling edge.
    always @(spi_cs_n) begin
        if (slave_enabled && presetn) begin
            if (previous_cs === {NUM_CS{1'b1}} && spi_cs_n !== {NUM_CS{1'b1}}) begin
                slave_asserts=slave_asserts+1;
                check(spi_cs_n === selected_cs, "wrong CS selection or multiple slaves selected");
                check(spi_sclk === slave_cpol, "SCLK not at CPOL when CS asserts");
                if (!slave_cpha)
                    spi_miso=expected_rx[0][slave_lsb ? 0 : 7];
            end else if (spi_cs_n === {NUM_CS{1'b1}} && previous_cs !== {NUM_CS{1'b1}}) begin
                slave_deasserts=slave_deasserts+1;
                check(slave_edges == 16*slave_length, "CS deasserted before/after expected edge count");
                check(slave_samples == 8*slave_length, "CS deasserted before expected sample count");
                check($time-last_trailing_time >= 10, "CS hold shorter than one PCLK after final edge");
                completion_hold_cycles=($time-last_trailing_time)/10;
                check(spi_sclk === slave_cpol, "CS deasserted away from idle clock polarity");
            end else if (spi_cs_n !== {NUM_CS{1'b1}}) begin
                check(spi_cs_n === selected_cs, "CS changed during transaction");
            end
        end
        previous_cs=spi_cs_n;
    end

    always @(spi_sclk) begin
        if (slave_enabled && presetn && spi_cs_n === selected_cs) begin
            edge_index=slave_edges % 16;
            check(spi_sclk === (slave_cpol ^ ((edge_index % 2) == 0)),
                  "SPI edges do not alternate from leading edge");
            if (edge_index != 0)
                check($time-previous_edge_time == slave_divider*10,
                      $sformatf("SCLK half-period expected=%0d ns actual=%0t", slave_divider*10,
                                $time-previous_edge_time));
            previous_edge_time=$time;
            if (edge_index == 15) last_trailing_time=$time;
            slave_edges=slave_edges+1;
            if (((spi_sclk != slave_cpol) && !slave_cpha) ||
                ((spi_sclk == slave_cpol) && slave_cpha)) begin
                byte_index=slave_samples/8;
                bit_index=slave_lsb ? slave_samples%8 : 7-(slave_samples%8);
                check(byte_index < slave_length, "unexpected extra SPI byte");
                expected_bit=expected_tx[byte_index][bit_index];
                check(spi_mosi === expected_bit,
                      $sformatf("MOSI byte=%0d bit=%0d expected=%0b actual=%0b mode=%0b%0b lsb=%0b",
                                byte_index, bit_index, expected_bit, spi_mosi,
                                slave_cpol, slave_cpha, slave_lsb));
                slave_samples=slave_samples+1;
            end else begin
                byte_index=slave_samples/8;
                bit_index=slave_lsb ? slave_samples%8 : 7-(slave_samples%8);
                if (byte_index < slave_length) spi_miso=expected_rx[byte_index][bit_index];
            end
        end
    end

    task automatic wait_idle;
        integer watchdog;
        reg [31:0] state_value;
        begin : waiting
            for (watchdog=0;watchdog<20000;watchdog=watchdog+1) begin
                read_reg(STATUS,state_value);
                if (!state_value[0]) disable waiting;
            end
            check(0,"transaction completion watchdog");
        end
    endtask

    task automatic finish_slave;
        begin
            check(slave_samples == slave_length*8, "incorrect serial sample count");
            check(slave_edges == slave_length*16, "incorrect serial edge count");
            check(slave_asserts == 1 && slave_deasserts == 1, "CS was not held for complete transaction");
            check(spi_cs_n === {NUM_CS{1'b1}}, "CS not idle after transaction");
            slave_enabled=0;
            completed_transfers=completed_transfers+1;
            verified_bytes=verified_bytes+slave_length;
        end
    endtask

    task automatic pop_expected(input integer index_value);
        reg [31:0] received;
        reg [7:0] expected_value;
        begin
            expected_value=slave_loopback ? expected_tx[index_value] : expected_rx[index_value];
            read_reg(RXDATA,received);
            check(received === {24'd0,expected_value},
                  $sformatf("RX byte=%0d expected=%02x actual=%08x", index_value, expected_value, received));
        end
    endtask

    task automatic test_access_rules;
        integer k;
        reg [31:0] read_value;
        begin
            $display("TEST reset, APB setup gating, continuous PSEL, access errors");
            reset_dut();
            // A long setup without an access must neither push TX nor start work.
            @(negedge pclk);
            psel=1; penable=0; pwrite=1; paddr=TXDATA; pwdata=8'hac;
            idle_cycles(4);
            paddr=COMMAND; pwdata=1;
            idle_cycles(4);
            pwrite=0; paddr=RXDATA;
            idle_cycles(4);
            psel=0;
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            expect_reg(IRQ_STATUS,0,31);
            expect_reg(STATUS,10,32'hffffffff);
            // Two transfers retain PSEL but insert the required setup phases.
            @(negedge pclk);
            psel=1; penable=0; pwrite=1; paddr=TXDATA; pwdata=8'h31;
            @(negedge pclk); penable=1;
            #1; check(pready && !pslverr,"first continuous-PSEL write");
            @(negedge pclk); penable=0; pwdata=8'h62;
            @(negedge pclk); penable=1;
            #1; check(pready && !pslverr,"second continuous-PSEL write");
            @(negedge pclk); penable=0; pwrite=0; paddr=FIFO_LEVEL;
            @(negedge pclk); penable=1;
            #1; check(pready && !pslverr && prdata === 2,"continuous-PSEL read and exact TX pushes");
            @(negedge pclk); psel=0; penable=0;
            apb_count=apb_count+3;
            expect_reg(FIFO_LEVEL,2,32'hffffffff);
            write_reg(COMMAND,2);
            bad_write(CTRL,32'h20);
            bad_write(DIVIDER,0);
            bad_write(DIVIDER,32'h10000);
            bad_write(LENGTH,0);
            bad_write(LENGTH,32'h10000);
            bad_write(CS_SELECT,NUM_CS);
            bad_write(CS_SELECT,32'h10000);
            bad_write(IRQ_ENABLE,32'h20);
            bad_write(IRQ_STATUS,32'h20);
            bad_write(COMMAND,0);
            bad_write(COMMAND,3);
            bad_write(COMMAND,8);
            bad_write(COMMAND,1); // disabled START
            bad_write(STATUS,0);
            bad_write(RXDATA,0);
            bad_write(FIFO_LEVEL,0);
            bad_write(8'h01,1);
            bad_write(8'h2c,1);
            bad_read(COMMAND);
            bad_read(TXDATA);
            bad_read(8'h02);
            bad_read(8'hfc);
            expect_reg(CTRL,0,32'hffffffff);
            expect_reg(DIVIDER,2,32'hffffffff);
            expect_reg(LENGTH,1,32'hffffffff);
            expect_reg(CS_SELECT,0,32'hffffffff);
            expect_reg(IRQ_ENABLE,0,32'hffffffff);
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            expect_reg(IRQ_STATUS,8,31);
            check(!irq,"IRQ raised with all enables clear");
            write_reg(IRQ_STATUS,8);
            expect_reg(IRQ_STATUS,0,31);
            $display("PASS access rules");
        end
    endtask

    task automatic test_fifo_irq;
        integer k;
        begin
            $display("TEST FIFO full/empty and sticky IRQ masking/W1C");
            write_reg(COMMAND,2);
            write_reg(IRQ_STATUS,31);
            for(k=0;k<FIFO_DEPTH;k=k+1) write_reg(TXDATA,32'hde000000|k);
            expect_reg(FIFO_LEVEL,FIFO_DEPTH,32'hffffffff);
            expect_reg(STATUS,12,31);
            bad_write(TXDATA,32'hff);
            expect_reg(FIFO_LEVEL,FIFO_DEPTH,32'hffffffff);
            bad_read(RXDATA);
            expect_reg(IRQ_STATUS,6,31);
            check(!irq,"masked error IRQ asserted");
            write_reg(IRQ_ENABLE,2);
            check(irq,"TX overflow IRQ mask did not assert");
            write_reg(IRQ_STATUS,2);
            check(!irq,"W1C did not clear selected pending IRQ");
            expect_reg(IRQ_STATUS,4,31);
            write_reg(IRQ_ENABLE,4);
            check(irq,"enabling pending RX underflow did not assert IRQ");
            write_reg(IRQ_STATUS,0);
            check(irq,"writing W1C zero cleared pending interrupt");
            write_reg(IRQ_STATUS,4);
            check(!irq,"RX underflow W1C did not clear IRQ");
            write_reg(IRQ_ENABLE,0);
            write_reg(COMMAND,2);
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            $display("PASS FIFO boundaries and IRQ");
        end
    endtask

    task automatic test_modes;
        integer mode_value, order_value, div_index, div_value, k, n;
        begin
            $display("TEST 4 modes x 2 bit orders x 3 clock dividers, external MISO");
            n=(FIFO_DEPTH < 3) ? FIFO_DEPTH : 3;
            for(mode_value=0;mode_value<4;mode_value=mode_value+1)
                for(order_value=0;order_value<2;order_value=order_value+1)
                    for(div_index=0;div_index<3;div_index=div_index+1) begin
                        div_value=(div_index == 0) ? 1 : ((div_index == 1) ? 2 : 5);
                        prepare(mode_value,order_value,div_value,
                                (mode_value+order_value+div_index)%NUM_CS,n,0);
                        patterns(n);
                        // Add deterministic all-zero/all-one and asymmetric data.
                        expected_tx[0]=8'h96;
                        if(n>1) expected_tx[1]=(order_value == 0) ? 8'h00 : 8'hff;
                        expected_rx[0]=8'h69;
                        for(k=0;k<n;k=k+1) write_reg(TXDATA,32'hface0000|expected_tx[k]);
                        write_reg(IRQ_ENABLE,1);
                        arm_slave();
                        write_reg(COMMAND,1);
                        wait_idle();
                        finish_slave();
                        check(irq,"DONE did not assert enabled IRQ");
                        expect_reg(IRQ_STATUS,1,31);
                        expect_reg(FIFO_LEVEL,n<<16,32'hffffffff);
                        for(k=0;k<n;k=k+1) pop_expected(k);
                        expect_reg(FIFO_LEVEL,0,32'hffffffff);
                        write_reg(IRQ_STATUS,1);
                        check(!irq,"DONE W1C did not clear IRQ");
                        $display("PASS mode=%0d lsb=%0d divider=%0d cs=%0d bytes=%0d",
                                 mode_value,order_value,div_value,slave_select,n);
                    end
            $display("TEST internal loopback, both phases and bit orders");
            for(mode_value=0;mode_value<4;mode_value=mode_value+1) begin
                prepare(mode_value,mode_value%2,2,0,1,1);
                patterns(1);
                write_reg(TXDATA,expected_tx[0]);
                arm_slave(); write_reg(COMMAND,1); wait_idle(); finish_slave();
                pop_expected(0);
            end
            $display("PASS loopback");
        end
    endtask

    task automatic test_streaming;
        integer n, queued, received, watchdog, stable_edges, k;
        reg [31:0] state_value, level_value, random_value;
        begin
            $display("TEST streaming beyond FIFO depth, TX starvation, RX backpressure, CS hold");
            n=FIFO_DEPTH*3+3;
            prepare(3,1,1,NUM_CS-1,n,0);
            patterns(n);
            arm_slave(); write_reg(COMMAND,1);
            idle_cycles(6);
            expect_reg(STATUS,35,7'h63); // busy + TX empty + waiting TX
            check(spi_cs_n === selected_cs && spi_sclk === 1,"TX starvation lost CS or CPOL");
            check(slave_edges == 0,"empty START generated serial edges");
            queued=0; received=0;
            for(k=0;k<FIFO_DEPTH;k=k+1) begin
                write_reg(TXDATA,expected_tx[queued]); queued=queued+1;
            end
            begin : await_rx_full
                for(watchdog=0;watchdog<2000;watchdog=watchdog+1) begin
                    read_reg(STATUS,state_value);
                    if(state_value[4]) disable await_rx_full;
                end
                check(0,"RX never became full");
            end
            for(k=0;k<FIFO_DEPTH;k=k+1) begin
                write_reg(TXDATA,expected_tx[queued]); queued=queued+1;
            end
            expect_reg(FIFO_LEVEL,(FIFO_DEPTH<<16)|FIFO_DEPTH,32'hffffffff);
            expect_reg(STATUS,81,7'h51); // busy + RX full + waiting RX
            stable_edges=slave_edges;
            idle_cycles(30);
            check(slave_edges == stable_edges,"SCLK advanced while RX full");
            check(spi_cs_n === selected_cs && spi_sclk === 1,"RX backpressure lost CS or CPOL");
            bad_write(TXDATA,8'h55);
            expect_reg(IRQ_STATUS,2,31);
            // Drain and refill independently using only published FIFO levels.
            begin : stream_loop
                for(watchdog=0;watchdog<20000;watchdog=watchdog+1) begin
                    read_reg(FIFO_LEVEL,level_value);
                    if(level_value[31:16] != 0) begin
                        pop_expected(received); received=received+1;
                    end
                    if(queued<n && level_value[15:0]<FIFO_DEPTH) begin
                        write_reg(TXDATA,expected_tx[queued]); queued=queued+1;
                    end
                    random_value=next_random();
                    idle_cycles(random_value[2:0]);
                    if(received==n) disable stream_loop;
                end
                check(0,"streaming watchdog");
            end
            wait_idle(); finish_slave();
            check(queued == n && received == n,"streaming count mismatch");
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            expect_reg(IRQ_STATUS,3,31); // DONE plus earlier overflow remains sticky
            $display("PASS streaming bytes=%0d depth=%0d",n,FIFO_DEPTH);
        end
    endtask

    task automatic test_start_preservation;
        reg [7:0] retained_rx;
        reg [31:0] received;
        begin
            $display("TEST START preserves queued TX, prior RX, and sticky DONE");
            prepare(0,0,2,0,1,0);
            patterns(2);
            retained_rx=expected_rx[0];
            write_reg(TXDATA,expected_tx[0]);
            write_reg(TXDATA,expected_tx[1]);
            write_reg(IRQ_ENABLE,1);
            arm_slave(); write_reg(COMMAND,1); wait_idle(); finish_slave();
            expect_reg(FIFO_LEVEL,32'h00010001,32'hffffffff);
            expect_reg(IRQ_STATUS,1,31);
            expected_tx[0]=expected_tx[1];
            expected_rx[0]=expected_rx[1];
            arm_slave(); write_reg(COMMAND,1);
            check(irq,"START implicitly cleared sticky DONE");
            wait_idle(); finish_slave();
            expect_reg(FIFO_LEVEL,32'h00020000,32'hffffffff);
            read_reg(RXDATA,received);
            check(received === {24'd0,retained_rx},"START lost previous transaction RX data");
            pop_expected(0);
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            write_reg(IRQ_STATUS,1);
            check(!irq,"DONE W1C after consecutive transactions");
            $display("PASS START preservation");
        end
    endtask

    task automatic test_busy_abort_reset;
        reg [31:0] state_value;
        integer k, watchdog;
        begin
            $display("TEST busy configuration rejection, ABORT, reset in flight, recovery");
            prepare(2,0,5,0,3,0);
            write_reg(COMMAND,1); // no TX: deterministic busy stall
            bad_write(CTRL,0);
            bad_write(DIVIDER,1);
            bad_write(CS_SELECT,0);
            bad_write(LENGTH,1);
            bad_write(COMMAND,1);
            bad_write(COMMAND,2);
            expect_reg(CTRL,3,31);
            expect_reg(DIVIDER,5,32'hffffffff);
            expect_reg(LENGTH,3,32'hffffffff);
            expect_reg(CS_SELECT,0,32'hffffffff);
            expect_reg(IRQ_STATUS,8,31);
            write_reg(IRQ_ENABLE,16);
            write_reg(COMMAND,4);
            expect_reg(IRQ_STATUS,24,31);
            check(irq,"ABORTED IRQ not asserted");
            check(spi_cs_n === {NUM_CS{1'b1}} && spi_sclk === 1,"ABORT from wait did not idle pins");
            expect_reg(STATUS,10,32'hffffffff);
            expect_reg(FIFO_LEVEL,0,32'hffffffff);
            write_reg(IRQ_STATUS,31);
            write_reg(COMMAND,4); // ABORT is also legal while idle
            expect_reg(IRQ_STATUS,16,31);
            for(k=0;k<2;k=k+1) begin
                prepare(k == 0 ? 0 : 3,0,5,0,2,0);
                patterns(2);
                write_reg(TXDATA,expected_tx[0]);
                write_reg(TXDATA,expected_tx[1]);
                arm_slave(); write_reg(COMMAND,1);
                begin : await_mid_byte
                    for(watchdog=0;watchdog<100;watchdog=watchdog+1) begin
                        @(negedge pclk);
                        if(slave_samples >= 3) disable await_mid_byte;
                    end
                    check(0,"mid-byte activity watchdog");
                end
                check(slave_samples<8,"abort/reset test missed in-flight byte");
                slave_enabled=0; // Recovery may intentionally truncate a clock pulse.
                if(k==0) begin
                    write_reg(COMMAND,4);
                    expect_reg(STATUS,10,32'hffffffff);
                    expect_reg(FIFO_LEVEL,0,32'hffffffff);
                    expect_reg(IRQ_STATUS,16,31);
                    check(spi_cs_n === {NUM_CS{1'b1}} && spi_sclk === 0,"mid-byte ABORT pins");
                    idle_cycles(200);
                    expect_reg(IRQ_STATUS,16,31);
                end else reset_dut();
                prepare(1,1,1,0,1,0);
                patterns(1); write_reg(TXDATA,expected_tx[0]);
                arm_slave(); write_reg(COMMAND,1); wait_idle(); finish_slave();
                pop_expected(0);
                expect_reg(IRQ_STATUS,1,31);
            end
            $display("PASS abort/reset recovery");
        end
    endtask

    task automatic test_event_clear_collision;
        integer hold_cycles;
        begin
            $display("TEST simultaneous DONE event and APB W1C: hardware event wins");
            // Calibrate completion latency from external pins, without internal signals.
            prepare(0,0,2,0,1,0);
            patterns(1); write_reg(TXDATA,expected_tx[0]);
            arm_slave(); write_reg(COMMAND,1); wait_idle(); finish_slave();
            pop_expected(0);
            hold_cycles=completion_hold_cycles;
            prepare(0,0,2,0,1,0);
            patterns(1); write_reg(TXDATA,expected_tx[0]);
            write_reg(IRQ_ENABLE,1);
            arm_slave(); write_reg(COMMAND,1);
            // An extended SETUP phase is legal. ACCESS is aligned with completion.
            @(negedge pclk);
            psel=1; penable=0; pwrite=1; paddr=IRQ_STATUS; pwdata=1;
            wait(slave_edges == 16);
            repeat(hold_cycles) @(negedge pclk);
            penable=1;
            #1;
            check(pready && !pslverr,"W1C collision APB access error");
            @(posedge pclk);
            #1;
            check(spi_cs_n === {NUM_CS{1'b1}},"W1C was not aligned with completion");
            check(irq,"simultaneous W1C incorrectly suppressed new DONE event");
            @(negedge pclk);
            psel=0; penable=0; pwrite=0; paddr=0; pwdata=0;
            apb_count=apb_count+1;
            finish_slave();
            expect_reg(IRQ_STATUS,1,31);
            pop_expected(0);
            write_reg(IRQ_STATUS,1);
            check(!irq,"DONE clear after collision failed");
            $display("PASS event/W1C collision");
        end
    endtask

    initial begin
        if($value$plusargs("SEED=%d",seed)) begin end
        random_state=seed;
        if($value$plusargs("VCD=%s",vcd_path)) begin
            $dumpfile(vcd_path); $dumpvars(0,tb_apb_spi_master);
        end else if($test$plusargs("WAVES")) begin
            $dumpfile("waves.vcd"); $dumpvars(0,tb_apb_spi_master);
        end
        $display("APB SPI regression FIFO_DEPTH=%0d NUM_CS=%0d SEED=%0d",FIFO_DEPTH,NUM_CS,seed);
        test_access_rules();
        test_fifo_irq();
        test_modes();
        test_streaming();
        test_start_preservation();
        test_event_clear_collision();
        test_busy_abort_reset();
        $display("PASS ALL checks=%0d APB_accesses=%0d transactions=%0d serial_bytes=%0d seed=%0d",
                 checks,apb_count,completed_transfers,verified_bytes,seed);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1,"global regression watchdog timeout");
    end
endmodule
