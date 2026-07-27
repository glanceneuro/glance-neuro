// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Stimulus peripheral top: AXI-Lite registers + frame RAM + playback engine
// + DAC70502 SPI pins. Instantiated in the block design as a module
// reference (like axi_lite_registers / data_generator).
//
//   s_axi_*        AXI-Lite slave, 128K aperture (regs + frame RAM)
//   pl_clk/pl_rstn 84 MHz engine domain; reset MUST come from
//                  proc_sys_reset_0_84M (see CLAUDE.md on cross-domain resets)
//   digital_in     carrier TTL inputs (shared with data_generator's tap)
//   master_timestamp  acquisition sample counter from data_generator_wrapper
//   dac_*          DAC70502 SPI pins (W18 / R18 / T17)
`timescale 1ns/1ps

module stim_top (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire        pl_clk,
    input  wire        pl_rstn,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire [7:0]  digital_in,
    input  wire [63:0] master_timestamp,

    output wire        dac_sclk,
    output wire        dac_sync_n,
    output wire        dac_sdin,
    output wire        dac_running
);

localparam integer RAM_DEPTH = 16384;
localparam integer ADDR_W    = $clog2(RAM_DEPTH);

wire              ram_ena, ram_wea;
wire [ADDR_W-1:0] ram_addra;
wire [31:0]       ram_dina, ram_douta;
wire              ram_enb;
wire [ADDR_W-1:0] ram_addrb;
wire [31:0]       ram_doutb;

wire              cfg_continuous, cfg_hw_arm, cfg_trig_pol, cfg_retrig_restart;
wire              cfg_idle_drive_codes;
wire [1:0]        cfg_trig_mode;
wire [2:0]        cfg_trig_line;
wire [31:0]       cfg_rate_k, cfg_frame_count, cfg_idle_codes, cfg_trig_minpulse;
wire [ADDR_W-1:0] cfg_start_index, cfg_end_index, cfg_loop_index;
wire              p_start, p_stop, p_soft_reset, p_clear_sticky;
wire              p_zero, p_powerdown, p_dac_soft_reset;
wire              eng_running, eng_shifter_busy, eng_armed, eng_cfg_valid;
wire              eng_sticky_bad_start, eng_idle_seq_active;
wire [ADDR_W-1:0] eng_current_index;
wire [63:0]       eng_completed, eng_ts_start, eng_ts_stop;

assign dac_running = eng_running;

stim_axi_regs #(.RAM_DEPTH(RAM_DEPTH), .ADDR_W(ADDR_W)) regs_i (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .pl_clk(pl_clk), .pl_rstn(pl_rstn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .ram_ena(ram_ena), .ram_wea(ram_wea), .ram_addra(ram_addra),
    .ram_dina(ram_dina), .ram_douta(ram_douta),
    .cfg_continuous(cfg_continuous), .cfg_hw_arm(cfg_hw_arm),
    .cfg_trig_mode(cfg_trig_mode), .cfg_trig_pol(cfg_trig_pol),
    .cfg_trig_line(cfg_trig_line), .cfg_retrig_restart(cfg_retrig_restart),
    .cfg_idle_drive_codes(cfg_idle_drive_codes), .cfg_rate_k(cfg_rate_k),
    .cfg_start_index(cfg_start_index), .cfg_end_index(cfg_end_index),
    .cfg_loop_index(cfg_loop_index), .cfg_frame_count(cfg_frame_count),
    .cfg_idle_codes(cfg_idle_codes), .cfg_trig_minpulse(cfg_trig_minpulse),
    .p_start(p_start), .p_stop(p_stop), .p_soft_reset(p_soft_reset),
    .p_clear_sticky(p_clear_sticky), .p_zero(p_zero), .p_powerdown(p_powerdown),
    .p_dac_soft_reset(p_dac_soft_reset),
    .eng_running(eng_running), .eng_shifter_busy(eng_shifter_busy),
    .eng_armed(eng_armed), .eng_cfg_valid(eng_cfg_valid),
    .eng_sticky_bad_start(eng_sticky_bad_start),
    .eng_idle_seq_active(eng_idle_seq_active),
    .eng_current_index(eng_current_index), .eng_completed(eng_completed),
    .eng_ts_start(eng_ts_start), .eng_ts_stop(eng_ts_stop),
    .digital_in(digital_in)
);

stim_frame_ram #(.DEPTH(RAM_DEPTH), .ADDR_W(ADDR_W)) ram_i (
    .clka(s_axi_aclk), .ena(ram_ena), .wea(ram_wea),
    .addra(ram_addra), .dina(ram_dina), .douta(ram_douta),
    .clkb(pl_clk), .enb(ram_enb), .addrb(ram_addrb), .doutb(ram_doutb)
);

stim_engine #(.RAM_DEPTH(RAM_DEPTH), .ADDR_W(ADDR_W)) engine_i (
    .clk(pl_clk), .rstn(pl_rstn),
    .cfg_continuous(cfg_continuous), .cfg_hw_arm(cfg_hw_arm),
    .cfg_trig_mode(cfg_trig_mode), .cfg_trig_pol(cfg_trig_pol),
    .cfg_trig_line(cfg_trig_line), .cfg_retrig_restart(cfg_retrig_restart),
    .cfg_idle_drive_codes(cfg_idle_drive_codes), .cfg_rate_k(cfg_rate_k),
    .cfg_start_index(cfg_start_index), .cfg_end_index(cfg_end_index),
    .cfg_loop_index(cfg_loop_index), .cfg_frame_count(cfg_frame_count),
    .cfg_idle_codes(cfg_idle_codes), .cfg_trig_minpulse(cfg_trig_minpulse),
    .p_start(p_start), .p_stop(p_stop), .p_soft_reset(p_soft_reset),
    .p_clear_sticky(p_clear_sticky), .p_zero(p_zero), .p_powerdown(p_powerdown),
    .p_dac_soft_reset(p_dac_soft_reset),
    .digital_in(digital_in), .master_timestamp(master_timestamp),
    .ram_en(ram_enb), .ram_addr(ram_addrb), .ram_rdata(ram_doutb),
    .dac_sclk(dac_sclk), .dac_sync_n(dac_sync_n), .dac_sdin(dac_sdin),
    .running(eng_running), .shifter_busy(eng_shifter_busy), .armed(eng_armed),
    .cfg_valid(eng_cfg_valid), .sticky_bad_start(eng_sticky_bad_start),
    .idle_seq_active(eng_idle_seq_active), .current_index(eng_current_index),
    .completed_count(eng_completed), .ts_start(eng_ts_start), .ts_stop(eng_ts_stop)
);

endmodule
