`timescale 1ns / 1ps
`default_nettype none

// APB3-controlled, byte-oriented SPI master. All state is clocked by pclk.
module apb_spi_master #(
    parameter int FIFO_DEPTH = 16,
    parameter int NUM_CS = 4
) (
    input  wire logic              pclk,
    input  wire logic              presetn,
    input  wire logic [7:0]        paddr,
    input  wire logic              psel,
    input  wire logic              penable,
    input  wire logic              pwrite,
    input  wire logic [31:0]       pwdata,
    output      logic [31:0]       prdata,
    output      logic              pready,
    output      logic              pslverr,
    output      logic              irq,
    output      logic              spi_sclk,
    output      logic              spi_mosi,
    input  wire logic              spi_miso,
    output      logic [NUM_CS-1:0] spi_cs_n
);
    localparam int COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1;
    localparam logic [7:0] A_CTRL       = 8'h00,
                           A_DIVIDER    = 8'h04,
                           A_CS_SELECT  = 8'h08,
                           A_LENGTH     = 8'h0c,
                           A_COMMAND    = 8'h10,
                           A_STATUS     = 8'h14,
                           A_TXDATA     = 8'h18,
                           A_RXDATA     = 8'h1c,
                           A_FIFO_LEVEL = 8'h20,
                           A_IRQ_STATUS = 8'h24,
                           A_IRQ_ENABLE = 8'h28;

    logic [4:0]  ctrl;
    logic [15:0] divider;
    logic [1:0]  cs_select;
    logic [15:0] length;
    logic [15:0] remaining;
    logic        transfer_busy;
    logic        byte_active;
    logic [4:0]  irq_status;
    logic [4:0]  irq_enable;

    logic [7:0] tx_head, rx_head;
    logic tx_empty, tx_full, rx_empty, rx_full;
    logic [COUNT_WIDTH-1:0] tx_level, rx_level;
    logic engine_busy, engine_done;
    logic [7:0] engine_rx;

    logic apb_access;
    logic access_error;
    logic [4:0] error_event;
    logic write_ok;
    logic read_ok;
    logic command_start;
    logic command_flush;
    logic command_abort;
    logic fifo_clear;
    logic can_launch;
    logic engine_start;
    logic rx_push;
    logic tx_push;
    logic rx_pop;
    logic [4:0] irq_clear;
    logic [4:0] irq_events;

    assign apb_access = psel && penable;
    assign pready = 1'b1;
    assign pslverr = apb_access && access_error;
    assign write_ok = apb_access && pwrite && !access_error;
    assign read_ok = apb_access && !pwrite && !access_error;
    assign command_start = write_ok && paddr == A_COMMAND && pwdata == 32'd1;
    assign command_flush = write_ok && paddr == A_COMMAND && pwdata == 32'd2;
    assign command_abort = write_ok && paddr == A_COMMAND && pwdata == 32'd4;
    assign fifo_clear = command_flush || command_abort;
    assign can_launch = transfer_busy && !byte_active && !engine_busy &&
                        !engine_done && remaining != 0;
    assign engine_start = can_launch && !tx_empty && !rx_full && !command_abort;
    assign rx_push = engine_done && transfer_busy && !command_abort;
    assign tx_push = write_ok && paddr == A_TXDATA;
    assign rx_pop = read_ok && paddr == A_RXDATA;
    assign irq_clear = (write_ok && paddr == A_IRQ_STATUS) ? pwdata[4:0] : 5'b0;
    assign irq = |(irq_status & irq_enable);

    // Side effects are gated by a completed APB access, never by SETUP alone.
    // Bad accesses return an error immediately rather than stalling the bus.
    always_comb begin
        prdata = 32'b0;
        access_error = 1'b0;
        error_event = 5'b01000;
        if (paddr[1:0] != 2'b00) begin
            access_error = 1'b1;
        end else if (pwrite) begin
            case (paddr)
                A_CTRL: access_error = transfer_busy || (pwdata[31:5] != 0);
                A_DIVIDER: access_error = transfer_busy || (pwdata[31:16] != 0) ||
                                          (pwdata[15:0] == 0);
                A_CS_SELECT: access_error = transfer_busy || (pwdata >= NUM_CS);
                A_LENGTH: access_error = transfer_busy || (pwdata[31:16] != 0) ||
                                         (pwdata[15:0] == 0);
                A_COMMAND: begin
                    case (pwdata)
                        32'd1: access_error = transfer_busy || !ctrl[0];
                        32'd2: access_error = transfer_busy;
                        32'd4: access_error = 1'b0;
                        default: access_error = 1'b1;
                    endcase
                end
                A_TXDATA: begin
                    access_error = tx_full;
                    error_event = 5'b00010;
                end
                A_IRQ_STATUS, A_IRQ_ENABLE: access_error = (pwdata[31:5] != 0);
                default: access_error = 1'b1;
            endcase
        end else begin
            case (paddr)
                A_CTRL: prdata = {27'b0, ctrl};
                A_DIVIDER: prdata = {16'b0, divider};
                A_CS_SELECT: prdata = {30'b0, cs_select};
                A_LENGTH: prdata = {16'b0, length};
                A_STATUS: begin
                    prdata[0] = transfer_busy;
                    prdata[1] = tx_empty;
                    prdata[2] = tx_full;
                    prdata[3] = rx_empty;
                    prdata[4] = rx_full;
                    prdata[5] = can_launch && tx_empty;
                    prdata[6] = can_launch && rx_full;
                end
                A_RXDATA: begin
                    prdata[7:0] = rx_head;
                    access_error = rx_empty;
                    error_event = 5'b00100;
                end
                A_FIFO_LEVEL: begin
                    prdata[15:0] = tx_level;
                    prdata[31:16] = rx_level;
                end
                A_IRQ_STATUS: prdata = {27'b0, irq_status};
                A_IRQ_ENABLE: prdata = {27'b0, irq_enable};
                default: access_error = 1'b1;
            endcase
        end
    end

    always_comb begin
        irq_events = 5'b0;
        if (apb_access && access_error)
            irq_events = error_event;
        if (engine_done && transfer_busy && remaining == 16'd1 && !command_abort)
            irq_events[0] = 1'b1;
        if (command_abort)
            irq_events[4] = 1'b1;
    end

    always_comb begin
        spi_cs_n = {NUM_CS{1'b1}};
        if (transfer_busy)
            spi_cs_n[cs_select] = 1'b0;
    end

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl          <= 5'b0;
            divider       <= 16'd2;
            cs_select     <= 2'b0;
            length        <= 16'd1;
            remaining     <= 16'b0;
            transfer_busy <= 1'b0;
            byte_active   <= 1'b0;
            irq_status    <= 5'b0;
            irq_enable    <= 5'b0;
        end else begin
            // Hardware events take priority over simultaneous software clear.
            irq_status <= (irq_status & ~irq_clear) | irq_events;
            if (write_ok) begin
                case (paddr)
                    A_CTRL: ctrl <= pwdata[4:0];
                    A_DIVIDER: divider <= pwdata[15:0];
                    A_CS_SELECT: cs_select <= pwdata[1:0];
                    A_LENGTH: length <= pwdata[15:0];
                    A_IRQ_ENABLE: irq_enable <= pwdata[4:0];
                    default: begin end
                endcase
            end

            if (command_abort) begin
                transfer_busy <= 1'b0;
                byte_active <= 1'b0;
                remaining <= 16'b0;
            end else if (command_start) begin
                transfer_busy <= 1'b1;
                remaining <= length;
                byte_active <= 1'b0;
            end else begin
                if (engine_start)
                    byte_active <= 1'b1;
                if (engine_done && transfer_busy) begin
                    byte_active <= 1'b0;
                    remaining <= remaining - 1'b1;
                    if (remaining == 16'd1)
                        transfer_busy <= 1'b0;
                end
            end
        end
    end

    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) tx_fifo (
        .clk(pclk), .rst_n(presetn), .clear(fifo_clear),
        .push(tx_push), .pop(engine_start), .din(pwdata[7:0]),
        .dout(tx_head), .empty(tx_empty), .full(tx_full), .level(tx_level)
    );
    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) rx_fifo (
        .clk(pclk), .rst_n(presetn), .clear(fifo_clear),
        .push(rx_push), .pop(rx_pop), .din(engine_rx),
        .dout(rx_head), .empty(rx_empty), .full(rx_full), .level(rx_level)
    );
    spi_shift engine (
        .clk(pclk), .rst_n(presetn), .abort(command_abort), .start(engine_start),
        .divider(divider), .cpol(ctrl[1]), .cpha(ctrl[2]),
        .lsb_first(ctrl[3]), .loopback(ctrl[4]), .tx_data(tx_head),
        .miso(spi_miso), .busy(engine_busy), .done(engine_done),
        .rx_data(engine_rx), .sclk(spi_sclk), .mosi(spi_mosi)
    );

    // synthesis translate_off
    initial begin
        if (FIFO_DEPTH < 2 || FIFO_DEPTH > 32768 ||
            (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
            $fatal(1, "FIFO_DEPTH must be a power of two in [2, 32768]");
        if (NUM_CS < 1 || NUM_CS > 4)
            $fatal(1, "NUM_CS must be in [1, 4]");
    end
    // synthesis translate_on
endmodule

`default_nettype wire
