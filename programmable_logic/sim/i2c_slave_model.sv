// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Sim-only behavioral open-drain I2C slave modelling a BNO055-ish device:
// ACKs its 7-bit address, returns ID_VALUE on register reads. `enabled=0`
// models an absent device (NAKs). Validated against i2c_probe in
// i2c_probe_tb.sv.
`timescale 1ns/1ps

module i2c_slave_model #(
    parameter [6:0] ADDR     = 7'h28,
    parameter [7:0] ID_VALUE = 8'hA0
)(
    input  wire enabled,
    input  wire stretch,     // hold SCL low briefly on one read bit
    inout  wire sda,
    inout  wire scl
);

reg s_sda_low = 0, s_scl_low = 0;
assign sda = s_sda_low ? 1'b0 : 1'bz;
assign scl = s_scl_low ? 1'b0 : 1'bz;

reg        act = 0, gotaddr = 0, rd = 0, did_stretch = 0;
reg [3:0]  bn = 0;
reg [7:0]  rx = 0, tx = 0;
wire       scl_h = (scl === 1'b1);

always @(negedge sda) if (scl_h) begin      // START / repeated START
    act=1; bn=0; gotaddr=0; s_sda_low=0; rx=0;
end
always @(posedge sda) if (scl_h && act) begin // STOP
    act=0; rd=0; gotaddr=0; s_sda_low=0;
end
always @(posedge scl) if (act) begin
    if (bn < 8 && !(rd && gotaddr)) rx <= {rx[6:0], (sda===1'b1)};
    bn <= bn + 4'd1;
end
always @(negedge scl) if (act) begin
    if (bn == 8) begin
        if (!gotaddr) begin
            if (rx[7:1] == ADDR && enabled) begin
                gotaddr <= 1; rd <= rx[0]; tx <= ID_VALUE; s_sda_low <= 1;
            end else s_sda_low <= 0;
        end else if (!rd) begin
            s_sda_low <= enabled;
        end else begin
            s_sda_low <= 0;
        end
    end else if (bn == 9) begin
        bn <= 0; rx <= 0; s_sda_low <= 0;
        if (rd && gotaddr) s_sda_low <= ~tx[7];
    end else if (rd && gotaddr && bn >= 1 && bn <= 7) begin
        s_sda_low <= ~tx[7 - bn];
        if (stretch && bn == 3 && !did_stretch) begin
            did_stretch <= 1; s_scl_low <= 1; #300 s_scl_low <= 0;
        end
    end
end

endmodule
