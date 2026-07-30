// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// AXI-Lite register file + frame-RAM aperture for the stimulus engine.
//
// Aperture layout (byte offsets inside the 128K window):
//   0x00000 + 4*n : registers (map below)
//   0x10000 + 4*i : FRAME_RAM word i (16384 x 32-bit, RW; reads back for CRC)
//
//   n  reg           access  content
//   0  CONTROL       W1P     [0]start [1]stop [2]soft_reset [3]clear_sticky
//                            [4]force_zero [5]force_powerdown [6]dac_soft_reset
//   1  STATUS        RO      [0]running [1]shifter_busy [2]armed [3]cfg_ok
//                            [4]sticky_ram_write [5]sticky_bad_start
//                            [6]idle_seq_active [15:8]digital_in
//   2  MODE          RW      [0]continuous [1]hw_arm [3:2]trig_mode [4]trig_pol
//                            [7:5]trig_line [8]retrig_restart [9]idle_drive_codes
//   3  RATE_K        RW      frame-rate divider k (>=1; 240 kf/s / k)
//   4  START_INDEX   RW      5 END_INDEX  6 LOOP_INDEX  7 FRAME_COUNT
//   8  IDLE_CODES    RW      {codeB[15:0], codeA[15:0]} (MSB-aligned DAC codes)
//   9  TRIG_MINPULSE RW      trigger glitch filter, 84 MHz clocks
//  10  CURRENT_INDEX RO     11/12 COMPLETED LO/HI RO
//  13/14 TS_START LO/HI RO  15/16 TS_STOP LO/HI RO
//  17  RAM_DEPTH     RO     18 VERSION RO
//
// CDC follows axi_lite_registers.v: config crosses AXI->engine through 2-FF
// stages and is quasi-static (the engine latches it only at start); one-shot
// CONTROL bits cross as toggle flips edge-detected in the engine domain;
// status words are registered in the engine domain and cross back through
// 2-FF stages (multi-bit skew accepted -- the moving counters are debug/
// observability, and the timestamp latches are stable before `running`
// clears, so a reader that waits for running==0 sees settled values).
//
// The write FSM uses the joint-accept form: AWREADY/WREADY assert together
// only when both VALIDs are up -- see the anti-phase deadlock note in
// axi_lite_registers.v (proven in sim/axi_lite_write_tb.sv).
`timescale 1ns/1ps

module stim_axi_regs #(
    parameter integer RAM_DEPTH = 16384,
    parameter integer ADDR_W    = $clog2(RAM_DEPTH)
)(
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire        pl_clk,
    input  wire        pl_rstn,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Frame RAM port A (AXI domain)
    output reg               ram_ena,
    output reg               ram_wea,
    output reg  [ADDR_W-1:0] ram_addra,
    output reg  [31:0]       ram_dina,
    input  wire [31:0]       ram_douta,

    // Engine configuration (pl_clk domain, quasi-static)
    output wire              cfg_continuous,
    output wire              cfg_hw_arm,
    output wire [1:0]        cfg_trig_mode,
    output wire              cfg_trig_pol,
    output wire [2:0]        cfg_trig_line,
    output wire              cfg_retrig_restart,
    output wire              cfg_idle_drive_codes,
    output wire [31:0]       cfg_rate_k,
    output wire [ADDR_W-1:0] cfg_start_index,
    output wire [ADDR_W-1:0] cfg_end_index,
    output wire [ADDR_W-1:0] cfg_loop_index,
    output wire [31:0]       cfg_frame_count,
    output wire [31:0]       cfg_idle_codes,
    output wire [31:0]       cfg_trig_minpulse,

    // Engine command pulses (pl_clk domain)
    output wire              p_start,
    output wire              p_stop,
    output wire              p_soft_reset,
    output wire              p_clear_sticky,
    output wire              p_zero,
    output wire              p_powerdown,
    output wire              p_dac_soft_reset,

    // Engine status (pl_clk domain inputs)
    input  wire              eng_running,
    input  wire              eng_shifter_busy,
    input  wire              eng_armed,
    input  wire              eng_cfg_valid,
    input  wire              eng_sticky_bad_start,
    input  wire              eng_idle_seq_active,
    input  wire [ADDR_W-1:0] eng_current_index,
    input  wire [63:0]       eng_completed,
    input  wire [63:0]       eng_ts_start,
    input  wire [63:0]       eng_ts_stop,
    input  wire [7:0]        digital_in
);

localparam integer N_CFG = 8;  // MODE..TRIG_MINPULSE shadow registers (idx 2..9)
localparam [31:0] VERSION = 32'h5354_0100; // "ST" + v1.0

// ------------------------------------------------------- AXI-domain state --
reg [31:0] cfg_axi [0:N_CFG-1];     // idx-2 .. idx-9
reg [6:0]  ctl_toggle;              // one toggle per CONTROL W1P bit
reg        sticky_ram_write;

// Engine status crossed into the AXI domain (bulk 2-FF, house pattern)
localparam integer N_STAT_W = 8;    // status, current, comp lo/hi, ts_start lo/hi, ts_stop lo/hi
reg [31:0] stat_pl  [0:N_STAT_W-1];
reg [31:0] stat_s1  [0:N_STAT_W-1];
reg [31:0] stat_axi [0:N_STAT_W-1];

// running, synchronized to the AXI domain: gates RAM writes
(* ASYNC_REG = "TRUE" *) reg run_ax0, run_ax1;
always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        run_ax0 <= 1'b0; run_ax1 <= 1'b0;
    end else begin
        run_ax0 <= eng_running; run_ax1 <= run_ax0;
    end
end

// ----------------------------------------------------------- write channel --
wire aw_is_ram = s_axi_awaddr[16];
wire [4:0] aw_reg = s_axi_awaddr[6:2];
integer i;

wire wr_fire = s_axi_awready & s_axi_awvalid & s_axi_wready & s_axi_wvalid;

always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_bresp   <= 2'b00;
        ctl_toggle    <= 7'd0;
        sticky_ram_write <= 1'b0;
        for (i = 0; i < N_CFG; i = i + 1)
            cfg_axi[i] <= 32'd0;
        cfg_axi[1] <= 32'd1;    // RATE_K resets to 1 so a raw start is legal
        cfg_axi[7] <= 32'd84;   // TRIG_MINPULSE default 1 us
    end else begin
        s_axi_awready <= ~s_axi_awready & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
        s_axi_wready  <= ~s_axi_wready  & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;

        if (wr_fire) begin
            s_axi_bresp <= 2'b00;
            if (aw_is_ram) begin
                if (run_ax1)
                    sticky_ram_write <= 1'b1;   // blocked, remembered, OKAY resp
                // the accepted write reaches the RAM through the port arbiter
            end else if (aw_reg == 5'd0) begin
                // CONTROL: flip a toggle per set W1P bit
                ctl_toggle <= ctl_toggle ^ s_axi_wdata[6:0];
                if (s_axi_wdata[3])
                    sticky_ram_write <= 1'b0;
            end else if (aw_reg >= 5'd2 && aw_reg <= 5'd9) begin
                cfg_axi[aw_reg - 5'd2] <= s_axi_wdata;
            end else begin
                s_axi_bresp <= 2'b10;   // RO or unmapped register
            end
            s_axi_bvalid <= 1'b1;
        end else if (s_axi_bvalid & s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end
end

// ------------------------------------------------------------ read channel --
// Register reads answer in one cycle; RAM reads take two extra cycles for
// the BRAM output register (ISSUE -> WAIT -> data valid).
localparam [1:0] R_IDLE = 2'd0, R_RAMWAIT = 2'd1, R_RAMDATA = 2'd2;
reg [1:0] rstate;

wire ar_is_ram = s_axi_araddr[16];
wire [4:0] ar_reg = s_axi_araddr[6:2];

wire rd_fire = s_axi_arvalid & s_axi_arready;

always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        s_axi_rdata   <= 32'd0;
        s_axi_rresp   <= 2'b00;
        rstate        <= R_IDLE;
    end else begin
        // The ~(AWVALID & WVALID) term makes a read fire and a write fire to
        // the shared RAM port mutually exclusive by construction: ARREADY can
        // only set when no complete write was pending the cycle before, and a
        // write can only fire when its readys set the cycle before.
        s_axi_arready <= ~s_axi_arready & s_axi_arvalid & ~s_axi_rvalid
                         & (rstate == R_IDLE)
                         & ~(s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid);

        case (rstate)
        R_IDLE: begin
            if (rd_fire) begin
                if (ar_is_ram) begin
                    rstate    <= R_RAMWAIT;
                end else begin
                    s_axi_rvalid <= 1'b1;
                    s_axi_rresp  <= 2'b00;
                    case (ar_reg)
                        5'd1:  s_axi_rdata <= stat_axi[0] | {26'd0, sticky_ram_write, 4'd0};
                        5'd2:  s_axi_rdata <= cfg_axi[0];
                        5'd3:  s_axi_rdata <= cfg_axi[1];
                        5'd4:  s_axi_rdata <= cfg_axi[2];
                        5'd5:  s_axi_rdata <= cfg_axi[3];
                        5'd6:  s_axi_rdata <= cfg_axi[4];
                        5'd7:  s_axi_rdata <= cfg_axi[5];
                        5'd8:  s_axi_rdata <= cfg_axi[6];
                        5'd9:  s_axi_rdata <= cfg_axi[7];
                        5'd10: s_axi_rdata <= stat_axi[1];
                        5'd11: s_axi_rdata <= stat_axi[2];
                        5'd12: s_axi_rdata <= stat_axi[3];
                        5'd13: s_axi_rdata <= stat_axi[4];
                        5'd14: s_axi_rdata <= stat_axi[5];
                        5'd15: s_axi_rdata <= stat_axi[6];
                        5'd16: s_axi_rdata <= stat_axi[7];
                        5'd17: s_axi_rdata <= RAM_DEPTH;
                        5'd18: s_axi_rdata <= VERSION;
                        default: begin
                            s_axi_rdata <= 32'hdeadbeef;
                            s_axi_rresp <= 2'b10;
                        end
                    endcase
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
        R_RAMWAIT: rstate <= R_RAMDATA;
        R_RAMDATA: begin
            s_axi_rdata  <= ram_douta;
            s_axi_rresp  <= 2'b00;
            s_axi_rvalid <= 1'b1;
            rstate       <= R_IDLE;
        end
        default: rstate <= R_IDLE;
        endcase
    end
end

// ------------------------------------------------- RAM port A drive (AXI) --
// Single driver for the shared port: writes and readback reads cannot fire
// in the same cycle (see the ARREADY gating above).
always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        ram_ena   <= 1'b0;
        ram_wea   <= 1'b0;
        ram_addra <= {ADDR_W{1'b0}};
        ram_dina  <= 32'd0;
    end else begin
        ram_ena <= 1'b0;
        ram_wea <= 1'b0;
        if (wr_fire && aw_is_ram && !run_ax1) begin
            ram_ena   <= 1'b1;
            ram_wea   <= 1'b1;
            ram_addra <= s_axi_awaddr[2 +: ADDR_W];
            ram_dina  <= s_axi_wdata;
        end else if (rd_fire && ar_is_ram) begin
            ram_ena   <= 1'b1;
            ram_addra <= s_axi_araddr[2 +: ADDR_W];
        end
    end
end

// -------------------------------------------- CDC: config, pulses (AXI->PL) --
reg [31:0] cfg_s1 [0:N_CFG-1];
reg [31:0] cfg_s2 [0:N_CFG-1];
integer j;
always @(posedge pl_clk) begin
    if (!pl_rstn) begin
        for (j = 0; j < N_CFG; j = j + 1) begin
            cfg_s1[j] <= 32'd0;
            cfg_s2[j] <= 32'd0;
        end
        cfg_s1[1] <= 32'd1; cfg_s2[1] <= 32'd1;
        cfg_s1[7] <= 32'd84; cfg_s2[7] <= 32'd84;
    end else begin
        for (j = 0; j < N_CFG; j = j + 1) begin
            cfg_s1[j] <= cfg_axi[j];
            cfg_s2[j] <= cfg_s1[j];
        end
    end
end

assign cfg_continuous       = cfg_s2[0][0];
assign cfg_hw_arm           = cfg_s2[0][1];
assign cfg_trig_mode        = cfg_s2[0][3:2];
assign cfg_trig_pol         = cfg_s2[0][4];
assign cfg_trig_line        = cfg_s2[0][7:5];
assign cfg_retrig_restart   = cfg_s2[0][8];
assign cfg_idle_drive_codes = cfg_s2[0][9];
assign cfg_rate_k           = cfg_s2[1];
assign cfg_start_index      = cfg_s2[2][ADDR_W-1:0];
assign cfg_end_index        = cfg_s2[3][ADDR_W-1:0];
assign cfg_loop_index       = cfg_s2[4][ADDR_W-1:0];
assign cfg_frame_count      = cfg_s2[5];
assign cfg_idle_codes       = cfg_s2[6];
assign cfg_trig_minpulse    = cfg_s2[7];

(* ASYNC_REG = "TRUE" *) reg [6:0] tog_s1, tog_s2;
reg [6:0] tog_s3;
always @(posedge pl_clk) begin
    if (!pl_rstn) begin
        tog_s1 <= 7'd0; tog_s2 <= 7'd0; tog_s3 <= 7'd0;
    end else begin
        tog_s1 <= ctl_toggle;
        tog_s2 <= tog_s1;
        tog_s3 <= tog_s2;
    end
end
wire [6:0] pulses = tog_s2 ^ tog_s3;
assign p_start          = pulses[0];
assign p_stop           = pulses[1];
assign p_soft_reset     = pulses[2];
assign p_clear_sticky   = pulses[3];
assign p_zero           = pulses[4];
assign p_powerdown      = pulses[5];
assign p_dac_soft_reset = pulses[6];

// ------------------------------------------------ CDC: status (PL -> AXI) --
(* ASYNC_REG = "TRUE" *) reg [7:0] din_pl0, din_pl1;
always @(posedge pl_clk) begin
    if (!pl_rstn) begin
        din_pl0 <= 8'd0; din_pl1 <= 8'd0;
        for (j = 0; j < N_STAT_W; j = j + 1)
            stat_pl[j] <= 32'd0;
    end else begin
        din_pl0 <= digital_in;   // async carrier inputs: sync before packing
        din_pl1 <= din_pl0;
        stat_pl[0] <= {16'd0, din_pl1,
                       1'b0, eng_idle_seq_active, eng_sticky_bad_start, 1'b0,
                       eng_cfg_valid, eng_armed, eng_shifter_busy, eng_running};
        stat_pl[1] <= {{(32-ADDR_W){1'b0}}, eng_current_index};
        stat_pl[2] <= eng_completed[31:0];
        stat_pl[3] <= eng_completed[63:32];
        stat_pl[4] <= eng_ts_start[31:0];
        stat_pl[5] <= eng_ts_start[63:32];
        stat_pl[6] <= eng_ts_stop[31:0];
        stat_pl[7] <= eng_ts_stop[63:32];
    end
end

always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        for (i = 0; i < N_STAT_W; i = i + 1) begin
            stat_s1[i]  <= 32'd0;
            stat_axi[i] <= 32'd0;
        end
    end else begin
        for (i = 0; i < N_STAT_W; i = i + 1) begin
            stat_s1[i]  <= stat_pl[i];
            stat_axi[i] <= stat_s1[i];
        end
    end
end

endmodule
