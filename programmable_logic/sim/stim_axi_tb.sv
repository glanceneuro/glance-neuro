// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// stim_top integration testbench: AXI-Lite register access, frame-RAM upload
// and readback, a full playback run driven purely through the bus, and the
// write-while-running interlock -- across the real 131.25 MHz AXI / 84 MHz
// engine clock pair.
`timescale 1ns/1ps

module stim_axi_tb;

reg aclk = 0;
always #3.810 aclk = ~aclk;    // 131.25 MHz
reg pclk = 0;
always #5.952 pclk = ~pclk;    // 84 MHz
reg aresetn = 0, prstn = 0;

reg  [31:0] awaddr = 0;  reg awvalid = 0;  wire awready;
reg  [31:0] wdata = 0;   reg wvalid = 0;   wire wready;
wire [1:0]  bresp;       wire bvalid;      reg bready = 1;
reg  [31:0] araddr = 0;  reg arvalid = 0;  wire arready;
wire [31:0] rdata;       wire [1:0] rresp; wire rvalid; reg rready = 1;

reg  [7:0]  digital_in = 0;
reg  [63:0] master_timestamp = 0;
always @(posedge pclk) master_timestamp <= master_timestamp + 1;

wire dac_sclk, dac_sync_n, dac_sdin, dac_running;

stim_top dut (
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
    .pl_clk(pclk), .pl_rstn(prstn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid),
    .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
    .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .digital_in(digital_in), .master_timestamp(master_timestamp),
    .dac_sclk(dac_sclk), .dac_sync_n(dac_sync_n), .dac_sdin(dac_sdin),
    .dac_running(dac_running)
);

integer errors = 0;
task check(input cond, input [511:0] msg);
    if (!cond) begin
        errors = errors + 1;
        $display("FAIL: %0s (t=%0t)", msg, $time);
    end
endtask

// Register offsets
localparam CONTROL  = 32'h00, STATUS = 32'h04, MODE = 32'h08, RATE_K = 32'h0C;
localparam START_IX = 32'h10, END_IX = 32'h14, LOOP_IX = 32'h18, COUNT = 32'h1C;
localparam IDLE_CD  = 32'h20, MINPULSE = 32'h24, CURRENT = 32'h28;
localparam COMP_LO  = 32'h2C, COMP_HI = 32'h30;
localparam TSSTART_LO = 32'h34, TSSTOP_LO = 32'h3C;
localparam RAMDEP   = 32'h44, VERSION = 32'h48;
localparam RAM_BASE = 32'h10000;

// VALID must be held through the clock edge that samples READY high --
// deasserting at the mid-cycle negedge after a level-sensitive wait() kills
// the handshake before it happens. Sample READY only at posedges.
task axi_write(input [31:0] addr, input [31:0] data);
begin
    @(negedge aclk);
    awaddr = addr; wdata = data;
    awvalid = 1; wvalid = 1;
    do @(posedge aclk); while (!(awready && wready));
    @(negedge aclk);
    awvalid = 0; wvalid = 0;
    while (!bvalid) @(posedge aclk);
    @(negedge aclk);
end
endtask

// Skewed-valid variant: AWVALID and WVALID asserted `skew` cycles apart.
// This is the stimulus that historically exposed the joint-accept FSM's
// anti-phase deadlock (see axi_lite_registers.v) -- the copied FSM here must
// survive it too.
task axi_write_skewed(input [31:0] addr, input [31:0] data, input integer skew);
begin
    @(negedge aclk);
    if (skew >= 0) begin
        awaddr = addr; awvalid = 1;
        repeat (skew) @(negedge aclk);
        wdata = data; wvalid = 1;
    end else begin
        wdata = data; wvalid = 1;
        repeat (-skew) @(negedge aclk);
        awaddr = addr; awvalid = 1;
    end
    do @(posedge aclk); while (!(awready && wready));
    @(negedge aclk);
    awvalid = 0; wvalid = 0;
    while (!bvalid) @(posedge aclk);
    @(negedge aclk);
end
endtask

reg [31:0] rd;
task axi_read(input [31:0] addr);
begin
    @(negedge aclk);
    araddr = addr; arvalid = 1;
    do @(posedge aclk); while (!arready);
    @(negedge aclk);
    arvalid = 0;
    while (!rvalid) @(posedge aclk);
    rd = rdata;
    @(negedge aclk);
end
endtask

// Count frames on the wire
integer sync_rises = 0;
always @(posedge dac_sync_n) if (prstn) sync_rises = sync_rises + 1;

integer i;
reg [31:0] status_snap;

initial begin
    repeat (10) @(posedge aclk);
    aresetn = 1; prstn = 1;
    repeat (10) @(posedge aclk);

    // ---- IDs ----
    axi_read(VERSION);
    check(rd == 32'h5354_0100, "VERSION reads 0x53540100");
    axi_read(RAMDEP);
    check(rd == 32'd16384, "RAM_DEPTH reads 16384");

    // ---- Config write/readback ----
    axi_write(RATE_K, 32'd3);
    axi_read(RATE_K);
    check(rd == 32'd3, "RATE_K readback");
    // Skewed-valid writes must complete (no anti-phase deadlock) and land
    axi_write_skewed(RATE_K, 32'd5, 3);
    axi_read(RATE_K);
    check(rd == 32'd5, "skewed write (AW leads) lands");
    axi_write_skewed(RATE_K, 32'd7, -3);
    axi_read(RATE_K);
    check(rd == 32'd7, "skewed write (W leads) lands");
    axi_write(IDLE_CD, 32'h4444_2222);
    axi_read(IDLE_CD);
    check(rd == 32'h4444_2222, "IDLE_CODES readback");

    // ---- Frame RAM upload + readback ----
    for (i = 0; i < 16; i = i + 1)
        axi_write(RAM_BASE + 4*i, 32'h00080100 + i);
    for (i = 0; i < 16; i = i + 1) begin
        axi_read(RAM_BASE + 4*i);
        check(rd == 32'h00080100 + i, "frame RAM readback");
    end
    // High address (aperture end)
    axi_write(RAM_BASE + 4*16383, 32'hABCD1234);
    axi_read(RAM_BASE + 4*16383);
    check(rd == 32'hABCD1234, "frame RAM last-word readback");

    // ---- Full playback run through the bus ----
    axi_write(RATE_K, 32'd1);
    axi_write(START_IX, 0); axi_write(END_IX, 7); axi_write(LOOP_IX, 0);
    axi_write(COUNT, 8);
    axi_write(MODE, 32'h0);         // finite, no trigger, power-down idle
    sync_rises = 0;
    axi_write(CONTROL, 32'h1);      // start
    // running must be visible over the bus
    rd = 0;
    for (i = 0; i < 100 && !rd[0]; i = i + 1)
        axi_read(STATUS);
    check(rd[0] == 1'b1, "STATUS.running set after start");
    check(dac_running == 1'b1, "dac_running pin follows");
    // wait for completion
    for (i = 0; i < 10000 && (rd[0] || rd[6]); i = i + 1)
        axi_read(STATUS);
    check(rd[0] == 1'b0 && rd[6] == 1'b0, "run + idle sequence complete");
    repeat (100) @(posedge aclk);
    check(sync_rises == 9, "8 frames + 1 power-down on the wire");
    axi_read(COMP_LO);
    check(rd == 32'd8, "COMPLETED_LO == 8");
    axi_read(TSSTART_LO);
    check(rd != 32'd0, "TS_START latched");
    axi_read(TSSTOP_LO);
    check(rd != 32'd0, "TS_STOP latched");

    // ---- Write-while-running interlock ----
    axi_write(MODE, 32'h1);         // continuous
    axi_write(CONTROL, 32'h1);      // start
    rd = 0;
    for (i = 0; i < 100 && !rd[0]; i = i + 1)
        axi_read(STATUS);
    check(rd[0] == 1'b1, "continuous run started");
    axi_write(RAM_BASE + 4*5, 32'hDEAD_BEEF);   // must be blocked
    axi_read(STATUS);
    check(rd[4] == 1'b1, "sticky RAM-write-while-running set");
    axi_write(CONTROL, 32'h8);      // clear sticky
    axi_read(STATUS);
    check(rd[4] == 1'b0, "sticky cleared");
    axi_write(CONTROL, 32'h2);      // stop
    rd = 32'hFF;
    for (i = 0; i < 10000 && (rd[0] || rd[6]); i = i + 1)
        axi_read(STATUS);
    check(rd[0] == 1'b0, "stopped");
    axi_read(RAM_BASE + 4*5);
    check(rd == 32'h00080105, "blocked write left RAM word intact");

    if (errors == 0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #20_000_000;
    $display("FAIL: timeout");
    $display("RESULT: FAIL");
    $finish;
end

endmodule
