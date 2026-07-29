// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Stimulus engine testbench: playback order, divider spacing, stop/idle
// sequences, hardware trigger (edge, gate, glitch filter, retrigger), bad
// starts, and the datasheet inter-frame timing floor.
//
// A SPI mode-1 monitor decodes every frame off the wires (sample on SCLK
// falling edge, frame closes on SYNC_N rising edge) -- the checks run on
// what the DAC would actually receive, not on internal state.
`timescale 1ns/1ps

module stim_engine_tb;

localparam integer RAM_DEPTH = 16384;
localparam integer ADDR_W = $clog2(RAM_DEPTH);
localparam integer MASTER = 350;

reg clk = 0;
always #5.952 clk = ~clk;   // 84 MHz

reg rstn = 0;

// cfg
reg        cfg_continuous = 0, cfg_hw_arm = 0, cfg_trig_pol = 0;
reg        cfg_retrig_restart = 0, cfg_idle_drive_codes = 0;
reg [1:0]  cfg_trig_mode = 0;
reg [2:0]  cfg_trig_line = 0;
reg [31:0] cfg_rate_k = 1, cfg_frame_count = 0;
reg [31:0] cfg_idle_codes = {16'hB0B0, 16'hA0A0};
reg [31:0] cfg_trig_minpulse = 84;
reg [ADDR_W-1:0] cfg_start_index = 0, cfg_end_index = 0, cfg_loop_index = 0;
// pulses
reg p_start = 0, p_stop = 0, p_soft_reset = 0, p_clear_sticky = 0;
reg p_zero = 0, p_powerdown = 0, p_dac_soft_reset = 0;
reg [7:0] digital_in = 0;
reg [63:0] master_timestamp = 0;
always @(posedge clk) master_timestamp <= master_timestamp + 1;

wire ram_en;
wire [ADDR_W-1:0] ram_addr;
wire [31:0] ram_rdata;
wire dac_sclk, dac_sync_n, dac_sdin;
wire running, shifter_busy, armed, cfg_valid, sticky_bad_start, idle_seq_active;
wire [ADDR_W-1:0] current_index;
wire [63:0] completed_count, ts_start, ts_stop;

stim_frame_ram #(.DEPTH(RAM_DEPTH), .ADDR_W(ADDR_W)) ram_i (
    .clka(clk), .ena(1'b0), .wea(1'b0), .addra({ADDR_W{1'b0}}),
    .dina(32'd0), .douta(),
    .clkb(clk), .enb(ram_en), .addrb(ram_addr), .doutb(ram_rdata)
);

stim_engine #(.RAM_DEPTH(RAM_DEPTH), .ADDR_W(ADDR_W)) dut (
    .clk(clk), .rstn(rstn),
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
    .ram_en(ram_en), .ram_addr(ram_addr), .ram_rdata(ram_rdata),
    .dac_sclk(dac_sclk), .dac_sync_n(dac_sync_n), .dac_sdin(dac_sdin),
    .running(running), .shifter_busy(shifter_busy), .armed(armed),
    .cfg_valid(cfg_valid), .sticky_bad_start(sticky_bad_start),
    .idle_seq_active(idle_seq_active), .current_index(current_index),
    .completed_count(completed_count), .ts_start(ts_start), .ts_stop(ts_stop)
);

integer errors = 0;
task check(input cond, input [511:0] msg);
    if (!cond) begin
        errors = errors + 1;
        $display("FAIL: %0s (t=%0t)", msg, $time);
    end
endtask

// ------------------------------------------------------------ SPI monitor --
integer cyc = 0;
always @(posedge clk) cyc = cyc + 1;

reg [23:0] mon_shift;
integer    mon_bits = 0;
integer    frame_count = 0;
reg [23:0] frames [0:255];
integer    frame_start_cyc [0:255];
integer    prev_sync_rise_cyc = -1;
integer    min_gap_cyc = 1_000_000;   // smallest SYNC_N-high gap seen

always @(negedge dac_sclk) begin
    if (!dac_sync_n) begin
        mon_shift = {mon_shift[22:0], dac_sdin};
        mon_bits = mon_bits + 1;
    end
end

always @(negedge dac_sync_n) begin
    mon_bits = 0;
    mon_shift = 24'd0;
    if (frame_count < 256)
        frame_start_cyc[frame_count] = cyc;
    if (prev_sync_rise_cyc >= 0 && (cyc - prev_sync_rise_cyc) < min_gap_cyc)
        min_gap_cyc = cyc - prev_sync_rise_cyc;
end

always @(posedge dac_sync_n) begin
    if (rstn) begin
        check(mon_bits == 24, "frame closed with != 24 bits");
        if (frame_count < 256)
            frames[frame_count] = mon_shift;
        frame_count = frame_count + 1;
        prev_sync_rise_cyc = cyc;
    end
end

task clear_monitor;
begin
    frame_count = 0;
    prev_sync_rise_cyc = -1;
    min_gap_cyc = 1_000_000;
end
endtask

// A task output argument only copies back at task exit, so a pulse through a
// task never reaches the signal -- use a macro.
`define PULSE(sig) begin @(negedge clk); sig = 1; @(negedge clk); sig = 0; end

task wait_idle;
begin
    wait (running === 1'b0 && idle_seq_active === 1'b0 && shifter_busy === 1'b0);
    repeat (10) @(posedge clk);
end
endtask

integer i;
reg [63:0] ts_start_saved;

initial begin
    // Preload the frame RAM: word i = 0x080000 | i (recognizable payloads).
    for (i = 0; i < 64; i = i + 1)
        ram_i.mem[i] = 24'h080000 | i[15:0];

    repeat (5) @(posedge clk);
    rstn = 1;
    repeat (5) @(posedge clk);

    // ---- Test 1: finite run, k=1, frames 0..9, power-down idle default ----
    cfg_start_index = 0; cfg_end_index = 9; cfg_loop_index = 0;
    cfg_frame_count = 10; cfg_continuous = 0; cfg_rate_k = 1;
    cfg_idle_drive_codes = 0;
    clear_monitor;
    `PULSE(p_start)
    wait (running === 1'b1);
    check(ts_start != 64'd0, "ts_start latched");
    ts_start_saved = ts_start;
    wait_idle;
    check(frame_count == 11, "finite run: 10 frames + 1 power-down frame");
    for (i = 0; i < 10; i = i + 1)
        check(frames[i] == (24'h080000 | i[15:0]), "finite run frame payload/order");
    check(frames[10] == 24'h030003, "power-down idle frame after finite run");
    check(completed_count == 10, "completed_count == 10");
    // Spacing: consecutive playback frames exactly 350*k cycles apart
    for (i = 1; i < 10; i = i + 1)
        check(frame_start_cyc[i] - frame_start_cyc[i-1] == MASTER,
              "k=1 frame spacing == 350");
    check(ts_stop > ts_start_saved, "ts_stop latched after ts_start");
    check(min_gap_cyc >= 84, "SYNC_N high gap >= 1us everywhere (t_DACWAIT)");

    // ---- Test 2: continuous with loop region + graceful stop ----
    cfg_start_index = 0; cfg_end_index = 4; cfg_loop_index = 2;
    cfg_continuous = 1; cfg_rate_k = 2;
    clear_monitor;
    `PULSE(p_start)
    wait (frame_count >= 11);   // 0 1 2 3 4 | 2 3 4 | 2 3 4
    `PULSE(p_stop)
    wait_idle;
    check(frames[0] == 24'h080000 && frames[4] == 24'h080004, "first pass 0..4");
    check(frames[5] == 24'h080002, "wrap to LOOP_INDEX=2");
    check(frames[8] == 24'h080002, "second wrap to LOOP_INDEX=2");
    for (i = 1; i < 10; i = i + 1)
        check(frame_start_cyc[i] - frame_start_cyc[i-1] == 2*MASTER,
              "k=2 frame spacing == 700");
    check(frames[frame_count-1] == 24'h030003, "power-down after stop");

    // ---- Test 3: STIM_ZERO with driven idle codes ----
    cfg_idle_drive_codes = 1;
    cfg_continuous = 1; cfg_rate_k = 1;
    clear_monitor;
    `PULSE(p_start)
    wait (frame_count >= 3);
    `PULSE(p_zero)
    wait_idle;
    check(frames[frame_count-2] == {8'h08, 16'hA0A0}, "idle code A frame");
    check(frames[frame_count-1] == {8'h09, 16'hB0B0}, "idle code B frame");

    // ---- Test 4: powerdown command overrides driven-codes config ----
    clear_monitor;
    `PULSE(p_start)
    wait (frame_count >= 2);
    `PULSE(p_powerdown)
    wait_idle;
    check(frames[frame_count-1] == 24'h030003, "p_powerdown forces CONFIG frame");
    cfg_idle_drive_codes = 0;

    // ---- Test 5: bad start (k=0) -> sticky, no run; clear works ----
    cfg_rate_k = 0;
    clear_monitor;
    `PULSE(p_start)
    repeat (100) @(posedge clk);
    check(running === 1'b0 && frame_count == 0, "k=0 start refused");
    check(sticky_bad_start === 1'b1, "sticky_bad_start set");
    `PULSE(p_clear_sticky)
    repeat (5) @(posedge clk);
    check(sticky_bad_start === 1'b0, "sticky cleared");
    cfg_rate_k = 1;

    // ---- Test 6: edge trigger with glitch filter ----
    cfg_hw_arm = 1; cfg_trig_mode = 1; cfg_trig_line = 3;
    cfg_trig_minpulse = 84;
    cfg_continuous = 0; cfg_frame_count = 3;
    cfg_start_index = 0; cfg_end_index = 2; cfg_loop_index = 0;
    clear_monitor;
    repeat (10) @(posedge clk);
    check(armed === 1'b1, "armed reported");
    // 20-cycle glitch: below the 84-cycle filter, must not start
    digital_in[3] = 1; repeat (20) @(posedge clk); digital_in[3] = 0;
    repeat (300) @(posedge clk);
    check(running === 1'b0 && frame_count == 0, "sub-minpulse glitch rejected");
    // Real trigger
    digital_in[3] = 1; repeat (200) @(posedge clk); digital_in[3] = 0;
    wait_idle;
    check(frame_count == 4, "edge trigger: 3 frames + power-down");

    // ---- Test 6b: retrigger-restart rewinds to START_INDEX ----
    cfg_retrig_restart = 1;
    cfg_continuous = 0; cfg_frame_count = 10;
    cfg_start_index = 0; cfg_end_index = 9; cfg_loop_index = 0;
    clear_monitor;
    digital_in[3] = 1; repeat (200) @(posedge clk); digital_in[3] = 0;
    wait (frame_count >= 3);
    digital_in[3] = 1; repeat (200) @(posedge clk); digital_in[3] = 0;
    wait_idle;
    begin : retrig_scan
        integer j;
        reg found;
        found = 0;
        for (j = 2; j < frame_count - 1; j = j + 1)
            if (frames[j] == 24'h080000) found = 1;
        check(found, "retrigger restarted from START_INDEX");
    end
    cfg_retrig_restart = 0;

    // ---- Test 7: gate mode ----
    cfg_trig_mode = 2; cfg_continuous = 1;
    clear_monitor;
    digital_in[3] = 1;
    wait (frame_count >= 5);
    check(running === 1'b1, "gate high -> running");
    digital_in[3] = 0;
    wait_idle;
    check(frames[frame_count-1] == 24'h030003, "gate low -> stop + power-down");
    cfg_hw_arm = 0; cfg_trig_mode = 0;

    // ---- Test 8: DAC soft-reset maintenance frame from idle ----
    clear_monitor;
    `PULSE(p_dac_soft_reset)
    wait (frame_count >= 1);
    wait_idle;
    check(frames[0] == 24'h05000A, "DAC soft-reset frame");

    // ---- Test 9: stop pulse landing in the RD pipeline is not lost ----
    cfg_continuous = 1; cfg_rate_k = 1;
    clear_monitor;
    `PULSE(p_start)
    wait (frame_count >= 1);
    // Align a stop pulse onto the tick: wait until the engine issues the next
    // RAM read (ram_en high = S_RUN's tick cycle), then pulse immediately.
    @(posedge ram_en);
    `PULSE(p_stop)
    wait_idle;
    check(1'b1, "stop during RD pipeline completed (no hang)");

    if (errors == 0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #80_000_000;   // 80 ms guard
    $display("FAIL: timeout");
    $display("RESULT: FAIL");
    $finish;
end

endmodule
