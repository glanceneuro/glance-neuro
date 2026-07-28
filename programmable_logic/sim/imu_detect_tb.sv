// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// AXI-Lite integration test for imu_detect_top: port A has an IMU (0xA0),
// port B has none. Drive CONTROL.start over AXI, poll STATUS.done, read the
// per-port RESULT registers. Uses the Xilinx IOBUF (compile with unisims).
`timescale 1ns/1ps

module imu_detect_tb;

reg aclk = 0; always #5 aclk = ~aclk;     // 100 MHz
reg arstn = 0;

reg  [7:0]  awaddr=0;  reg awvalid=0;  wire awready;
reg  [31:0] wdata=0;   reg wvalid=0;   wire wready;
wire [1:0]  bresp;     wire bvalid;    reg bready=1;
reg  [7:0]  araddr=0;  reg arvalid=0;  wire arready;
wire [31:0] rdata;     wire [1:0] rresp; wire rvalid; reg rready=1;

tri1 sda_a, scl_a, sda_b, scl_b;   // pull-ups

imu_detect_top #(.CLK_HZ(100_000_000), .I2C_HZ(5_000_000)) dut (
    .s_axi_aclk(aclk), .s_axi_aresetn(arstn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .sda_a(sda_a), .scl_a(scl_a), .sda_b(sda_b), .scl_b(scl_b)
);

// Port A = IMU present; Port B = absent
i2c_slave_model #(.ADDR(7'h28), .ID_VALUE(8'hA0)) slaveA (.enabled(1'b1), .stretch(1'b0), .sda(sda_a), .scl(scl_a));
i2c_slave_model #(.ADDR(7'h28), .ID_VALUE(8'hA0)) slaveB (.enabled(1'b0), .stretch(1'b0), .sda(sda_b), .scl(scl_b));

integer errors = 0;
task check(input c, input [255:0] m); if (!c) begin errors=errors+1; $display("FAIL: %0s", m); end endtask

task axi_write(input [7:0] a, input [31:0] d);
begin
    @(negedge aclk); awaddr=a; wdata=d; awvalid=1; wvalid=1;
    do @(posedge aclk); while(!(awready&&wready));
    @(negedge aclk); awvalid=0; wvalid=0;
    while(!bvalid) @(posedge aclk); @(negedge aclk);
end
endtask
reg [31:0] rd;
task axi_read(input [7:0] a);
begin
    @(negedge aclk); araddr=a; arvalid=1;
    do @(posedge aclk); while(!arready);
    @(negedge aclk); arvalid=0;
    while(!rvalid) @(posedge aclk); rd=rdata; @(negedge aclk);
end
endtask

integer i;
initial begin
    repeat(10) @(posedge aclk); arstn=1; repeat(10) @(posedge aclk);

    axi_read(8'h10); check(rd==32'h494D5531, "VERSION IMU1");

    axi_write(8'h00, 32'h1);              // CONTROL.start
    rd=0;
    for (i=0;i<200000 && !(rd[1]);i=i+1) axi_read(8'h04);  // poll STATUS.done
    check(rd[1]==1'b1, "detection completed");

    axi_read(8'h08);                      // RESULT_A
    $display("A: present=%b ack=%b to=%b idle=%b id=0x%02x", rd[0],rd[1],rd[2],rd[4:3],rd[15:8]);
    check(rd[0]==1'b1,       "port A present");
    check(rd[15:8]==8'hA0,   "port A chip_id 0xA0");

    axi_read(8'h0C);                      // RESULT_B
    $display("B: present=%b ack=%b idle=%b id=0x%02x", rd[0],rd[1],rd[4:3],rd[15:8]);
    check(rd[0]==1'b0,       "port B not present");

    if (errors==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
end

initial begin #10_000_000; $display("FAIL: timeout"); $display("RESULT: FAIL"); $finish; end

endmodule
