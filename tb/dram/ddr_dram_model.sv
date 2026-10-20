// ============================================================================
// ddr_dram_model -- cycle-based behavioral model of a 4-bank DRAM device.
//
// Responsibilities
//   * Decode the JEDEC command bus and track bank state (open row per bank).
//   * Store data (sparse), return read data CL cycles after RD and capture
//     write data CWL cycles after WR, with CL/CWL taken from the MRS command.
//   * Model the *physical consequences* of protocol abuse, the way silicon
//     would misbehave, so that controller bugs propagate to visible data
//     corruption (caught end-to-end by the scoreboard):
//        - CAS before tRCD / after ACT-in-precharge  -> corrupted read/write
//        - PRE before tRAS or before write recovery   -> row restore damaged
//        - REF with a bank open                       -> open row damaged
//        - no REF within the retention window         -> array loses data
//        - commands during tRFC                       -> ignored
//   * Report illegal operations as UVM_ERROR [DRAM_PROTO]; report timing
//     abuse as UVM_WARNING [DRAM_PHYS] (the SVA layer owns timing errors).
// ============================================================================
`include "uvm_macros.svh"

module ddr_dram_model
  import uvm_pkg::*;
  import ddr_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  input  logic              cs_n,
  input  logic              ras_n,
  input  logic              cas_n,
  input  logic              we_n,
  input  logic [BA_W-1:0]   ba,
  input  logic [DA_W-1:0]   addr,
  input  logic              wdata_valid,
  input  logic [DQ_W-1:0]   wdata,
  output logic              rdata_valid,
  output logic [DQ_W-1:0]   rdata
);

  localparam logic [DQ_W-1:0] CORRUPT = 64'hDEAD_BEEF_0BAD_F00D;
  localparam longint NEVER = -100000;

  typedef struct {
    longint            due;
    logic [ADDR_W-1:0] a;
    bit                corrupt;
  } wr_pend_t;

  typedef struct {
    longint          due;
    logic [DQ_W-1:0] d;
  } rd_pend_t;

  // Storage and device state
  logic [DQ_W-1:0]   mem [logic [ADDR_W-1:0]];
  bit                bg_lost;            // retention failure: background gone

  bit                open     [NUM_BANKS];
  logic [ROW_W-1:0]  orow     [NUM_BANKS];
  bit                unstable [NUM_BANKS]; // activation started too early
  longint            t_act [NUM_BANKS], t_pre [NUM_BANKS];
  longint            t_rd  [NUM_BANKS], t_wr  [NUM_BANKS];
  longint            t_any_act, t_cas, t_any_wr, t_mrs;
  longint            t_ref;              // retention baseline (REF or MRS)
  longint            t_refcmd;           // last REF command (tRFC)
  bit                mrs_seen;
  int                cl_p, cwl_p;
  longint            cyc;

  wr_pend_t          wq[$];
  rd_pend_t          rq[$];

  // Statistics
  longint unsigned   n_cmd [string];
  int unsigned       n_proto_err, n_phys;

  // --------------------------------------------------------------------------
  function automatic logic [DQ_W-1:0] peek(logic [ADDR_W-1:0] a);
    if (mem.exists(a)) return mem[a];
    return bg_lost ? (background(a) ^ CORRUPT) : background(a);
  endfunction

  function automatic void corrupt_row(int b, logic [ROW_W-1:0] r, string why);
    for (int c = 0; c < (1 << COL_W); c++) begin
      logic [ADDR_W-1:0] a;
      a = make_addr(BA_W'(b), r, COL_W'(c));
      mem[a] = peek(a) ^ CORRUPT;
    end
    n_phys++;
    `uvm_warning("DRAM_PHYS", $sformatf("bank %0d row 0x%0h contents damaged: %s", b, r, why))
  endfunction

  function automatic void proto_err(string msg);
    n_proto_err++;
    `uvm_error("DRAM_PROTO", msg)
  endfunction

  function automatic void phys(string msg);
    n_phys++;
    `uvm_warning("DRAM_PHYS", msg)
  endfunction

  // --------------------------------------------------------------------------
  logic [3:0] cmd;
  assign cmd = {cs_n, ras_n, cas_n, we_n};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_valid <= 1'b0;
      rdata       <= '0;
      cyc         = 0;
      mrs_seen    = 0;
      bg_lost     = 0;
      cl_p        = CL;
      cwl_p       = CWL;
      t_any_act   = NEVER; t_cas = NEVER; t_any_wr = NEVER; t_mrs = NEVER;
      t_ref       = 0;     t_refcmd = NEVER;
      for (int b = 0; b < NUM_BANKS; b++) begin
        open[b] = 0; unstable[b] = 0; orow[b] = '0;
        t_act[b] = NEVER; t_pre[b] = NEVER; t_rd[b] = NEVER; t_wr[b] = NEVER;
      end
      wq.delete();
      rq.delete();
    end else begin
      // ---------------- write data landing this cycle
      if (wq.size() > 0 && wq[0].due == cyc) begin
        wr_pend_t w;
        w = wq.pop_front();
        if (!wdata_valid) begin
          proto_err($sformatf("write data missing at CWL for addr 0x%0h", w.a));
          mem[w.a] = CORRUPT;
        end else begin
          mem[w.a] = w.corrupt ? (wdata ^ CORRUPT) : wdata;
        end
      end else if (wdata_valid) begin
        proto_err("write data driven with no WR command CWL cycles earlier");
      end

      if (wdata_valid && rdata_valid)
        proto_err("DQ bus contention: read and write data in the same cycle");

      // ---------------- read data return
      if (rq.size() > 0 && rq[0].due == cyc + 1) begin
        rd_pend_t r;
        r = rq.pop_front();
        rdata_valid <= 1'b1;
        rdata       <= r.d;
      end else begin
        rdata_valid <= 1'b0;
      end

      // ---------------- retention
      if (mrs_seen && (cyc - t_ref) > T_RETENTION) begin
        proto_err($sformatf("no REF for %0d cycles: retention lost, array contents decayed",
                            cyc - t_ref));
        foreach (mem[a]) mem[a] = mem[a] ^ CORRUPT;
        bg_lost = 1;
        t_ref   = cyc;
      end

      // ---------------- command decode
      if (is_active_cmd(cmd)) begin
        string nm;
        nm = cmd_name(cmd, addr[A10]);
        n_cmd[nm] = n_cmd.exists(nm) ? n_cmd[nm] + 1 : 1;

        if (!mrs_seen && cmd != CMD_MRS) begin
          proto_err($sformatf("%s issued before mode registers were programmed", nm));
        end else if (cyc - t_refcmd < T_RFC) begin
          proto_err($sformatf("%s issued %0d cycles after REF (device busy refreshing), ignored",
                              nm, cyc - t_refcmd));
        end else begin
          case (cmd)
            CMD_MRS: begin
              mrs_seen = 1;
              t_mrs    = cyc;
              t_ref    = cyc;
              cl_p     = int'(addr[3:0]);
              cwl_p    = int'(addr[7:4]);
              if (cl_p != CL || cwl_p != CWL)
                proto_err($sformatf("MRS programmed CL=%0d CWL=%0d (device datasheet CL=%0d CWL=%0d)",
                                    cl_p, cwl_p, CL, CWL));
            end

            CMD_ACT: begin
              int b;
              b = int'(ba);
              if (open[b]) begin
                proto_err($sformatf("ACT to bank %0d while row 0x%0h is open", b, orow[b]));
                corrupt_row(b, orow[b], "row forcibly replaced by ACT");
              end
              unstable[b] = 0;
              if (cyc - t_pre[b] < T_RP) begin
                phys($sformatf("bank %0d ACT %0d cycles after PRE (tRP=%0d): bitlines not equalized",
                               b, cyc - t_pre[b], T_RP));
                unstable[b] = 1;
              end
              if (cyc - t_act[b] < T_RC) begin
                phys($sformatf("bank %0d ACT %0d cycles after previous ACT (tRC=%0d)",
                               b, cyc - t_act[b], T_RC));
                unstable[b] = 1;
              end
              if (cyc - t_any_act < T_RRD)
                phys($sformatf("ACT %0d cycles after previous ACT (tRRD=%0d)", cyc - t_any_act, T_RRD));
              open[b]   = 1;
              orow[b]   = addr[ROW_W-1:0];
              t_act[b]  = cyc;
              t_any_act = cyc;
            end

            CMD_RD, CMD_WR: begin
              int b;
              bit bad;
              logic [ADDR_W-1:0] a;
              b   = int'(ba);
              bad = 0;
              a   = make_addr(ba, orow[b], addr[COL_W-1:0]);
              if (!open[b]) begin
                proto_err($sformatf("%s to bank %0d with no open row", nm, b));
                bad = 1;
              end else begin
                if (cyc - t_act[b] < T_RCD) begin
                  phys($sformatf("bank %0d %s %0d cycles after ACT (tRCD=%0d): sense amps not settled",
                                 b, nm, cyc - t_act[b], T_RCD));
                  bad = 1;
                end
                if (unstable[b]) bad = 1;
              end
              if (cyc - t_cas < T_CCD)
                phys($sformatf("%s %0d cycles after previous CAS (tCCD=%0d)", nm, cyc - t_cas, T_CCD));
              t_cas = cyc;
              if (cmd == CMD_RD) begin
                rd_pend_t r;
                if (cyc - t_any_wr < T_WR2RD)
                  phys($sformatf("RD %0d cycles after WR (tWTR window=%0d): may return stale data",
                                 cyc - t_any_wr, T_WR2RD));
                r.due = cyc + cl_p;
                r.d   = bad ? (open[b] ? (peek(a) ^ CORRUPT) : CORRUPT) : peek(a);
                rq.push_back(r);
                t_rd[b] = cyc;
              end else begin
                wr_pend_t w;
                w.due     = cyc + cwl_p;
                w.a       = a;
                w.corrupt = bad;
                wq.push_back(w);
                t_wr[b]   = cyc;
                t_any_wr  = cyc;
              end
            end

            CMD_PRE: begin
              for (int b = 0; b < NUM_BANKS; b++) begin
                if (addr[A10] || int'(ba) == b) begin
                  if (open[b]) begin
                    if (cyc - t_act[b] < T_RAS)
                      corrupt_row(b, orow[b], $sformatf("PRE %0d cycles after ACT (tRAS=%0d): incomplete restore",
                                                        cyc - t_act[b], T_RAS));
                    else if (cyc - t_wr[b] < T_WR2PRE && t_wr[b] > t_act[b])
                      corrupt_row(b, orow[b], $sformatf("PRE %0d cycles after WR (write recovery=%0d)",
                                                        cyc - t_wr[b], T_WR2PRE));
                    if (cyc - t_rd[b] < T_RTP && t_rd[b] > t_act[b])
                      phys($sformatf("bank %0d PRE %0d cycles after RD (tRTP=%0d)", b, cyc - t_rd[b], T_RTP));
                    open[b]  = 0;
                    t_pre[b] = cyc;
                  end
                end
              end
            end

            CMD_REF: begin
              for (int b = 0; b < NUM_BANKS; b++) begin
                if (open[b]) begin
                  proto_err($sformatf("REF with bank %0d open (row 0x%0h)", b, orow[b]));
                  corrupt_row(b, orow[b], "REF while row open");
                  open[b] = 0;
                end
                if (cyc - t_pre[b] < T_RP)
                  phys($sformatf("REF %0d cycles after precharge of bank %0d (tRP=%0d)",
                                 cyc - t_pre[b], b, T_RP));
              end
              t_ref    = cyc;
              t_refcmd = cyc;
            end

            default: proto_err($sformatf("unsupported command %s", nm));
          endcase
        end
      end
      cyc = cyc + 1;
    end
  end

  // --------------------------------------------------------------------------
  function automatic string stats();
    string s;
    s = $sformatf("DRAM model: %0d cycles, %0d illegal ops, %0d physical-violation events; commands:",
                  cyc, n_proto_err, n_phys);
    foreach (n_cmd[k]) s = {s, $sformatf(" %s=%0d", k, n_cmd[k])};
    return s;
  endfunction

endmodule
