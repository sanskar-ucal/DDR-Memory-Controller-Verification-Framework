// ============================================================================
// ddr_protocol_sva -- black-box DRAM command-bus protocol and timing checker.
//
// Bound to the controller's DRAM-side pins. It re-derives bank state and
// "cycles since last <event>" counters from the bus alone (independent of the
// controller's own timers) and checks every JEDEC-style rule the controller
// must honour. Failures are reported as UVM_ERROR with ID "SVA_<rule>".
//
// Counter convention: in the cycle a command is on the bus, s_x == number of
// cycles since the most recent x (1 == previous cycle). Saturates at SAT.
// ============================================================================
`include "uvm_macros.svh"

module ddr_protocol_sva
  import uvm_pkg::*;
  import ddr_pkg::*;
(
  input logic              clk,
  input logic              rst_n,
  input logic              dram_cs_n,
  input logic              dram_ras_n,
  input logic              dram_cas_n,
  input logic              dram_we_n,
  input logic [BA_W-1:0]   dram_ba,
  input logic [DA_W-1:0]   dram_addr,
  input logic              dram_wdata_valid,
  input logic              dram_rdata_valid
);

  localparam int unsigned SAT = 32'h00FF_FFFF;
  localparam int unsigned REFI_LIMIT = T_REFI + T_REF_SLACK;

  bit en = 1'b1;
  initial if ($test$plusargs("no_sva")) en = 1'b0;

  logic [3:0] cmd;
  assign cmd = {dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n};

  logic c_any, c_act, c_rd, c_wr, c_cas, c_pre, c_prea, c_ref, c_mrs;
  assign c_any  = is_active_cmd(cmd);
  assign c_act  = (cmd == CMD_ACT);
  assign c_rd   = (cmd == CMD_RD);
  assign c_wr   = (cmd == CMD_WR);
  assign c_cas  = c_rd || c_wr;
  assign c_pre  = (cmd == CMD_PRE) && !dram_addr[A10];
  assign c_prea = (cmd == CMD_PRE) &&  dram_addr[A10];
  assign c_ref  = (cmd == CMD_REF);
  assign c_mrs  = (cmd == CMD_MRS);

  // --------------------------------------------------------------------------
  // Auxiliary model: bank state + elapsed-cycle counters
  // --------------------------------------------------------------------------
  int unsigned s_act [NUM_BANKS], s_pre [NUM_BANKS], s_rd [NUM_BANKS], s_wr [NUM_BANKS];
  int unsigned s_any_act, s_cas, s_any_rd, s_any_wr, s_mrs;
  int unsigned s_ref;      // refresh interval (restarted by REF, or by MRS at init)
  int unsigned s_refcmd;   // since last REF command (tRFC)
  logic [NUM_BANKS-1:0] open;
  logic [NUM_BANKS-1:0] pre_hit;     // this cycle's PRE/PREA closes bank b
  logic                 mrs_done;

  function automatic int unsigned inc(int unsigned v);
    return (v >= SAT) ? SAT : v + 1;
  endfunction

  always_comb
    for (int b = 0; b < NUM_BANKS; b++)
      pre_hit[b] = open[b] && (c_prea || (c_pre && dram_ba == BA_W'(b)));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < NUM_BANKS; b++) begin
        s_act[b] <= SAT; s_pre[b] <= SAT; s_rd[b] <= SAT; s_wr[b] <= SAT;
      end
      s_any_act <= SAT; s_cas <= SAT; s_any_rd <= SAT; s_any_wr <= SAT;
      s_ref     <= 0;   s_mrs <= SAT; s_refcmd <= SAT;
      open      <= '0;
      mrs_done  <= 1'b0;
    end else begin
      for (int b = 0; b < NUM_BANKS; b++) begin
        logic hit;
        hit = (dram_ba == BA_W'(b));
        s_act[b] <= (c_act && hit) ? 1 : inc(s_act[b]);
        s_pre[b] <= pre_hit[b]     ? 1 : inc(s_pre[b]);
        s_rd[b]  <= (c_rd && hit)  ? 1 : inc(s_rd[b]);
        s_wr[b]  <= (c_wr && hit)  ? 1 : inc(s_wr[b]);
        if (c_act && hit)        open[b] <= 1'b1;
        else if (pre_hit[b])     open[b] <= 1'b0;
        else if (c_ref)          open[b] <= 1'b0;
      end
      s_any_act <= c_act ? 1 : inc(s_any_act);
      s_cas     <= c_cas ? 1 : inc(s_cas);
      s_any_rd  <= c_rd  ? 1 : inc(s_any_rd);
      s_any_wr  <= c_wr  ? 1 : inc(s_any_wr);
      s_ref     <= (c_ref || c_mrs) ? 1 : inc(s_ref);
      s_mrs     <= c_mrs ? 1 : inc(s_mrs);
      s_refcmd  <= c_ref ? 1 : inc(s_refcmd);
      if (c_mrs) mrs_done <= 1'b1;
    end
  end

  // --------------------------------------------------------------------------
  // Per-bank rules
  // --------------------------------------------------------------------------
  for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
    logic act_b, cas_b;
    assign act_b = c_act && dram_ba == BA_W'(b);
    assign cas_b = c_cas && dram_ba == BA_W'(b);

    // Illegal command sequences
    a_act_open_bank: assert property (@(posedge clk) disable iff (!rst_n || !en)
      act_b |-> !open[b])
      else `uvm_error("SVA_ACT_OPEN", $sformatf("ACT to bank %0d which already has an open row", b))

    a_cas_closed_bank: assert property (@(posedge clk) disable iff (!rst_n || !en)
      cas_b |-> open[b])
      else `uvm_error("SVA_CAS_CLOSED", $sformatf("%s to bank %0d with no open row",
                                                  c_rd ? "RD" : "WR", b))

    // Timing
    a_trcd: assert property (@(posedge clk) disable iff (!rst_n || !en)
      cas_b |-> s_act[b] >= T_RCD)
      else `uvm_error("SVA_TRCD", $sformatf("bank %0d %s %0d cycles after ACT (tRCD=%0d): premature column access",
                      b, $sampled(c_rd) ? "RD" : "WR", $sampled(s_act[b]), T_RCD))

    a_trp: assert property (@(posedge clk) disable iff (!rst_n || !en)
      act_b |-> s_pre[b] >= T_RP)
      else `uvm_error("SVA_TRP", $sformatf("bank %0d ACT %0d cycles after PRE (tRP=%0d)",
                      b, $sampled(s_pre[b]), T_RP))

    a_trc: assert property (@(posedge clk) disable iff (!rst_n || !en)
      act_b |-> s_act[b] >= T_RC)
      else `uvm_error("SVA_TRC", $sformatf("bank %0d ACT %0d cycles after previous ACT (tRC=%0d)",
                      b, $sampled(s_act[b]), T_RC))

    a_tras: assert property (@(posedge clk) disable iff (!rst_n || !en)
      pre_hit[b] |-> s_act[b] >= T_RAS)
      else `uvm_error("SVA_TRAS", $sformatf("bank %0d precharged %0d cycles after ACT (tRAS=%0d)",
                      b, $sampled(s_act[b]), T_RAS))

    a_trtp: assert property (@(posedge clk) disable iff (!rst_n || !en)
      pre_hit[b] |-> s_rd[b] >= T_RTP)
      else `uvm_error("SVA_TRTP", $sformatf("bank %0d precharged %0d cycles after RD (tRTP=%0d)",
                      b, $sampled(s_rd[b]), T_RTP))

    a_twr: assert property (@(posedge clk) disable iff (!rst_n || !en)
      pre_hit[b] |-> s_wr[b] >= T_WR2PRE)
      else `uvm_error("SVA_TWR", $sformatf("bank %0d precharged %0d cycles after WR (write recovery=%0d)",
                      b, $sampled(s_wr[b]), T_WR2PRE))
  end

  // --------------------------------------------------------------------------
  // Cross-bank rules
  // --------------------------------------------------------------------------
  a_trrd: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_act |-> s_any_act >= T_RRD)
    else `uvm_error("SVA_TRRD", $sformatf("ACT %0d cycles after previous ACT (tRRD=%0d)",
                    $sampled(s_any_act), T_RRD))

  a_tccd: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_cas |-> s_cas >= T_CCD)
    else `uvm_error("SVA_TCCD", $sformatf("CAS %0d cycles after previous CAS (tCCD=%0d)",
                    $sampled(s_cas), T_CCD))

  a_twtr: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_rd |-> s_any_wr >= T_WR2RD)
    else `uvm_error("SVA_TWTR", $sformatf("RD %0d cycles after WR (CWL+1+tWTR=%0d)",
                    $sampled(s_any_wr), T_WR2RD))

  a_trtw: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_wr |-> s_any_rd >= T_RD2WR)
    else `uvm_error("SVA_TRTW", $sformatf("WR %0d cycles after RD (read-to-write turnaround=%0d)",
                    $sampled(s_any_rd), T_RD2WR))

  // --------------------------------------------------------------------------
  // Refresh rules
  // --------------------------------------------------------------------------
  a_trfc: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_any |-> s_refcmd >= T_RFC)
    else `uvm_error("SVA_TRFC", $sformatf("%s %0d cycles after REF (tRFC=%0d)",
                    cmd_name($sampled(cmd), $sampled(dram_addr[A10])), $sampled(s_refcmd), T_RFC))

  a_ref_banks_closed: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_ref |-> open == '0)
    else `uvm_error("SVA_REF_OPEN", $sformatf("REF while banks 0b%b are open", $sampled(open)))

  a_ref_trp: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_ref |-> (s_pre[0] >= T_RP && s_pre[1] >= T_RP && s_pre[2] >= T_RP && s_pre[3] >= T_RP))
    else `uvm_error("SVA_REF_TRP", "REF issued before tRP elapsed after precharge")

  // Every refresh interval must be <= tREFI + drain slack. Fires once, on the
  // cycle the limit is crossed.
  a_trefi: assert property (@(posedge clk) disable iff (!rst_n || !en)
    mrs_done |-> s_ref != REFI_LIMIT + 1)
    else `uvm_error("SVA_TREFI", $sformatf("no REF for more than %0d cycles (tREFI=%0d + slack %0d): refresh starvation",
                    REFI_LIMIT, T_REFI, T_REF_SLACK))

  // --------------------------------------------------------------------------
  // Initialization
  // --------------------------------------------------------------------------
  a_mrs_first: assert property (@(posedge clk) disable iff (!rst_n || !en)
    (c_any && !mrs_done) |-> c_mrs)
    else `uvm_error("SVA_INIT", $sformatf("%s before MRS", cmd_name($sampled(cmd))))

  a_mrs_once: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_mrs |-> !mrs_done)
    else `uvm_error("SVA_INIT", "MRS issued after initialization")

  a_mrs_value: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_mrs |-> dram_addr == mrs_value(CL, CWL))
    else `uvm_error("SVA_MRS", $sformatf("MRS value 0x%0h, expected 0x%0h",
                    $sampled(dram_addr), mrs_value(CL, CWL)))

  a_tmrd: assert property (@(posedge clk) disable iff (!rst_n || !en)
    (c_any && mrs_done) |-> s_mrs >= T_MRD)
    else `uvm_error("SVA_TMRD", $sformatf("%s %0d cycles after MRS (tMRD=%0d)",
                    cmd_name($sampled(cmd)), $sampled(s_mrs), T_MRD))

  // --------------------------------------------------------------------------
  // Data bus
  // --------------------------------------------------------------------------
  a_wdata_latency: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_wr |-> ##CWL dram_wdata_valid)
    else `uvm_error("SVA_WDATA", $sformatf("write data not driven CWL=%0d cycles after WR", CWL))

  a_wdata_orphan: assert property (@(posedge clk) disable iff (!rst_n || !en)
    dram_wdata_valid |-> $past(c_wr, CWL))
    else `uvm_error("SVA_WDATA", "write data driven without a WR command CWL cycles earlier")

  a_rdata_latency: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_rd |-> ##CL dram_rdata_valid)
    else `uvm_error("SVA_RDATA", $sformatf("DRAM did not return read data CL=%0d cycles after RD", CL))

  a_dq_contention: assert property (@(posedge clk) disable iff (!rst_n || !en)
    !(dram_wdata_valid && dram_rdata_valid))
    else `uvm_error("SVA_DQ", "read and write data on the DQ bus in the same cycle")

  a_legal_opcode: assert property (@(posedge clk) disable iff (!rst_n || !en)
    c_any |-> (cmd inside {CMD_MRS, CMD_REF, CMD_PRE, CMD_ACT, CMD_WR, CMD_RD}))
    else `uvm_error("SVA_OPCODE", $sformatf("unsupported command encoding 4'b%04b", $sampled(cmd)))

  a_cmd_known: assert property (@(posedge clk) disable iff (!rst_n || !en)
    !$isunknown({cmd, dram_ba}))
    else `uvm_error("SVA_X", "X/Z on command or bank-address pins")

endmodule
