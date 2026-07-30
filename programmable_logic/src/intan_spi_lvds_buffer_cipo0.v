// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University

// CIPO0-only LVDS buffer -- a variant of intan_spi_lvds_buffer for the
// IMU-acquisition fabrics (acq_imu_*). It drives sclk/csn/copi and receives
// CIPO0 over LVDS exactly like the full buffer, but OMITS the CIPO1 pair. That
// frees the second-CIPO pins (port A M19/M20, port B K16/J16) so an AXI IIC can
// drive them single-ended for a BNO055 IMU on that cable -- a 64-ch-per-port
// configuration. CIPO1 is tied low, so the data path's channels 65..128 for
// this cable read as zeros (the SPI transaction is unchanged; only the second
// return lane is absent).
//
// The single-ended `intan_spi` interface is kept identical to the full buffer
// so data_generator connects unchanged; only the differential `spi_lvds` side
// is reduced, and it is exposed as plain ports (no intan_spi_diff interface) so
// the block design's external pins carry no CIPO1 pair to place.

module intan_spi_lvds_buffer_cipo0 (
    // Input: single-ended Intan SPI interface (unchanged from the full buffer)
    (* X_INTERFACE_INFO = "kemerelab.org:intan:intan_spi:1.0 intan_spi sclk" *)
    input wire sclk,

    (* X_INTERFACE_INFO = "kemerelab.org:intan:intan_spi:1.0 intan_spi csn" *)
    input wire csn,

    (* X_INTERFACE_INFO = "kemerelab.org:intan:intan_spi:1.0 intan_spi copi" *)
    input wire copi,

    (* X_INTERFACE_INFO = "kemerelab.org:intan:intan_spi:1.0 intan_spi cipo0" *)
    output wire cipo0,

    (* X_INTERFACE_INFO = "kemerelab.org:intan:intan_spi:1.0 intan_spi cipo1" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF intan_spi" *)
    output wire cipo1,

    // Output: differential LVDS -- plain ports, CIPO0 only (no CIPO1 pair)
    output wire spi_sclk_p,
    output wire spi_sclk_n,
    output wire spi_csn_p,
    output wire spi_csn_n,
    output wire spi_copi_p,
    output wire spi_copi_n,
    input  wire spi_cipo0_p,
    input  wire spi_cipo0_n
);

    // No second return lane on this fabric: channels 65..128 for this cable read
    // as zeros through the normal data path.
    assign cipo1 = 1'b0;

    (* IOB = "TRUE" *)
    (* IOSTANDARD = "LVDS_25" *)
    OBUFDS #(
        .IOSTANDARD("LVDS_25"),
        .SLEW("FAST")
    ) obufds_sclk (
        .O(spi_sclk_p),
        .OB(spi_sclk_n),
        .I(sclk)
    );

    (* IOB = "TRUE" *)
    (* IOSTANDARD = "LVDS_25" *)
    OBUFDS #(
        .IOSTANDARD("LVDS_25"),
        .SLEW("FAST")
    ) obufds_csn (
        .O(spi_csn_p),
        .OB(spi_csn_n),
        .I(csn)
    );

    (* IOB = "TRUE" *)
    (* IOSTANDARD = "LVDS_25" *)
    OBUFDS #(
        .IOSTANDARD("LVDS_25"),
        .SLEW("FAST")
    ) obufds_copi (
        .O(spi_copi_p),
        .OB(spi_copi_n),
        .I(copi)
    );

    (* IOB = "TRUE" *)
    (* IOSTANDARD = "LVDS_25" *)
    IBUFDS #(
        .IOSTANDARD("LVDS_25"),
        .DIFF_TERM("TRUE")
    ) ibufds_cipo0 (
        .O(cipo0),
        .I(spi_cipo0_p),
        .IB(spi_cipo0_n)
    );

endmodule
