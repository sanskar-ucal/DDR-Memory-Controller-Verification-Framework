`include "uvm_macros.svh"

package ddr_tb_pkg;
  import uvm_pkg::*;
  import ddr_pkg::*;

  `include "ddr_items.svh"
  `include "ddr_agent.svh"
  `include "ddr_scoreboard.svh"
  `include "ddr_coverage.svh"
  `include "ddr_env.svh"
  `include "ddr_seq_lib.svh"
  `include "ddr_tests.svh"
endpackage
