// ============================================================================
// Testbench interfaces. Each carries a cycle counter (cycles since reset
// release) so that every component reports events on the same timebase.
// ============================================================================

interface ddr_host_if (input logic clk, input logic rst_n);
  import ddr_pkg::*;

  logic              req_valid;
  logic              req_ready;
  logic              req_we;
  logic [ADDR_W-1:0] req_addr;
  logic [DQ_W-1:0]   req_wdata;
  logic [ID_W-1:0]   req_id;

  logic              rd_valid;
  logic [ID_W-1:0]   rd_id;
  logic [DQ_W-1:0]   rd_data;

  logic              wr_ack_valid;
  logic [ID_W-1:0]   wr_ack_id;

  logic              init_done;

  longint unsigned   cycle;
  realtime           cycle_t;      // time of the last counter update
  always @(posedge clk or negedge rst_n)
    if (!rst_n) cycle <= 0;
    else begin
      cycle   <= cycle + 1;
      cycle_t <= $realtime;
    end

  // Label of the bus cycle whose sampled values are being processed now:
  // checkers that run after the edge's updates (SVA action blocks) see the
  // incremented counter, monitors that run before them do not.
  function automatic longint unsigned sampled_cycle();
    return (cycle_t == $realtime && cycle > 0) ? cycle - 1 : cycle;
  endfunction
endinterface


interface ddr_dram_if (input logic clk, input logic rst_n);
  import ddr_pkg::*;

  logic              cs_n;
  logic              ras_n;
  logic              cas_n;
  logic              we_n;
  logic [BA_W-1:0]   ba;
  logic [DA_W-1:0]   addr;
  logic              wdata_valid;
  logic [DQ_W-1:0]   wdata;
  logic              rdata_valid;
  logic [DQ_W-1:0]   rdata;

  longint unsigned   cycle;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) cycle <= 0;
    else        cycle <= cycle + 1;
endinterface
