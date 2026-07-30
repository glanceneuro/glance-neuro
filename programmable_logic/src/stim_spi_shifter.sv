// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// 24-bit SPI mode-1 frame shifter for the DAC70502 (stimulus output).
//
// One start pulse shifts one 24-bit frame, MSB first, at 2 engine clocks per
// bit (42 MHz SCLK from the 84 MHz clock). Mode 1 (CPOL=0, CPHA=1): SDIN
// changes on the SCLK rising edge and the DAC captures it on the falling
// edge; internal DAC registers latch on the SYNC_N rising edge. CS_SETUP=2
// and CS_HOLD=1 clocks match the timing bench-verified on this carrier by the
// spi_dac_70502 reference project. Inter-frame pacing (SYNC_N high time,
// t_DACWAIT) is the caller's job -- the engine only starts a frame when the
// frame tick says so, and the slowest legal tick spacing is enforced there.
`timescale 1ns/1ps

module stim_spi_shifter (
    input  wire        clk,          // 84 MHz engine clock
    input  wire        rstn,

    input  wire        start,        // 1-cycle pulse; frame must be valid with it
    input  wire [23:0] frame,
    output reg         busy,
    output reg         done,         // 1-cycle pulse when SYNC_N has risen

    output reg         dac_sclk,
    output reg         dac_sync_n,
    output reg         dac_sdin
);

localparam integer CS_SETUP = 2;  // SYNC_N low to first SCLK rising edge
localparam integer CS_HOLD  = 1;  // last SCLK falling edge to SYNC_N rising

localparam [1:0] S_IDLE  = 2'd0,
                 S_SETUP = 2'd1,
                 S_SHIFT = 2'd2,
                 S_HOLD  = 2'd3;

reg [1:0]  state;
reg [23:0] shreg;
reg [4:0]  bit_cnt;    // 23..0
reg [1:0]  phase_cnt;  // counts the 2 clocks of one bit cell / setup / hold

always @(posedge clk) begin
    if (!rstn) begin
        state      <= S_IDLE;
        busy       <= 1'b0;
        done       <= 1'b0;
        dac_sclk   <= 1'b0;
        dac_sync_n <= 1'b1;
        dac_sdin   <= 1'b0;
        shreg      <= 24'd0;
        bit_cnt    <= 5'd0;
        phase_cnt  <= 2'd0;
    end else begin
        done <= 1'b0;
        case (state)
            S_IDLE: begin
                dac_sclk   <= 1'b0;
                dac_sync_n <= 1'b1;
                if (start) begin
                    shreg      <= frame;
                    bit_cnt    <= 5'd23;
                    phase_cnt  <= CS_SETUP[1:0];
                    dac_sync_n <= 1'b0;
                    busy       <= 1'b1;
                    state      <= S_SETUP;
                end
            end
            S_SETUP: begin
                phase_cnt <= phase_cnt - 2'd1;
                if (phase_cnt == 2'd1) begin
                    // First bit cell: rising edge + MSB together (mode 1).
                    dac_sclk  <= 1'b1;
                    dac_sdin  <= shreg[23];
                    phase_cnt <= 2'd1;
                    state     <= S_SHIFT;
                end
            end
            S_SHIFT: begin
                if (phase_cnt == 2'd1) begin
                    // Second half of the bit cell: falling edge, DAC samples.
                    dac_sclk  <= 1'b0;
                    phase_cnt <= 2'd0;
                end else begin
                    if (bit_cnt == 5'd0) begin
                        phase_cnt <= CS_HOLD[1:0];
                        state     <= S_HOLD;
                    end else begin
                        bit_cnt   <= bit_cnt - 5'd1;
                        shreg     <= {shreg[22:0], 1'b0};
                        dac_sclk  <= 1'b1;
                        dac_sdin  <= shreg[22];
                        phase_cnt <= 2'd1;
                    end
                end
            end
            S_HOLD: begin
                phase_cnt <= phase_cnt - 2'd1;
                if (phase_cnt == 2'd1) begin
                    dac_sync_n <= 1'b1;   // DAC latches the frame here
                    dac_sdin   <= 1'b0;
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    state      <= S_IDLE;
                end
            end
        endcase
    end
end

endmodule
