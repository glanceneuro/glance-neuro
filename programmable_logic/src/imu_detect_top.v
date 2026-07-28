// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// IMU-detect peripheral: AXI-Lite control of two i2c_probe engines (one per
// headstage port), with the open-drain IOBUFs for the shared 2nd-CIPO lane
// pins. This is the whole PL of the minimal "detect" bitstream — the PS brings
// up the network, pokes CONTROL.start, polls STATUS.done, and reads the per-
// port RESULT registers.
//
// Register map (AXI-Lite, offset within the peripheral):
//   0x00 CONTROL  W1P : [0] start (probe both ports)
//   0x04 STATUS   RO  : [0] busy  [1] done (sticky until next start)
//   0x08 RESULT_A RO  : [0] present [1] ack_ok [2] timed_out
//                        [4:3] idle_lvl {scl,sda} [15:8] chip_id
//   0x0C RESULT_B RO  : same layout, port B
//   0x10 VERSION  RO  : 0x494D5531  ("IMU1")
//
// SDA/SCL are the same LVCMOS25 pins that carry LVDS 2nd-CIPO in the
// acquisition image; here they are single-ended open-drain (external 2 kOhm
// pull-ups on the headstage). The probe only drives after its high-Z idle
// sense passes, so this is safe against an LVDS-driving 128-ch headstage.
`timescale 1ns/1ps

module imu_detect_top #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // shared 2nd-CIPO lane pins, single-ended open-drain (LVCMOS25)
    inout  wire        sda_a,
    inout  wire        scl_a,
    inout  wire        sda_b,
    inout  wire        scl_b
);

localparam [31:0] VERSION = 32'h494D5531; // "IMU1"

// -------- probe A/B --------
wire        startp;
wire        busy_a, done_a, present_a, ack_a, to_a;
wire [7:0]  id_a;   wire [1:0] idle_a;
wire        sda_a_oe, scl_a_oe, sda_a_in, scl_a_in;
wire        busy_b, done_b, present_b, ack_b, to_b;
wire [7:0]  id_b;   wire [1:0] idle_b;
wire        sda_b_oe, scl_b_oe, sda_b_in, scl_b_in;

i2c_probe #(.CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ)) probe_a (
    .clk(s_axi_aclk), .rstn(s_axi_aresetn), .start(startp),
    .busy(busy_a), .done(done_a), .present(present_a), .ack_ok(ack_a),
    .chip_id(id_a), .idle_lvl(idle_a), .timed_out(to_a),
    .sda_oe(sda_a_oe), .scl_oe(scl_a_oe), .sda_in(sda_a_in), .scl_in(scl_a_in)
);
i2c_probe #(.CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ)) probe_b (
    .clk(s_axi_aclk), .rstn(s_axi_aresetn), .start(startp),
    .busy(busy_b), .done(done_b), .present(present_b), .ack_ok(ack_b),
    .chip_id(id_b), .idle_lvl(idle_b), .timed_out(to_b),
    .sda_oe(sda_b_oe), .scl_oe(scl_b_oe), .sda_in(sda_b_in), .scl_in(scl_b_in)
);

// open-drain IOBUFs: drive 0 when *_oe, else Hi-Z (pulled up externally)
IOBUF sda_a_buf (.IO(sda_a), .I(1'b0), .T(~sda_a_oe), .O(sda_a_in));
IOBUF scl_a_buf (.IO(scl_a), .I(1'b0), .T(~scl_a_oe), .O(scl_a_in));
IOBUF sda_b_buf (.IO(sda_b), .I(1'b0), .T(~sda_b_oe), .O(sda_b_in));
IOBUF scl_b_buf (.IO(scl_b), .I(1'b0), .T(~scl_b_oe), .O(scl_b_in));

wire [31:0] result_a = {16'd0, id_a, 3'd0, idle_a, to_a, ack_a, present_a};
wire [31:0] result_b = {16'd0, id_b, 3'd0, idle_b, to_b, ack_b, present_b};

// -------- start pulse + done latch --------
reg ctl_start;    // 1-cycle from a CONTROL.start write (driven by write channel)
reg start_flag;   // pulses probes for one cycle
reg done_latch;
always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        start_flag <= 1'b0; done_latch <= 1'b0;
    end else begin
        start_flag <= 1'b0;
        if (ctl_start) begin start_flag <= 1'b1; done_latch <= 1'b0; end
        else if (done_a && done_b) done_latch <= 1'b1;
    end
end
assign startp = start_flag;
wire busy = busy_a | busy_b;

// -------- AXI-Lite write (joint-accept; see axi_lite_registers.v) --------
wire wr_fire = s_axi_awready & s_axi_awvalid & s_axi_wready & s_axi_wvalid;
always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
        s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00; ctl_start <= 1'b0;
    end else begin
        ctl_start <= 1'b0;
        s_axi_awready <= ~s_axi_awready & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
        s_axi_wready  <= ~s_axi_wready  & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
        if (wr_fire) begin
            s_axi_bresp <= 2'b00;
            if (s_axi_awaddr[7:2] == 6'd0 && s_axi_wdata[0]) ctl_start <= 1'b1; // CONTROL.start
            s_axi_bvalid <= 1'b1;
        end else if (s_axi_bvalid & s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end
end

// -------- AXI-Lite read --------
always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0;
        s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00;
    end else begin
        s_axi_arready <= ~s_axi_arready & s_axi_arvalid & ~s_axi_rvalid;
        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
            case (s_axi_araddr[7:2])
                6'd0: s_axi_rdata <= 32'd0;                       // CONTROL reads 0
                6'd1: s_axi_rdata <= {30'd0, done_latch, busy};   // STATUS
                6'd2: s_axi_rdata <= result_a;
                6'd3: s_axi_rdata <= result_b;
                6'd4: s_axi_rdata <= VERSION;
                default: begin s_axi_rdata <= 32'hDEAD_1200; s_axi_rresp <= 2'b10; end
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

endmodule
