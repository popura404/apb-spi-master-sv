`timescale 1ns / 1ps
`default_nettype none

// Eight-bit SPI engine. All state changes use clk; SCLK is only an output.
module spi_shift (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        abort,
    input  wire logic        start,
    input  wire logic [15:0] divider,
    input  wire logic        cpol,
    input  wire logic        cpha,
    input  wire logic        lsb_first,
    input  wire logic        loopback,
    input  wire logic [7:0]  tx_data,
    input  wire logic        miso,
    output      logic        busy,
    output      logic        done,
    output      logic [7:0]  rx_data,
    output      logic        sclk,
    output      logic        mosi
);

    logic [15:0] half_count;
    logic [3:0]  edge_index;
    logic [7:0]  tx_shift;
    logic [7:0]  rx_shift;
    logic        finish_pending;

    logic sample_bit;
    logic first_bit;
    logic [7:0] shifted_tx;
    logic [7:0] shifted_rx;

    assign sample_bit = loopback ? mosi : miso;
    assign first_bit = lsb_first ? tx_shift[0] : tx_shift[7];
    assign shifted_tx = lsb_first ? {1'b0, tx_shift[7:1]}
                                  : {tx_shift[6:0], 1'b0};
    assign shifted_rx = lsb_first ? {sample_bit, rx_shift[7:1]}
                                  : {rx_shift[6:0], sample_bit};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            rx_data        <= 8'h00;
            sclk           <= 1'b0;
            mosi           <= 1'b0;
            half_count     <= 16'h0000;
            edge_index     <= 4'h0;
            tx_shift       <= 8'h00;
            rx_shift       <= 8'h00;
            finish_pending <= 1'b0;
        end else begin
            done <= 1'b0;

            if (abort) begin
                busy           <= 1'b0;
                rx_data        <= 8'h00;
                sclk           <= cpol;
                mosi           <= 1'b0;
                half_count     <= 16'h0000;
                edge_index     <= 4'h0;
                tx_shift       <= 8'h00;
                rx_shift       <= 8'h00;
                finish_pending <= 1'b0;
            end else if (!busy) begin
                sclk <= cpol;
                if (start) begin
                    busy           <= 1'b1;
                    half_count     <= divider - 16'd1;
                    edge_index     <= 4'h0;
                    tx_shift       <= tx_data;
                    rx_shift       <= 8'h00;
                    finish_pending <= 1'b0;
                    // CPHA=0 requires the first bit before the leading edge.
                    mosi <= lsb_first ? tx_data[0] : tx_data[7];
                end
            end else if (finish_pending) begin
                // Leave a full clk interval after the final trailing edge.
                busy           <= 1'b0;
                done           <= 1'b1;
                rx_data        <= rx_shift;
                finish_pending <= 1'b0;
            end else if (half_count != 16'h0000) begin
                half_count <= half_count - 16'd1;
            end else begin
                half_count <= divider - 16'd1;
                edge_index <= edge_index + 4'd1;
                sclk       <= edge_index[0] ? cpol : !cpol;

                // Even edge indices are leading edges; odd ones are trailing.
                if (edge_index[0] == cpha)
                    rx_shift <= shifted_rx;

                if (cpha && !edge_index[0]) begin
                    mosi     <= first_bit;
                    tx_shift <= shifted_tx;
                end else if (!cpha && edge_index[0] && edge_index != 4'd15) begin
                    tx_shift <= shifted_tx;
                    mosi     <= lsb_first ? tx_shift[1] : tx_shift[6];
                end

                if (edge_index == 4'd15)
                    finish_pending <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
