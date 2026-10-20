// ============================================================================
// ddr_ctrl_internal_sva -- white-box assertions bound inside ddr_ctrl.
//
// Checks the controller's own state machines and bookkeeping: legal FSM
// transitions, commands only from legal states, refresh ticks never lost,
// request-queue integrity and the FR-FCFS starvation bound.
// ============================================================================
`include "uvm_macros.svh"

module ddr_ctrl_internal_sva
  import uvm_pkg::*;
  import ddr_pkg::*;
#(
  parameter int REFI_W = $clog2(T_REFI)
)(
  input logic              clk,
  input logic              rst_n,
  input bank_state_e       bank_state [NUM_BANKS],
  input ref_state_e        ref_state,
  input init_state_e       init_state,
  input logic [QCNT_W-1:0] q_cnt      [NUM_BANKS],
  input qentry_t           q          [NUM_BANKS][QDEPTH],
  input logic [2:0]        bypass_cnt [NUM_BANKS],
  input logic [REFI_W-1:0] refi_cnt,
  input dram_cmd_e         iss_cmd,
  input logic [BA_W-1:0]   iss_ba,
  input logic              push,
  input logic [BA_W-1:0]   req_ba,
  input logic [ID_W-1:0]   req_id,
  input logic              req_ready,
  input logic              rd_strobe_miss
);

  bit en = 1'b1;
  initial if ($test$plusargs("no_sva")) en = 1'b0;

  logic iss_traffic;
  assign iss_traffic = iss_cmd inside {CMD_ACT, CMD_RD, CMD_WR};

  // Raw refresh tick (before any gating in the controller)
  logic refi_tick;
  assign refi_tick = (init_state == I_DONE) && (refi_cnt == REFI_W'(T_REFI - 1));

  for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
    // ---------------- bank FSM transitions
    a_bank_from_idle: assert property (@(posedge clk) disable iff (!rst_n || !en)
      bank_state[b] == B_IDLE |=> bank_state[b] inside {B_IDLE, B_ACTIVATING})
      else `uvm_error("SVA_BANK_FSM", $sformatf("bank %0d illegal transition IDLE -> %s",
                      b, bank_state[b].name()))

    a_bank_from_activating: assert property (@(posedge clk) disable iff (!rst_n || !en)
      bank_state[b] == B_ACTIVATING |=> bank_state[b] inside {B_ACTIVATING, B_ACTIVE})
      else `uvm_error("SVA_BANK_FSM", $sformatf("bank %0d illegal transition ACTIVATING -> %s",
                      b, bank_state[b].name()))

    a_bank_from_active: assert property (@(posedge clk) disable iff (!rst_n || !en)
      bank_state[b] == B_ACTIVE |=> bank_state[b] inside {B_ACTIVE, B_PRECHARGING})
      else `uvm_error("SVA_BANK_FSM", $sformatf("bank %0d illegal transition ACTIVE -> %s (row closed without PRE)",
                      b, bank_state[b].name()))

    a_bank_from_precharging: assert property (@(posedge clk) disable iff (!rst_n || !en)
      bank_state[b] == B_PRECHARGING |=> bank_state[b] inside {B_PRECHARGING, B_IDLE})
      else `uvm_error("SVA_BANK_FSM", $sformatf("bank %0d illegal transition PRECHARGING -> %s",
                      b, bank_state[b].name()))

    // ---------------- commands only from legal bank states
    a_act_from_idle: assert property (@(posedge clk) disable iff (!rst_n || !en)
      (iss_cmd == CMD_ACT && iss_ba == BA_W'(b)) |-> bank_state[b] == B_IDLE)
      else `uvm_error("SVA_BANK_CMD", $sformatf("ACT scheduled for bank %0d in state %s",
                      b, bank_state[b].name()))

    a_cas_from_active: assert property (@(posedge clk) disable iff (!rst_n || !en)
      (iss_cmd inside {CMD_RD, CMD_WR} && iss_ba == BA_W'(b)) |-> bank_state[b] == B_ACTIVE)
      else `uvm_error("SVA_BANK_CMD", $sformatf("column command scheduled for bank %0d in state %s",
                      b, bank_state[b].name()))

    // ---------------- queues
    a_qcnt_bound: assert property (@(posedge clk) disable iff (!rst_n || !en)
      q_cnt[b] <= QCNT_W'(QDEPTH))
      else `uvm_error("SVA_QUEUE", $sformatf("bank %0d queue count %0d exceeds depth", b, q_cnt[b]))

    a_push_lands_at_tail: assert property (@(posedge clk) disable iff (!rst_n || !en)
      (push && req_ba == BA_W'(b)) |=> (q_cnt[b] != '0 &&
                                         q[b][q_cnt[b] - 1'b1].id == $past(req_id)))
      else `uvm_error("SVA_QUEUE", $sformatf("bank %0d: accepted request id %0d is not at the queue tail",
                      b, $past(req_id)))

    a_bypass_bound: assert property (@(posedge clk) disable iff (!rst_n || !en)
      bypass_cnt[b] <= 3'(MAX_BYPASS))
      else `uvm_error("SVA_STARVE", $sformatf("bank %0d oldest request bypassed %0d times (limit %0d)",
                      b, bypass_cnt[b], MAX_BYPASS))
  end

  // ---------------- refresh FSM
  a_ref_from_idle: assert property (@(posedge clk) disable iff (!rst_n || !en)
    ref_state == R_IDLE |=> ref_state inside {R_IDLE, R_DRAIN})
    else `uvm_error("SVA_REF_FSM", $sformatf("illegal refresh transition IDLE -> %s", ref_state.name()))

  a_ref_from_drain: assert property (@(posedge clk) disable iff (!rst_n || !en)
    ref_state == R_DRAIN |=> ref_state inside {R_DRAIN, R_PREA_WAIT, R_REFRESH})
    else `uvm_error("SVA_REF_FSM", $sformatf("illegal refresh transition DRAIN -> %s", ref_state.name()))

  a_ref_from_prea_wait: assert property (@(posedge clk) disable iff (!rst_n || !en)
    ref_state == R_PREA_WAIT |=> ref_state inside {R_PREA_WAIT, R_REFRESH})
    else `uvm_error("SVA_REF_FSM", $sformatf("illegal refresh transition PREA_WAIT -> %s", ref_state.name()))

  a_ref_from_refresh: assert property (@(posedge clk) disable iff (!rst_n || !en)
    ref_state == R_REFRESH |=> ref_state inside {R_REFRESH, R_IDLE})
    else `uvm_error("SVA_REF_FSM", $sformatf("illegal refresh transition REFRESH -> %s", ref_state.name()))

  a_ref_tick_taken: assert property (@(posedge clk) disable iff (!rst_n || !en)
    refi_tick |=> ref_state == R_DRAIN)
    else `uvm_error("SVA_REF_LOST", "refresh interval elapsed but the refresh FSM did not start a refresh")

  a_no_traffic_in_refresh: assert property (@(posedge clk) disable iff (!rst_n || !en)
    ref_state != R_IDLE |-> !iss_traffic)
    else `uvm_error("SVA_REF_FSM", $sformatf("%s scheduled while refresh FSM in %s",
                    iss_cmd.name(), ref_state.name()))

  // ---------------- init FSM
  a_init_from_wait: assert property (@(posedge clk) disable iff (!rst_n || !en)
    init_state == I_WAIT |=> init_state inside {I_WAIT, I_MRD})
    else `uvm_error("SVA_INIT_FSM", $sformatf("illegal init transition WAIT -> %s", init_state.name()))

  a_init_from_mrd: assert property (@(posedge clk) disable iff (!rst_n || !en)
    init_state == I_MRD |=> init_state inside {I_MRD, I_DONE})
    else `uvm_error("SVA_INIT_FSM", $sformatf("illegal init transition MRD -> %s", init_state.name()))

  a_init_sticky: assert property (@(posedge clk) disable iff (!rst_n || !en)
    init_state == I_DONE |=> init_state == I_DONE)
    else `uvm_error("SVA_INIT_FSM", "controller left the initialized state")

  a_no_ready_before_init: assert property (@(posedge clk) disable iff (!rst_n || !en)
    init_state != I_DONE |-> !req_ready)
    else `uvm_error("SVA_INIT_FSM", "request accepted before initialization completed")

  // ---------------- read capture
  a_rd_capture: assert property (@(posedge clk) disable iff (!rst_n || !en)
    !rd_strobe_miss)
    else `uvm_error("SVA_RD_CAPTURE", "controller captured read data in a cycle with no DRAM read data")

endmodule
