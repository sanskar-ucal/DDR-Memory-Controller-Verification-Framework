// ============================================================================
// Reference memory model + scoreboard
//
//  * The reference model applies requests in host-acceptance order: that is
//    the ordering contract (per address) the controller must preserve even
//    though it reorders internally.
//  * Expected read data is computed at acceptance and checked when the tagged
//    response returns. Mismatches are classified to speed up debug.
//  * Liveness: every request must complete within cfg.max_latency cycles.
//  * Completeness: no request may be outstanding at end of test, and every
//    response must match an outstanding request of the same type.
// ============================================================================

`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_rsp)
`uvm_analysis_imp_decl(_cmd)
`uvm_analysis_imp_decl(_stall)

class ddr_ref_model;
  localparam int HIST = 4;

  bit [DQ_W-1:0]     mem  [bit [ADDR_W-1:0]];
  bit [DQ_W-1:0]     hist [bit [ADDR_W-1:0]][$];   // previous values (oldest first)
  int                last_wr_id  [bit [ADDR_W-1:0]];
  longint unsigned   last_wr_cyc [bit [ADDR_W-1:0]];

  function bit [DQ_W-1:0] read(bit [ADDR_W-1:0] a);
    return mem.exists(a) ? mem[a] : background(a);
  endfunction

  function void write(bit [ADDR_W-1:0] a, bit [DQ_W-1:0] d, int unsigned id, longint unsigned cyc);
    hist[a].push_back(read(a));
    if (hist[a].size() > HIST) void'(hist[a].pop_front());
    mem[a]         = d;
    last_wr_id[a]  = id;
    last_wr_cyc[a] = cyc;
  endfunction

  function string diagnose(bit [ADDR_W-1:0] a, bit [DQ_W-1:0] exp, bit [DQ_W-1:0] act);
    if ((exp ^ act) == 64'hDEAD_BEEF_0BAD_F00D)
      return "DRAM corruption signature (device-level timing/refresh abuse)";
    if (act == 64'hDEAD_BEEF_0BAD_F00D)
      return "DRAM poison value (access to closed bank or missing write data)";
    if (hist.exists(a))
      foreach (hist[a][i])
        if (hist[a][i] == act)
          return $sformatf("stale data: value from %0d write(s) earlier (ordering / hazard violation)",
                           hist[a].size() - i);
    if (act == background(a))
      return "never-written background value (write lost or went to another address)";
    return $sformatf("unrelated value (%0d bits differ)", $countones(exp ^ act));
  endfunction
endclass


class ddr_scoreboard extends uvm_component;
  `uvm_component_utils(ddr_scoreboard)

  uvm_analysis_imp_req #(ddr_txn, ddr_scoreboard) req_imp;
  uvm_analysis_imp_rsp #(ddr_rsp, ddr_scoreboard) rsp_imp;

  virtual ddr_host_if vif;
  ddr_cfg             cfg;
  ddr_ref_model       ref_m;
  ddr_txn             pending [int unsigned];
  bit                 timed_out [int unsigned];

  // statistics
  longint unsigned n_req, n_rd, n_wr, n_rd_ok, n_wr_ok, n_mismatch, n_unexpected, n_timeout;
  longint unsigned lat_sum [2], lat_max [2], lat_cnt [2];
  longint unsigned lat_min [2] = '{64'hFFFF_FFFF, 64'hFFFF_FFFF};
  longint unsigned last_activity;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    req_imp = new("req_imp", this);
    rsp_imp = new("rsp_imp", this);
    ref_m   = new();
    if (!uvm_config_db#(virtual ddr_host_if)::get(this, "", "host_vif", vif))
      `uvm_fatal("NOVIF", "host_vif not set")
    if (!uvm_config_db#(ddr_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
  endfunction

  function void write_req(ddr_txn t);
    ddr_txn c;
    $cast(c, t.clone());
    n_req++;
    if (c.we) begin
      n_wr++;
      ref_m.write(c.addr(), c.data, c.id, c.accept_cycle);
    end else begin
      n_rd++;
      c.exp_data = ref_m.read(c.addr());
    end
    pending[c.id] = c;
    last_activity = c.accept_cycle;
    if (n_req % 10000 == 0)
      `uvm_info("SB_PROGRESS", $sformatf("%0d requests accepted, %0d reads checked", n_req, n_rd_ok), UVM_NONE)
  endfunction

  function void write_rsp(ddr_rsp r);
    ddr_txn t;
    longint unsigned lat;
    last_activity = r.cycle;
    if (!pending.exists(r.id)) begin
      n_unexpected++;
      `uvm_error("SB_UNEXPECTED", $sformatf("%s for id %0d with no outstanding request @cycle %0d",
                 r.is_write ? "write ack" : "read response", r.id, r.cycle))
      return;
    end
    t = pending[r.id];
    if (t.we != r.is_write) begin
      n_unexpected++;
      `uvm_error("SB_TYPE", $sformatf("id %0d: got %s but request was %s",
                 r.id, r.is_write ? "write ack" : "read data", t.convert2string()))
    end else if (!t.we) begin
      if (r.data !== t.exp_data) begin
        bit [ADDR_W-1:0] a = t.addr();
        n_mismatch++;
        `uvm_error("SB_DATA_MISMATCH", $sformatf({"read id=%0d ba=%0d row=0x%03h col=0x%02h accepted @%0d returned @%0d\n",
                   "      expected 0x%016h\n      actual   0x%016h  (xor 0x%016h)\n",
                   "      last writer id=%0d @%0d\n      diagnosis: %s"},
                   t.id, t.ba, t.row, t.col, t.accept_cycle, r.cycle,
                   t.exp_data, r.data, t.exp_data ^ r.data,
                   ref_m.last_wr_id.exists(a) ? ref_m.last_wr_id[a] : -1,
                   ref_m.last_wr_cyc.exists(a) ? ref_m.last_wr_cyc[a] : 0,
                   ref_m.diagnose(a, t.exp_data, r.data)))
      end else begin
        n_rd_ok++;
      end
    end else begin
      n_wr_ok++;
    end
    lat = r.cycle - t.accept_cycle;
    lat_sum[t.we] += lat;
    lat_cnt[t.we]++;
    if (lat > lat_max[t.we]) lat_max[t.we] = lat;
    if (lat < lat_min[t.we]) lat_min[t.we] = lat;
    pending.delete(r.id);
    if (timed_out.exists(r.id)) timed_out.delete(r.id);
  endfunction

  // Liveness watchdog
  task run_phase(uvm_phase phase);
    forever begin
      repeat (32) @(posedge vif.clk);
      foreach (pending[id]) begin
        if (!timed_out.exists(id) && vif.cycle - pending[id].accept_cycle > cfg.max_latency) begin
          timed_out[id] = 1;
          n_timeout++;
          `uvm_error("SB_TIMEOUT", $sformatf("request not completed after %0d cycles (limit %0d): %s accepted @%0d",
                     vif.cycle - pending[id].accept_cycle, cfg.max_latency,
                     pending[id].convert2string(), pending[id].accept_cycle))
        end
      end
    end
  endtask

  function int unsigned outstanding();
    return pending.size();
  endfunction

  function void check_phase(uvm_phase phase);
    int n = 0;
    foreach (pending[id]) begin
      if (n < 8)
        `uvm_error("SB_LOST", $sformatf("request never completed: %s accepted @%0d",
                   pending[id].convert2string(), pending[id].accept_cycle))
      n++;
    end
    if (n > 8) `uvm_error("SB_LOST", $sformatf("... %0d more requests never completed", n - 8))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB_SUMMARY", $sformatf({"\n  requests accepted : %0d (%0d reads, %0d writes)",
              "\n  reads checked OK  : %0d", "\n  writes acked      : %0d",
              "\n  data mismatches   : %0d", "\n  unexpected rsp    : %0d", "\n  timeouts          : %0d",
              "\n  read  latency     : min %0d / avg %0.1f / max %0d cycles",
              "\n  write latency     : min %0d / avg %0.1f / max %0d cycles"},
              n_req, n_rd, n_wr, n_rd_ok, n_wr_ok, n_mismatch, n_unexpected, n_timeout,
              lat_cnt[0] ? lat_min[0] : 0, lat_cnt[0] ? real'(lat_sum[0]) / lat_cnt[0] : 0.0, lat_max[0],
              lat_cnt[1] ? lat_min[1] : 0, lat_cnt[1] ? real'(lat_sum[1]) / lat_cnt[1] : 0.0, lat_max[1]),
              UVM_NONE)
  endfunction
endclass
