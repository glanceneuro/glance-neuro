// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Stimulus frame RAM: 16384 x 32-bit words, one 24-bit DAC SPI frame per word.
//
// True dual port across two clock domains: port A is the AXI side (host
// upload and CRC readback), port B is the 84 MHz engine's read port. Distinct
// addresses by construction during playback -- the AXI side blocks writes
// while the engine runs (enforced in stim_axi_regs), so the classic
// same-address collision cannot happen in normal operation, and a corrupted
// word during a mis-sequenced upload is caught by the CRC verify.
`timescale 1ns/1ps

module stim_frame_ram #(
    parameter integer DEPTH  = 16384,
    parameter integer ADDR_W = $clog2(DEPTH)
)(
    // Port A: AXI domain (write + readback)
    input  wire              clka,
    input  wire              ena,
    input  wire              wea,
    input  wire [ADDR_W-1:0] addra,
    input  wire [31:0]       dina,
    output reg  [31:0]       douta,

    // Port B: engine domain (read only)
    input  wire              clkb,
    input  wire              enb,
    input  wire [ADDR_W-1:0] addrb,
    output reg  [31:0]       doutb
);

// Not reset: entries are only played after being written (same reasoning as
// write_fifo in fifo_bram_interface.sv), and this must infer block RAM.
reg [31:0] mem [0:DEPTH-1];

always @(posedge clka) begin
    if (ena) begin
        if (wea)
            mem[addra] <= dina;
        douta <= mem[addra];
    end
end

always @(posedge clkb) begin
    if (enb)
        doutb <= mem[addrb];
end

endmodule
