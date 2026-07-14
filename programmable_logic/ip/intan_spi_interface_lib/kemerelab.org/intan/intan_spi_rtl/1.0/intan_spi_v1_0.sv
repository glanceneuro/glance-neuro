// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Custom Vivado interface definition for the Intan SPI bus (VLNV kemerelab.org:intan:*).
// Emitted by Vivado's interface packager; its generic AMD template header has been
// replaced with this project's own license (the interface definition is first-party).


`ifndef intan_spi_v1_0
`define intan_spi_v1_0

package parameter_structs;

  typedef struct packed {
      bit    portEnabled;
      integer    portWidth;
  }portConfig;

  typedef struct packed {
    // <typeName> <LogicalName> = {<enablement>, <width>}
    portConfig sclk;
    portConfig csn;
    portConfig copi;
    portConfig cipo0;
    portConfig cipo1;
  }intan_spi_v1_0_port_configuration;

  parameter intan_spi_v1_0_port_configuration intan_spi_v1_0_default_port_configuration = '{sclk:'{1, -1}, csn:'{1, -1}, copi:'{1, -1}, cipo0:'{1, -1}, cipo1:'{1, -1}};

endpackage

interface intan_spi_v1_0 #(parameter_structs::intan_spi_v1_0_port_configuration port_configuration)();
  logic [port_configuration.sclk.portWidth-1:0] sclk;              // 
  logic [port_configuration.csn.portWidth-1:0] csn;                // 
  logic [port_configuration.copi.portWidth-1:0] copi;              // 
  logic [port_configuration.cipo0.portWidth-1:0] cipo0;            // 
  logic [port_configuration.cipo1.portWidth-1:0] cipo1;            // 

  modport MASTER (
    input cipo0, cipo1, 
    output sclk, csn, copi
    );

  modport SLAVE (
    input sclk, csn, copi, 
    output cipo0, cipo1
    );

  modport MONITOR (
    input sclk, csn, copi, cipo0, cipo1
    );

endinterface // intan_spi_v1_0

`endif