// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Testbench for i2c_probe: drives it against a behavioral open-drain I2C slave
// that models a BNO055 (ACK at 0x28, returns CHIP_ID on register reads), plus
// the not-both-high "no IMU" case and a clock-stretching case.
`timescale 1ns/1ps

module i2c_probe_tb;

localparam integer CLK_HZ = 100_000_000;
localparam integer I2C_HZ = 2_000_000;   // fast for sim; QDIV small

reg clk = 0; always #5 clk = ~clk;        // 100 MHz
reg rstn = 0;

reg  start = 0;
wire busy, done, present, ack_ok, timed_out;
wire [7:0] chip_id;
wire [1:0] idle_lvl;

// open-drain bus with pull-ups
tri1 sda, scl;
wire probe_sda_oe, probe_scl_oe;
wire sda_in = sda, scl_in = scl;
assign sda = probe_sda_oe ? 1'b0 : 1'bz;
assign scl = probe_scl_oe ? 1'b0 : 1'bz;

// Optional external "LVDS-ish" driver to force a not-both-high idle (no-IMU case)
reg force_scl_low = 0;
assign scl = force_scl_low ? 1'b0 : 1'bz;

i2c_probe #(
    .CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ),
    .DEV_ADDR(7'h28), .PROBE_REG(8'h00), .EXPECT_ID(8'hA0),
    .STRETCH_TICKS(2000)
) dut (
    .clk(clk), .rstn(rstn), .start(start),
    .busy(busy), .done(done), .present(present), .ack_ok(ack_ok),
    .chip_id(chip_id), .idle_lvl(idle_lvl), .timed_out(timed_out),
    .sda_oe(probe_sda_oe), .scl_oe(probe_scl_oe), .sda_in(sda_in), .scl_in(scl_in)
);

// ---------------- behavioral I2C slave (BNO055-like) ----------------
// Clean model: sample write bits on posedge SCL; make ACK / drive read bits on
// negedge SCL. `bn` counts SCL cycles in the current byte (data 0..7, ack at 8).
reg        slave_en   = 1;         // 0 => device absent (NAK)
reg [7:0]  slave_id   = 8'hA0;     // value returned for register reads
reg        slave_stretch = 0;      // hold SCL low briefly on one read bit
reg        s_sda_low = 0, s_scl_low = 0;
assign sda = s_sda_low ? 1'b0 : 1'bz;
assign scl = s_scl_low ? 1'b0 : 1'bz;

reg        act = 0, gotaddr = 0, rd = 0, did_stretch = 0;
reg [3:0]  bn = 0;
reg [7:0]  rx = 0, tx = 0;

task slave_reset;
begin
    act=0; gotaddr=0; rd=0; did_stretch=0; bn=0; rx=0; tx=0;
    s_sda_low=0; s_scl_low=0;
end
endtask

wire scl_h = (scl === 1'b1);
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
    if (bn == 8) begin                         // set up ACK for the 9th high
        if (!gotaddr) begin
            if (rx[7:1] == 7'h28 && slave_en) begin
                gotaddr <= 1; rd <= rx[0]; tx <= slave_id; s_sda_low <= 1;
            end else s_sda_low <= 0;            // NAK: wrong addr / absent
        end else if (!rd) begin
            s_sda_low <= slave_en;              // ACK register-pointer write
        end else begin
            s_sda_low <= 0;                     // read data byte done: master ACK/NAKs
        end
    end else if (bn == 9) begin                // after ACK bit -> next byte
        bn <= 0; rx <= 0; s_sda_low <= 0;
        if (rd && gotaddr) s_sda_low <= ~tx[7]; // begin driving read data (bit7)
    end else if (rd && gotaddr && bn >= 1 && bn <= 7) begin
        s_sda_low <= ~tx[7 - bn];               // drive read bits 6..0
        if (slave_stretch && bn == 3 && !did_stretch) begin
            did_stretch <= 1; s_scl_low <= 1; #300 s_scl_low <= 0;
        end
    end
end

// ---------------- test sequence ----------------
integer errors = 0;
task check(input c, input [255:0] m);
    if (!c) begin errors=errors+1; $display("FAIL: %0s", m); end
endtask

task run_probe;
begin
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    wait (done);
    repeat (5) @(posedge clk);
end
endtask

initial begin
    repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

    // --- Test 1: IMU present, CHIP_ID 0xA0 ---
    slave_reset; slave_en=1; slave_id=8'hA0; slave_stretch=0; force_scl_low=0;
    run_probe;
    $display("T1 present=%b ack=%b id=0x%02x idle=%b timeout=%b", present, ack_ok, chip_id, idle_lvl, timed_out);
    check(idle_lvl==2'b11, "T1 idle both-high");
    check(ack_ok==1'b1,   "T1 addr ACKed");
    check(chip_id==8'hA0, "T1 chip_id 0xA0");
    check(present==1'b1,  "T1 present");

    // --- Test 2: device present, wrong ID (0x00) -> not present ---
    slave_reset; slave_en=1; slave_id=8'h00; slave_stretch=0;
    run_probe;
    $display("T2 present=%b ack=%b id=0x%02x", present, ack_ok, chip_id);
    check(ack_ok==1'b1,  "T2 addr ACKed");
    check(present==1'b0, "T2 not present (wrong id)");

    // --- Test 3: no device (both high, but NAK) -> not present ---
    slave_reset; slave_en=0;
    run_probe;
    $display("T3 present=%b ack=%b idle=%b", present, ack_ok, idle_lvl);
    check(idle_lvl==2'b11, "T3 idle both-high");
    check(ack_ok==1'b0,   "T3 no ACK");
    check(present==1'b0,  "T3 not present");

    // --- Test 4: non-IMU headstage: idle not both-high, must NOT drive ---
    slave_reset; slave_en=0; force_scl_low=1;
    run_probe;
    $display("T4 present=%b idle=%b", present, idle_lvl);
    check(idle_lvl!=2'b11, "T4 idle not both-high");
    check(present==1'b0,  "T4 not present");
    force_scl_low=0;

    // --- Test 5: IMU present WITH clock stretching ---
    slave_reset; slave_en=1; slave_id=8'hA0; slave_stretch=1;
    run_probe;
    $display("T5 present=%b id=0x%02x timeout=%b", present, chip_id, timed_out);
    check(present==1'b1,  "T5 present through stretch");
    check(timed_out==1'b0,"T5 no timeout");

    if (errors==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #5_000_000;
    $display("FAIL: timeout"); $display("RESULT: FAIL"); $finish;
end

endmodule
