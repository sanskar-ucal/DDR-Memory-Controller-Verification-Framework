// ============================================================================
// ddr_host_sva -- host-interface protocol checker.
//
//  * Request channel obeys valid/ready: once valid is raised it stays high
//    with a stable payload until accepted (contract on the requester).
//  * Every response refers to an outstanding request of the matching type,
//    and IDs are never reused while outstanding (contract on both sides).
// ============================================================================
`include "uvm_macros.svh"

module ddr_host_sva
  import uvm_pkg::*;
  import ddr_pkg::*;
(
  input logic              clk,
  input logic              rst_n,
  input logic              req_valid,
  input logic              req_ready,
  input logic              req_we,
  input logic [ADDR_W-1:0] req_addr,
  input logic [DQ_W-1:0]   req_wdata,
  input logic [ID_W-1:0]   req_id,
  input logic              rd_valid,
  input logic [ID_W-1:0]   rd_id,
  input logic              wr_ack_valid,
  input logic [ID_W-1:0]   wr_ack_id
);

  bit en = 1'b1;
  initial if ($test$plusargs("no_sva")) en = 1'b0;

  logic accept;
  assign accept = req_valid && req_ready;

  // Outstanding-ID tracking
  logic [(1<<ID_W)-1:0] out_rd, out_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_rd <= '0;
      out_wr <= '0;
    end else begin
      if (rd_valid)     out_rd[rd_id]     <= 1'b0;
      if (wr_ack_valid) out_wr[wr_ack_id] <= 1'b0;
      if (accept && !req_we) out_rd[req_id] <= 1'b1;
      if (accept &&  req_we) out_wr[req_id] <= 1'b1;
    end
  end

  a_req_hold: assert property (@(posedge clk) disable iff (!rst_n || !en)
    (req_valid && !req_ready) |=> req_valid)
    else `uvm_error("SVA_HOST_REQ", "req_valid dropped before the request was accepted")

  a_req_stable: assert property (@(posedge clk) disable iff (!rst_n || !en)
    (req_valid && !req_ready) |=> $stable({req_we, req_addr, req_wdata, req_id}))
    else `uvm_error("SVA_HOST_REQ", "request payload changed while waiting for req_ready")

  a_id_unique: assert property (@(posedge clk) disable iff (!rst_n || !en)
    accept |-> !(out_rd[req_id] || out_wr[req_id]))
    else `uvm_error("SVA_HOST_ID", $sformatf("request id %0d reused while still outstanding", req_id))

  a_rd_rsp_known: assert property (@(posedge clk) disable iff (!rst_n || !en)
    rd_valid |-> out_rd[rd_id])
    else `uvm_error("SVA_HOST_RSP", $sformatf("read response for id %0d which has no outstanding read", rd_id))

  a_wr_ack_known: assert property (@(posedge clk) disable iff (!rst_n || !en)
    wr_ack_valid |-> out_wr[wr_ack_id])
    else `uvm_error("SVA_HOST_RSP", $sformatf("write ack for id %0d which has no outstanding write", wr_ack_id))

endmodule
