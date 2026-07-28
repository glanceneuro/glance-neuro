// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Single-bus I2C presence probe for the BNO055 IMU on a shared headstage lane.
//
// On `start`: first RELEASE both lines (open-drain, external pull-ups) and
// sample their idle levels. Both-high is the IMU signature — a 2 kOhm pull-up
// to 2.5 V on the headstage. If the lines are NOT both high (an LVDS driver on
// a 128-ch headstage idles one-high/one-low; a bare lane floats), the probe
// stops WITHOUT ever driving — this is the safety interlock that prevents open-
// drain contention with an Intan LVDS output. Only when both idle high does it
// drive a slow I2C read of the device's ID register and check the expected
// value.
//
// Open-drain convention: `*_oe = 1` drives the line low; `*_oe = 0` releases it
// (Hi-Z, pulled up externally). The output value is always 0. The IOBUF at the
// top ties I=0 and T = ~oe. Clock stretching is honored: after releasing SCL to
// go high, the FSM waits for `scl_in` to actually read high (bounded by
// STRETCH_TICKS) before sampling — the BNO055 holds SCL low when it needs time.
`timescale 1ns/1ps

module i2c_probe #(
    parameter integer CLK_HZ         = 100_000_000,
    parameter integer I2C_HZ         = 100_000,     // slow: forgiving over cable
    parameter [6:0]   DEV_ADDR       = 7'h28,       // BNO055 (COM3 low)
    parameter [7:0]   PROBE_REG      = 8'h00,       // CHIP_ID
    parameter [7:0]   EXPECT_ID      = 8'hA0,       // BNO055 CHIP_ID
    parameter integer STRETCH_TICKS  = 64,          // quarter-ticks to wait for SCL release
    parameter integer QDIV           = (CLK_HZ / (4*I2C_HZ)) // clk cycles per quarter bit
)(
    input  wire       clk,
    input  wire       rstn,

    input  wire       start,
    output reg        busy,
    output reg        done,

    output reg        present,     // idle-both-high AND addr-ACK AND id==EXPECT_ID
    output reg        ack_ok,      // device ACKed its address (something is there)
    output reg  [7:0] chip_id,     // byte read back from PROBE_REG
    output reg  [1:0] idle_lvl,    // {scl_in, sda_in} sampled before any drive
    output reg        timed_out,   // clock-stretch timeout

    // open-drain drive (1 = pull low, 0 = release/Hi-Z) + sampled line states
    output reg        sda_oe,
    output reg        scl_oe,
    input  wire       sda_in,
    input  wire       scl_in
);

localparam integer QW = (QDIV > 1) ? $clog2(QDIV) : 1;

// quarter-bit tick generator
reg [QW-1:0] qcnt;
reg          qtick;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin qcnt <= 0; qtick <= 1'b0; end
    else if (qcnt == QDIV[QW-1:0]-1'b1) begin qcnt <= 0; qtick <= 1'b1; end
    else begin qcnt <= qcnt + 1'b1; qtick <= 1'b0; end
end

// The transfer is a fixed micro-program of byte ops:
//   0: write DEV_ADDR|W    1: write PROBE_REG    (repeated start)
//   2: write DEV_ADDR|R    3: read byte (master NAK)
localparam [3:0]
    S_IDLE   = 4'd0, S_SENSE = 4'd1, S_START = 4'd2, S_WA = 4'd3, S_WR = 4'd4,
    S_RS1    = 4'd5, S_RS2   = 4'd6, S_AR    = 4'd7, S_RD = 4'd8, S_STOP = 4'd9,
    S_DONE   = 4'd10;

reg [3:0]  state;
reg [1:0]  phase;      // 0: SCL low/set SDA, 1: SCL rising, 2: SCL high/sample, 3: SCL falling
reg [3:0]  bitc;       // bit counter within a byte (8..0)
reg [7:0]  shifter;
reg        got_ack;
reg [15:0] stretch;

// advance one quarter-phase, honoring clock stretching in the high phase
reg        adv;        // 1-cycle: move to next phase this qtick
reg        stall;      // waiting on SCL release

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state <= S_IDLE; phase <= 2'd0; bitc <= 4'd0; shifter <= 8'd0;
        busy <= 1'b0; done <= 1'b0; present <= 1'b0; ack_ok <= 1'b0;
        chip_id <= 8'd0; idle_lvl <= 2'd0; timed_out <= 1'b0;
        sda_oe <= 1'b0; scl_oe <= 1'b0; got_ack <= 1'b0; stretch <= 16'd0;
        adv <= 1'b0; stall <= 1'b0;
    end else begin
        done <= 1'b0;
        adv  <= 1'b0;

        // Clock-stretch gate: in phase 1 we release SCL; only enter phase 2
        // once the line has actually risen (slave not holding it low).
        if (qtick) begin
            if (phase == 2'd1 && scl_oe == 1'b0 && scl_in == 1'b0 && state > S_START) begin
                stall <= 1'b1;
                if (stretch >= STRETCH_TICKS[15:0]) begin
                    timed_out <= 1'b1; adv <= 1'b1; stretch <= 16'd0;
                end else stretch <= stretch + 16'd1;
            end else begin
                adv <= 1'b1; stall <= 1'b0; stretch <= 16'd0;
            end
        end

        case (state)
        S_IDLE: begin
            sda_oe <= 1'b0; scl_oe <= 1'b0;   // released
            if (start) begin
                busy <= 1'b1; present <= 1'b0; ack_ok <= 1'b0; chip_id <= 8'd0;
                timed_out <= 1'b0; phase <= 2'd0; state <= S_SENSE;
            end
        end

        // Sense idle levels with both lines released (Hi-Z). Safe against any
        // headstage. Both-high => candidate IMU; else stop without driving.
        S_SENSE: if (adv) begin
            if (phase == 2'd3) begin
                idle_lvl <= {scl_in, sda_in};
                if (sda_in && scl_in) begin
                    // begin START: SDA high, SCL high already
                    phase <= 2'd0; state <= S_START;
                end else begin
                    present <= 1'b0; state <= S_DONE;   // not an IMU; never drove
                end
            end else phase <= phase + 2'd1;
        end

        // START: with SCL high, pull SDA low.
        S_START: if (adv) begin
            case (phase)
              2'd0: begin scl_oe <= 1'b0; sda_oe <= 1'b0; phase <= 2'd1; end // both high
              2'd1: begin sda_oe <= 1'b1; phase <= 2'd2; end                 // SDA low (START)
              2'd2: begin scl_oe <= 1'b1; phase <= 2'd3; end                 // SCL low
              2'd3: begin bitc <= 4'd8; shifter <= {DEV_ADDR,1'b0}; phase <= 2'd0; state <= S_WA; end
            endcase
        end

        S_WA: byte_write(S_WR, {PROBE_REG});
        S_WR: byte_write(S_RS1, 8'd0);            // after reg addr -> repeated start

        // Repeated START: SDA released high while SCL low, SCL high, SDA low.
        S_RS1: if (adv) begin
            case (phase)
              2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; phase <= 2'd1; end // SCL low, SDA release high
              2'd1: begin scl_oe <= 1'b0; phase <= 2'd2; end                 // SCL high (stretch-gated)
              2'd2: begin sda_oe <= 1'b1; phase <= 2'd3; end                 // SDA low = repeated START
              2'd3: begin scl_oe <= 1'b1; bitc <= 4'd8; shifter <= {DEV_ADDR,1'b1}; phase <= 2'd0; state <= S_AR; end
            endcase
        end
        S_RS2: ; // unused placeholder

        S_AR: byte_write(S_RD, 8'd0);             // after addr|R -> read data byte

        // Read one byte (master releases SDA, samples on SCL high), then NAK.
        S_RD: if (adv) begin
            case (phase)
              2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; phase <= 2'd1; end   // SCL low, release SDA
              2'd1: begin scl_oe <= 1'b0; phase <= 2'd2; end                   // SCL high
              2'd2: begin shifter <= {shifter[6:0], sda_in}; phase <= 2'd3; end// sample bit
              2'd3: begin
                        scl_oe <= 1'b1;
                        if (bitc == 4'd1) begin
                            chip_id <= shifter;                  // all 8 bits assembled
                            bitc <= 4'd0; phase <= 2'd0; state <= S_STOP; // NAK+STOP
                        end else begin bitc <= bitc - 4'd1; phase <= 2'd0; end
                     end
            endcase
        end

        // NAK bit already implied (SDA released during ack slot) + STOP:
        // SCL low, SDA low, SCL high, SDA high.
        S_STOP: if (adv) begin
            case (phase)
              2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; phase <= 2'd1; end // SCL low, SDA low
              2'd1: begin scl_oe <= 1'b0; phase <= 2'd2; end                 // SCL high
              2'd2: begin sda_oe <= 1'b0; phase <= 2'd3; end                 // SDA high = STOP
              2'd3: begin present <= ack_ok && (chip_id == EXPECT_ID); state <= S_DONE; end
            endcase
        end

        S_DONE: begin
            busy <= 1'b0; done <= 1'b1; sda_oe <= 1'b0; scl_oe <= 1'b0;
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end

// One I2C byte write (MSB first) + ACK sample. On completion go to `next`;
// `nextshift` preloads the shifter for the following byte-write op.
task byte_write(input [3:0] next, input [7:0] nextshift);
    if (adv) begin
        case (phase)
          2'd0: begin                                   // SCL low: drive SDA = current bit
                    if (bitc != 4'd0) sda_oe <= ~shifter[7]; // OE=1 drives low, so ~bit
                    else              sda_oe <= 1'b0;        // ack slot: release SDA
                    scl_oe <= 1'b1; phase <= 2'd1;
                 end
          2'd1: begin scl_oe <= 1'b0; phase <= 2'd2; end  // SCL high (stretch-gated)
          2'd2: begin                                      // sample (ack bit only)
                    if (bitc == 4'd0) got_ack <= ~sda_in;   // ACK = SDA low
                    phase <= 2'd3;
                 end
          2'd3: begin
                    scl_oe <= 1'b1;                          // SCL low
                    if (bitc == 4'd0) begin
                        ack_ok <= ack_ok | got_ack;          // sticky across the addr byte
                        bitc <= 4'd8; shifter <= nextshift; phase <= 2'd0; state <= next;
                    end else begin
                        shifter <= {shifter[6:0],1'b0}; bitc <= bitc - 4'd1; phase <= 2'd0;
                    end
                 end
        endcase
    end
endtask

endmodule
