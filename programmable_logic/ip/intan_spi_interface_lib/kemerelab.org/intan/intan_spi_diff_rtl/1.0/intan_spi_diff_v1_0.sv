// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Custom Vivado interface definition for the Intan SPI bus (VLNV kemerelab.org:intan:*).
// Emitted by Vivado's interface packager; its generic AMD template header has been
// replaced with this project's own license (the interface definition is first-party).


`ifndef intan_spi_diff_v1_0
`define intan_spi_diff_v1_0

package parameter_structs;

  typedef struct packed {
      bit    portEnabled;
      integer    portWidth;
  }portConfig;

  typedef struct packed {
    // <typeName> <LogicalName> = {<enablement>, <width>}
    portConfig sclk_p;
    portConfig sclk_n;
    portConfig csn_p;
    portConfig csn_n;
    portConfig copi_p;
    portConfig copi_n;
    portConfig cipo0_p;
    portConfig cipo0_n;
    portConfig cipo1_p;
    portConfig cipo1_n;
  }intan_spi_diff_v1_0_port_configuration;

  parameter intan_spi_diff_v1_0_port_configuration intan_spi_diff_v1_0_default_port_configuration = '{sclk_p:'{1, -1}, sclk_n:'{1, -1}, csn_p:'{1, -1}, csn_n:'{1, -1}, copi_p:'{1, -1}, copi_n:'{1, -1}, cipo0_p:'{1, -1}, cipo0_n:'{1, -1}, cipo1_p:'{1, -1}, cipo1_n:'{1, -1}};

endpackage

interface intan_spi_diff_v1_0 #(parameter_structs::intan_spi_diff_v1_0_port_configuration port_configuration)();
  logic [port_configuration.sclk_p.portWidth-1:0] sclk_p;              // 
  logic [port_configuration.sclk_n.portWidth-1:0] sclk_n;              // 
  logic [port_configuration.csn_p.portWidth-1:0] csn_p;                // 
  logic [port_configuration.csn_n.portWidth-1:0] csn_n;                // 
  logic [port_configuration.copi_p.portWidth-1:0] copi_p;              // 
  logic [port_configuration.copi_n.portWidth-1:0] copi_n;              // 
  logic [port_configuration.cipo0_p.portWidth-1:0] cipo0_p;            // 
  logic [port_configuration.cipo0_n.portWidth-1:0] cipo0_n;            // 
  logic [port_configuration.cipo1_p.portWidth-1:0] cipo1_p;            // 
  logic [port_configuration.cipo1_n.portWidth-1:0] cipo1_n;            // 

  modport MASTER (
    input cipo0_p, cipo0_n, cipo1_p, cipo1_n, 
    output sclk_p, sclk_n, csn_p, csn_n, copi_p, copi_n
    );

  modport SLAVE (
    input sclk_p, sclk_n, csn_p, csn_n, copi_p, copi_n, 
    output cipo0_p, cipo0_n, cipo1_p, cipo1_n
    );

  modport MONITOR (
    input sclk_p, sclk_n, csn_p, csn_n, copi_p, copi_n, cipo0_p, cipo0_n, cipo1_p, cipo1_n
    );

endinterface // intan_spi_diff_v1_0

`endif