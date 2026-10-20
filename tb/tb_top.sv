// ============================================================================
// tb_top -- clock/reset, DUT, DRAM model, interfaces, UVM launch, waveforms.
//
// Plusargs
//   +UVM_TESTNAME=<test>   test to run (default ddr_smoke_test)
//   +NUM_TXN=<n>           number of host requests
//   +WAVES[=<file>]        dump a VCD (default waves.vcd)
//   +TRACE                 log every DRAM command
//   +COV_FILE=<file>       write functional coverage JSON
//   +no_sva                disable all assertion checkers (end-to-end only)
//   +verilator+seed+<n>    random seed
// ============================================================================
`timescale 1ns/1ps
`include "uvm_macros.svh"

module tb_top;
  import uvm_pkg::*;
  import ddr_pkg::*;
  import ddr_tb_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;      // 100 MHz command clock: cycle N <-> time N*10ns

  ddr_host_if hif (clk, rst_n);
  ddr_dram_if dif (clk, rst_n);

  ddr_ctrl u_dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .req_valid        (hif.req_valid),
    .req_ready        (hif.req_ready),
    .req_we           (hif.req_we),
    .req_addr         (hif.req_addr),
    .req_wdata        (hif.req_wdata),
    .req_id           (hif.req_id),
    .rd_valid         (hif.rd_valid),
    .rd_id            (hif.rd_id),
    .rd_data          (hif.rd_data),
    .wr_ack_valid     (hif.wr_ack_valid),
    .wr_ack_id        (hif.wr_ack_id),
    .dram_cs_n        (dif.cs_n),
    .dram_ras_n       (dif.ras_n),
    .dram_cas_n       (dif.cas_n),
    .dram_we_n        (dif.we_n),
    .dram_ba          (dif.ba),
    .dram_addr        (dif.addr),
    .dram_wdata_valid (dif.wdata_valid),
    .dram_wdata       (dif.wdata),
    .dram_rdata_valid (dif.rdata_valid),
    .dram_rdata       (dif.rdata),
    .init_done        (hif.init_done)
  );

  ddr_dram_model u_dram (
    .clk         (clk),
    .rst_n       (rst_n),
    .cs_n        (dif.cs_n),
    .ras_n       (dif.ras_n),
    .cas_n       (dif.cas_n),
    .we_n        (dif.we_n),
    .ba          (dif.ba),
    .addr        (dif.addr),
    .wdata_valid (dif.wdata_valid),
    .wdata       (dif.wdata),
    .rdata_valid (dif.rdata_valid),
    .rdata       (dif.rdata)
  );

  ddr_binds u_binds ();

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
  end

  initial begin
    string wf;
    if ($test$plusargs("WAVES")) begin
      if (!$value$plusargs("WAVES=%s", wf)) wf = "waves.vcd";
      $dumpfile(wf);
      $dumpvars(0, tb_top);
    end
  end

  initial begin
    string test;
    uvm_config_db#(virtual ddr_host_if)::set(null, "*", "host_vif", hif);
    uvm_config_db#(virtual ddr_dram_if)::set(null, "*", "dram_vif", dif);
    if (!$value$plusargs("UVM_TESTNAME=%s", test)) test = "ddr_smoke_test";
    run_test(test);
  end

  final $display("[tb_top] %s", u_dram.stats());

endmodule
