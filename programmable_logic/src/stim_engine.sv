// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Stimulus playback engine (84 MHz domain, single clock).
//
// Plays 24-bit DAC SPI frames out of the stimulus frame RAM at a fixed
// 240 kframes/s master rate divided by an integer k: one frame every 350*k
// clocks. Playback order is START..END once, then LOOP..END repeated, either
// forever (continuous) or until FRAME_COUNT frames have been sent. Start and
// stop come from software pulses (via the AXI register block's CDC) or from a
// digital-input trigger (edge = one-shot pass, gate = run-while-high). Every
// stop path ends in the configured idle sequence -- DAC power-down (default)
// or driven idle codes -- so the outputs are never left at the last sample.
//
// All cfg_* inputs are quasi-static (written over AXI, stable long before a
// start; the register block guarantees ordering) and are latched into run_*
// registers when a start is accepted, so nothing here changes mid-run (R13:
// divider latched at start). p_* inputs are 1-cycle pulses already in this
// clock domain.
`timescale 1ns/1ps

module stim_engine #(
    parameter integer RAM_DEPTH = 16384,
    parameter integer ADDR_W    = $clog2(RAM_DEPTH),
    // Master frame period in clocks (84 MHz / 350 = 240 kframes/s exactly).
    parameter integer MASTER_PERIOD = 350
)(
    input  wire              clk,
    input  wire              rstn,

    // Quasi-static configuration (AXI domain writes, sampled at start)
    input  wire              cfg_continuous,
    input  wire              cfg_hw_arm,
    input  wire [1:0]        cfg_trig_mode,    // 0 off, 1 edge, 2 gate
    input  wire              cfg_trig_pol,     // 0 active-high/rising
    input  wire [2:0]        cfg_trig_line,
    input  wire              cfg_retrig_restart,
    input  wire              cfg_idle_drive_codes,
    input  wire [31:0]       cfg_rate_k,
    input  wire [ADDR_W-1:0] cfg_start_index,
    input  wire [ADDR_W-1:0] cfg_end_index,
    input  wire [ADDR_W-1:0] cfg_loop_index,
    input  wire [31:0]       cfg_frame_count,
    input  wire [31:0]       cfg_idle_codes,   // {codeB[15:0], codeA[15:0]}
    input  wire [31:0]       cfg_trig_minpulse,

    // Command pulses (already synchronized into this domain)
    input  wire              p_start,
    input  wire              p_stop,
    input  wire              p_soft_reset,
    input  wire              p_clear_sticky,
    input  wire              p_zero,           // stop now, then configured idle state
    input  wire              p_powerdown,      // stop now, then DAC power-down
    input  wire              p_dac_soft_reset, // idle only: DAC TRIGGER soft-reset frame

    input  wire [7:0]        digital_in,       // raw carrier TTL inputs
    input  wire [63:0]       master_timestamp, // acquisition sample counter

    // Frame RAM read port (registered, 1-cycle latency)
    output reg               ram_en,
    output reg  [ADDR_W-1:0] ram_addr,
    input  wire [31:0]       ram_rdata,

    // DAC pins
    output wire              dac_sclk,
    output wire              dac_sync_n,
    output wire              dac_sdin,

    // Status (sampled by the AXI block through 2-FF synchronizers)
    output reg               running,
    output wire              shifter_busy,
    output reg               armed,
    output wire              cfg_valid,
    output reg               sticky_bad_start,
    output reg               idle_seq_active,
    output reg  [ADDR_W-1:0] current_index,
    output reg  [63:0]       completed_count,
    output reg  [63:0]       ts_start,
    output reg  [63:0]       ts_stop
);

// DAC70502 frames the engine synthesizes itself (idle sequence / maintenance).
// Register byte in [23:16], data in [15:0]; data is 16-bit MSB-aligned.
localparam [23:0] FRAME_PWDN      = 24'h030003; // CONFIG: power down A+B, ref stays on
localparam [23:0] FRAME_DAC_RESET = 24'h05000A; // TRIGGER: soft-reset code

// ---------------------------------------------------------------- shifter --
reg         sh_start;
reg  [23:0] sh_frame;
wire        sh_done;

stim_spi_shifter shifter_i (
    .clk(clk), .rstn(rstn),
    .start(sh_start), .frame(sh_frame),
    .busy(shifter_busy), .done(sh_done),
    .dac_sclk(dac_sclk), .dac_sync_n(dac_sync_n), .dac_sdin(dac_sdin)
);

// ---------------------------------------------------- trigger conditioning --
// Select line -> 2-FF sync -> polarity -> minimum-pulse filter (the filtered
// level must be stable for cfg_trig_minpulse clocks before it is believed,
// in both directions -- a glitch reject, not just a debounce).
(* ASYNC_REG = "TRUE" *) reg trig_sync0, trig_sync1;
reg         trig_level;      // filtered, polarity-corrected level
reg         trig_level_d;
reg  [31:0] trig_stable_cnt;
wire        trig_raw = digital_in[cfg_trig_line] ^ cfg_trig_pol;
wire        trig_rise = trig_level & ~trig_level_d;

always @(posedge clk) begin
    if (!rstn) begin
        trig_sync0 <= 1'b0; trig_sync1 <= 1'b0;
        trig_level <= 1'b0; trig_level_d <= 1'b0;
        trig_stable_cnt <= 32'd0;
    end else begin
        trig_sync0 <= trig_raw;
        trig_sync1 <= trig_sync0;
        trig_level_d <= trig_level;
        if (trig_sync1 == trig_level) begin
            trig_stable_cnt <= 32'd0;
        end else if (trig_stable_cnt >= cfg_trig_minpulse) begin
            trig_level <= trig_sync1;
            trig_stable_cnt <= 32'd0;
        end else begin
            trig_stable_cnt <= trig_stable_cnt + 32'd1;
        end
    end
end

// ------------------------------------------------------------- run control --
localparam [2:0] S_IDLE    = 3'd0,
                 S_RUN     = 3'd1,   // between frames, waiting for the tick
                 S_RD      = 3'd2,   // RAM address issued
                 S_RD2     = 3'd3,   // RAM data registering
                 S_DRAIN   = 3'd4,   // stop requested, waiting for shifter
                 S_IDLESEQ = 3'd5;   // emitting idle-state frames

reg [2:0]  state;

// Latched-at-start run configuration
reg        run_continuous;
reg        run_retrig;
reg [ADDR_W-1:0] run_start_index, run_end_index, run_loop_index;
reg [31:0] run_frames_left;      // finite mode countdown
reg [31:0] run_frame_count;      // start-latched reload value; retrigger reloads
                                 // from this, not live cfg (config-frozen contract)
reg [40:0] run_period;           // 350 * k, up to 41 bits at k = 2^32-1
reg [40:0] tick_cnt;

// Stop requests are latched, not sampled: a 1-cycle p_* pulse can land during
// the S_RD/S_RD2 pipeline states where S_RUN's checks would miss it.
reg        stop_pending;
reg        retrig_pending;   // latched hw-retrigger edge (mirrors stop_pending so
                             // an edge in the RD pipeline is never dropped)
reg        stop_codes;       // idle flavour chosen by the stopping command
reg [1:0]  idle_frames_left;
reg        idle_use_codes;       // latched idle flavour for this sequence
reg [23:0] idle_frame_next;
reg [8:0]  idle_gap_cnt;         // MASTER_PERIOD spacing inside the idle seq

wire [40:0] period_calc = MASTER_PERIOD * cfg_rate_k; // quasi-static operand

wire cfg_ok = (cfg_rate_k != 32'd0)
           && (cfg_start_index <= cfg_end_index)
           && (cfg_loop_index  <= cfg_end_index)
           && (cfg_continuous || (cfg_frame_count != 32'd0));
assign cfg_valid = cfg_ok;

// A hardware start is an edge in one-shot mode, or the gate going active.
wire hw_start = cfg_hw_arm && (state == S_IDLE) &&
                ((cfg_trig_mode == 2'd1 && trig_rise) ||
                 (cfg_trig_mode == 2'd2 && trig_level));
wire gate_stop = (cfg_trig_mode == 2'd2) && cfg_hw_arm && !trig_level;
wire start_req = p_start || hw_start;

always @(posedge clk) begin
    if (!rstn) begin
        state <= S_IDLE;
        running <= 1'b0;
        armed <= 1'b0;
        sticky_bad_start <= 1'b0;
        idle_seq_active <= 1'b0;
        current_index <= {ADDR_W{1'b0}};
        completed_count <= 64'd0;
        ts_start <= 64'd0;
        ts_stop <= 64'd0;
        ram_en <= 1'b0;
        ram_addr <= {ADDR_W{1'b0}};
        sh_start <= 1'b0;
        sh_frame <= 24'd0;
        run_continuous <= 1'b0;
        run_retrig <= 1'b0;
        run_start_index <= {ADDR_W{1'b0}};
        run_end_index <= {ADDR_W{1'b0}};
        run_loop_index <= {ADDR_W{1'b0}};
        run_frames_left <= 32'd0;
        run_frame_count <= 32'd0;
        run_period <= 41'd0;
        tick_cnt <= 41'd0;
        stop_pending <= 1'b0;
        retrig_pending <= 1'b0;
        stop_codes <= 1'b0;
        idle_frames_left <= 2'd0;
        idle_use_codes <= 1'b0;
        idle_frame_next <= 24'd0;
        idle_gap_cnt <= 9'd0;
    end else begin
        sh_start <= 1'b0;
        ram_en <= 1'b0;
        armed <= cfg_hw_arm && (cfg_trig_mode != 2'd0) && (state == S_IDLE);

        if (p_clear_sticky)
            sticky_bad_start <= 1'b0;

        if (p_soft_reset) begin
            state <= S_IDLE;
            running <= 1'b0;
            idle_seq_active <= 1'b0;
            stop_pending <= 1'b0;
            retrig_pending <= 1'b0;
        end else begin
            case (state)
            S_IDLE: begin
                running <= 1'b0;
                if (start_req) begin
                    if (cfg_ok) begin
                        run_continuous  <= cfg_continuous;
                        run_retrig      <= cfg_retrig_restart;
                        run_start_index <= cfg_start_index;
                        run_end_index   <= cfg_end_index;
                        run_loop_index  <= cfg_loop_index;
                        run_frames_left <= cfg_frame_count;
                        run_frame_count <= cfg_frame_count;
                        run_period      <= period_calc;
                        current_index   <= cfg_start_index;
                        completed_count <= 64'd0;
                        stop_pending    <= 1'b0;
                        retrig_pending  <= 1'b0;
                        tick_cnt        <= 41'd0;   // first frame issues now
                        running         <= 1'b1;
                        ts_start        <= master_timestamp;
                        state           <= S_RUN;
                    end else begin
                        sticky_bad_start <= 1'b1;
                    end
                end else if (p_zero || p_powerdown || p_dac_soft_reset) begin
                    // Maintenance frames from idle: no run bookkeeping.
                    idle_use_codes   <= p_zero ? cfg_idle_drive_codes : 1'b0;
                    idle_frames_left <= (p_zero && cfg_idle_drive_codes) ? 2'd2 : 2'd1;
                    idle_frame_next  <= p_dac_soft_reset ? FRAME_DAC_RESET :
                                        (p_zero && cfg_idle_drive_codes)
                                          ? {8'h08, cfg_idle_codes[15:0]}
                                          : FRAME_PWDN;
                    // One master period of spacing before the first frame:
                    // a maintenance command can follow another frame closely,
                    // and t_DACWAIT must hold across that seam too.
                    idle_gap_cnt     <= MASTER_PERIOD[8:0];
                    idle_seq_active  <= 1'b1;
                    state            <= S_IDLESEQ;
                end
            end

            S_RUN: begin
                // Retrigger-restart: service a LATCHED edge (retrig_pending, set
                // below after the case just like stop_pending) so an edge that
                // lands in the S_RD/S_RD2 read pipeline is never lost. Rewind to
                // the stimulus start at this frame boundary.
                if (retrig_pending) begin
                    retrig_pending  <= 1'b0;
                    current_index   <= run_start_index;
                    run_frames_left <= run_frame_count;   // start-latched, not live cfg
                    ts_start        <= master_timestamp;
                end
                if (stop_pending || gate_stop) begin
                    idle_use_codes <= stop_pending ? stop_codes : cfg_idle_drive_codes;
                    stop_pending <= 1'b0;
                    state <= S_DRAIN;
                end else if (tick_cnt == 41'd0) begin
                    ram_en   <= 1'b1;
                    ram_addr <= current_index;
                    tick_cnt <= run_period - 41'd1;
                    state    <= S_RD;
                end else begin
                    tick_cnt <= tick_cnt - 41'd1;
                end
            end

            S_RD: state <= S_RD2;   // ram_rdata valid next cycle

            S_RD2: begin
                sh_frame <= ram_rdata[23:0];
                sh_start <= 1'b1;
                completed_count <= completed_count + 64'd1;
                current_index <= (current_index == run_end_index)
                                   ? run_loop_index
                                   : current_index + {{(ADDR_W-1){1'b0}}, 1'b1};
                if (!run_continuous) begin
                    run_frames_left <= run_frames_left - 32'd1;
                    if (run_frames_left == 32'd1) begin
                        idle_use_codes <= cfg_idle_drive_codes;
                        state <= S_DRAIN;
                    end else begin
                        state <= S_RUN;
                    end
                end else begin
                    state <= S_RUN;
                end
                // tick_cnt keeps counting down during S_RD/S_RD2 via the
                // decrement below, preserving the exact 350*k spacing.
            end

            S_DRAIN: begin
                if (!shifter_busy && !sh_start) begin
                    idle_frames_left <= idle_use_codes ? 2'd2 : 2'd1;
                    idle_frame_next  <= idle_use_codes ? {8'h08, cfg_idle_codes[15:0]}
                                                       : FRAME_PWDN;
                    // The stop seam: the last playback frame just finished, so
                    // wait a full master period before the idle frame or the
                    // DAC's 1 us sequential-update floor is violated.
                    idle_gap_cnt     <= MASTER_PERIOD[8:0];
                    idle_seq_active  <= 1'b1;
                    running          <= 1'b0;
                    state            <= S_IDLESEQ;
                end
            end

            S_IDLESEQ: begin
                if (idle_frames_left == 2'd0) begin
                    if (!shifter_busy && !sh_start) begin
                        idle_seq_active <= 1'b0;
                        ts_stop <= master_timestamp;
                        state <= S_IDLE;
                    end
                end else if (idle_gap_cnt != 9'd0) begin
                    idle_gap_cnt <= idle_gap_cnt - 9'd1;
                end else if (!shifter_busy && !sh_start) begin
                    sh_frame <= idle_frame_next;
                    sh_start <= 1'b1;
                    idle_frames_left <= idle_frames_left - 2'd1;
                    idle_frame_next <= {8'h09, cfg_idle_codes[31:16]};
                    idle_gap_cnt <= MASTER_PERIOD[8:0]; // legal inter-frame spacing
                end
            end

            default: state <= S_IDLE;
            endcase

            // Keep the master spacing exact across the RD pipeline states.
            if ((state == S_RD) || (state == S_RD2)) begin
                if (tick_cnt != 41'd0)
                    tick_cnt <= tick_cnt - 41'd1;
            end

            // Latch stop commands whenever a run is in flight (after the case
            // so a capture beats the same-cycle clear in S_RUN).
            if ((state == S_RUN || state == S_RD || state == S_RD2) &&
                (p_stop || p_zero || p_powerdown)) begin
                stop_pending <= 1'b1;
                stop_codes   <= p_powerdown ? 1'b0 : cfg_idle_drive_codes;
            end

            // Same treatment for the hardware retrigger edge: latch it whenever a
            // run is in flight, so an edge landing in the RD pipeline survives to
            // be serviced at the next S_RUN (this set beats the same-cycle clear).
            if ((state == S_RUN || state == S_RD || state == S_RD2) &&
                trig_rise && cfg_hw_arm && cfg_trig_mode == 2'd1 && run_retrig) begin
                retrig_pending <= 1'b1;
            end
        end
    end
end

endmodule
