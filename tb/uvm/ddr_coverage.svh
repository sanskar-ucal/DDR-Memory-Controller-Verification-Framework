// ============================================================================
// ddr_coverage -- functional coverage collector.
//
// Built purely from black-box observations (host channel + DRAM command bus).
// Bins are explicit, named and planned up front (see docs/verification_plan.md);
// results are written as JSON so the regression can merge them across seeds and
// produce the coverage matrix. (Explicit bins are used instead of covergroups
// because Verilator's covergroup reporting is not yet complete.)
// ============================================================================
class ddr_coverage extends uvm_component;
  `uvm_component_utils(ddr_coverage)

  uvm_analysis_imp_req   #(ddr_txn,      ddr_coverage) req_imp;
  uvm_analysis_imp_rsp   #(ddr_rsp,      ddr_coverage) rsp_imp;
  uvm_analysis_imp_cmd   #(ddr_cmd_item, ddr_coverage) cmd_imp;
  uvm_analysis_imp_stall #(ddr_txn,      ddr_coverage) stall_imp;

  ddr_cfg cfg;

  // ---------------- bin storage
  longint unsigned bin_hits [string];
  string           order [$];

  // ---------------- host-side tracking
  ddr_txn          pend [int unsigned];
  int unsigned     bank_pend [NUM_BANKS];
  int unsigned     addr_wr [bit [ADDR_W-1:0]];
  int unsigned     addr_rd [bit [ADDR_W-1:0]];
  longint unsigned last_acc_cyc = 0;
  bit              last_acc_we;
  bit              have_last_acc;
  bit [ADDR_W-1:0] last_acc_addr;

  // ---------------- DRAM-side tracking
  localparam longint NEVER = -100000;
  bit              open      [NUM_BANKS];
  bit [ROW_W-1:0]  orow      [NUM_BANKS];
  bit [ROW_W-1:0]  prev_row  [NUM_BANKS];   // row open before the last explicit PRE
  bit              act_since_cas [NUM_BANKS];
  bit              pre_since_cas [NUM_BANKS];
  bit              ref_since_cas [NUM_BANKS];
  bit              conflict_pre  [NUM_BANKS];   // bank closed by explicit PRE
  bit              cas_since_act [NUM_BANKS];
  longint          t_act [NUM_BANKS], t_pre [NUM_BANKS], t_rd [NUM_BANKS], t_wr [NUM_BANKS];
  longint          t_any_act = NEVER, t_cas = NEVER, t_ref = NEVER, t_prea = NEVER, t_any_rd = NEVER;
  longint          t_any_wr = NEVER;
  int              last_act_ba = -1;
  bit              last_cas_we;
  bit              first_after_ref;
  bit              prea_since_ref;
  longint          refresh_start = NEVER;     // first cycle of a refresh drain (PREA/REF)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // --------------------------------------------------------------------------
  function void def(string g, string b);
    string k = {g, ".", b};
    bin_hits[k] = 0;
    order.push_back(k);
  endfunction

  function void hit(string g, string b);
    string k = {g, ".", b};
    if (!bin_hits.exists(k)) `uvm_fatal("COV", $sformatf("undefined coverage bin %s", k))
    bin_hits[k]++;
  endfunction

  function void def_list(string g, string names[$]);
    foreach (names[i]) def(g, names[i]);
  endfunction

  function void build_phase(uvm_phase phase);
    string ops [2] = '{"RD", "WR"};
    string rs  [3] = '{"HIT", "MISS", "CONFLICT"};
    string l   [$];
    req_imp   = new("req_imp", this);
    rsp_imp   = new("rsp_imp", this);
    cmd_imp   = new("cmd_imp", this);
    stall_imp = new("stall_imp", this);
    if (!uvm_config_db#(ddr_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    for (int b = 0; b < NUM_BANKS; b++) begin
      t_act[b] = NEVER; t_pre[b] = NEVER; t_rd[b] = NEVER; t_wr[b] = NEVER;
    end

    // ---- planned bins
    foreach (ops[o]) for (int b = 0; b < NUM_BANKS; b++) foreach (rs[r])
      def("op_bank_rowstate", $sformatf("%s_B%0d_%s", ops[o], b, rs[r]));
    def("row_buffer", "MISS_AFTER_REFRESH");
    for (int k = 0; k < ROW_W; k++) def("row_alias_conflict", $sformatf("BIT%0d", k));
    l = '{"TRCD", "TRP", "TRAS", "TRC", "TRRD", "TRTP", "TWR", "RD_RD_TCCD", "WR_WR_TCCD",
          "WR_RD_TWTR", "RD_WR_TRTW", "TRFC", "PREA_REF_TRP"};
    def_list("timing_edge", l);
    l = '{"MRS", "ACT", "RD", "WR", "PRE", "PREA", "REF"};
    def_list("dram_cmd", l);
    l = '{"RANDOM", "ZERO", "ONES", "WALK1", "WALK0", "ALT_AA", "ALT_55"};
    def_list("write_data_pattern", l);
    l = '{"ROW_MIN", "ROW_MAX", "COL_MIN", "COL_MAX"};
    def_list("addr_corner", l);
    l = '{"RAW", "WAR", "WAW", "RAW_BACK_TO_BACK"};
    def_list("same_addr_hazard", l);
    l = '{"D1", "D2_4", "D5_8", "D9_12", "D13_PLUS"};
    def_list("outstanding_depth", l);
    for (int b = 0; b < NUM_BANKS; b++) def("queue_full_backpressure", $sformatf("B%0d", b));
    l = '{"RD_BYPASS_WR", "WR_BYPASS_RD", "SAME_DIR_BYPASS", "CROSS_BANK"};
    def_list("out_of_order_completion", l);
    for (int n = 1; n <= NUM_BANKS; n++) def("bank_parallelism", $sformatf("BANKS_%0d", n));
    for (int n = 0; n <= NUM_BANKS; n++) def("refresh_open_banks", $sformatf("OPEN_%0d", n));
    l = '{"PENDING_REQUESTS", "READ_DATA_IN_FLIGHT", "REQ_ACCEPTED_DURING_TRFC",
          "BACKPRESSURE_DURING_REFRESH", "QUEUE_FULL_AT_REFRESH"};
    def_list("refresh_interrupt", l);
    l = '{"RD_RD", "RD_WR", "WR_RD", "WR_WR"};
    def_list("host_back_to_back", l);
  endfunction

  function bit in_refresh(longint c);
    return (refresh_start != NEVER) && (c >= refresh_start) && (t_ref == NEVER || t_ref < refresh_start ||
                                                               c < t_ref + T_RFC);
  endfunction

  // --------------------------------------------------------------------------
  // Host requests
  // --------------------------------------------------------------------------
  function void write_req(ddr_txn t);
    ddr_txn c;
    bit [ADDR_W-1:0] a = t.addr();
    int unsigned n;
    $cast(c, t.clone());

    if (t.we) begin
      data_pat_e p = PAT_RANDOM;
      if      (t.data == '0)                 p = PAT_ZERO;
      else if (t.data == '1)                 p = PAT_ONES;
      else if ($countones(t.data) == 1)      p = PAT_WALK1;
      else if ($countones(~t.data) == 1)     p = PAT_WALK0;
      else if (t.data == {8{8'hAA}})         p = PAT_ALT_AA;
      else if (t.data == {8{8'h55}})         p = PAT_ALT_55;
      hit("write_data_pattern", p.name().substr(4, p.name().len() - 1));
    end
    if (t.row == '0) hit("addr_corner", "ROW_MIN");
    if (t.row == '1) hit("addr_corner", "ROW_MAX");
    if (t.col == '0) hit("addr_corner", "COL_MIN");
    if (t.col == '1) hit("addr_corner", "COL_MAX");

    // same-address hazards against still-outstanding requests
    if (!t.we && addr_wr.exists(a) && addr_wr[a] > 0) hit("same_addr_hazard", "RAW");
    if ( t.we && addr_rd.exists(a) && addr_rd[a] > 0) hit("same_addr_hazard", "WAR");
    if ( t.we && addr_wr.exists(a) && addr_wr[a] > 0) hit("same_addr_hazard", "WAW");
    if (!t.we && have_last_acc && last_acc_we && last_acc_addr == a && t.accept_cycle == last_acc_cyc + 1)
      hit("same_addr_hazard", "RAW_BACK_TO_BACK");

    if (have_last_acc && t.accept_cycle == last_acc_cyc + 1)
      hit("host_back_to_back", {last_acc_we ? "WR" : "RD", "_", t.we ? "WR" : "RD"});

    if (t.we) addr_wr[a] = addr_wr.exists(a) ? addr_wr[a] + 1 : 1;
    else      addr_rd[a] = addr_rd.exists(a) ? addr_rd[a] + 1 : 1;
    pend[t.id] = c;
    bank_pend[t.ba]++;

    n = pend.size();
    if      (n == 1)  hit("outstanding_depth", "D1");
    else if (n <= 4)  hit("outstanding_depth", "D2_4");
    else if (n <= 8)  hit("outstanding_depth", "D5_8");
    else if (n <= 12) hit("outstanding_depth", "D9_12");
    else              hit("outstanding_depth", "D13_PLUS");

    if (t_ref != NEVER && t.accept_cycle > t_ref && t.accept_cycle < t_ref + T_RFC)
      hit("refresh_interrupt", "REQ_ACCEPTED_DURING_TRFC");

    have_last_acc = 1;
    last_acc_cyc  = t.accept_cycle;
    last_acc_we   = t.we;
    last_acc_addr = a;
  endfunction

  function void write_stall(ddr_txn t);
    hit("queue_full_backpressure", $sformatf("B%0d", t.ba));
    if (in_refresh(t.accept_cycle)) hit("refresh_interrupt", "BACKPRESSURE_DURING_REFRESH");
  endfunction

  // --------------------------------------------------------------------------
  // Host responses: out-of-order completion
  // --------------------------------------------------------------------------
  function void write_rsp(ddr_rsp r);
    ddr_txn t;
    bit [ADDR_W-1:0] a;
    if (!pend.exists(r.id)) return;
    t = pend[r.id];
    a = t.addr();
    foreach (pend[i]) begin
      ddr_txn o = pend[i];
      if (o.accept_cycle < t.accept_cycle) begin
        if (o.ba != t.ba)            hit("out_of_order_completion", "CROSS_BANK");
        else if (o.we == t.we)       hit("out_of_order_completion", "SAME_DIR_BYPASS");
        else if (!t.we)              hit("out_of_order_completion", "RD_BYPASS_WR");
        else                         hit("out_of_order_completion", "WR_BYPASS_RD");
      end
    end
    if (t.we) addr_wr[a]--; else addr_rd[a]--;
    bank_pend[t.ba]--;
    pend.delete(r.id);
  endfunction

  // --------------------------------------------------------------------------
  // DRAM commands
  // --------------------------------------------------------------------------
  function void write_cmd(ddr_cmd_item it);
    longint c = longint'(it.cycle);
    int b = int'(it.ba);
    hit("dram_cmd", it.is_prea() ? "PREA" : cmd_name(it.cmd));

    if (first_after_ref && it.cmd != CMD_REF) begin
      if (c - t_ref == T_RFC) hit("timing_edge", "TRFC");
      first_after_ref = 0;
    end

    case (it.cmd)
      CMD_ACT: begin
        if (c - t_pre[b] == T_RP)                          hit("timing_edge", "TRP");
        if (c - t_act[b] == T_RC)                          hit("timing_edge", "TRC");
        if (c - t_any_act == T_RRD && last_act_ba != b)    hit("timing_edge", "TRRD");
        if (conflict_pre[b]) begin
          bit [ROW_W-1:0] d = prev_row[b] ^ it.addr[ROW_W-1:0];
          if ($countones(d) == 1)
            for (int k = 0; k < ROW_W; k++) if (d[k]) hit("row_alias_conflict", $sformatf("BIT%0d", k));
        end
        open[b] = 1; orow[b] = it.addr[ROW_W-1:0];
        act_since_cas[b] = 1;
        cas_since_act[b] = 0;
        t_act[b] = c; t_any_act = c; last_act_ba = b;
      end

      CMD_RD, CMD_WR: begin
        bit we = (it.cmd == CMD_WR);
        string st;
        int nb = 0;
        if (!cas_since_act[b] && c - t_act[b] == T_RCD) hit("timing_edge", "TRCD");
        if (c - t_cas == T_CCD && last_cas_we == we)    hit("timing_edge", we ? "WR_WR_TCCD" : "RD_RD_TCCD");
        if (!we && last_cas_we && c - t_any_wr == T_WR2RD)  hit("timing_edge", "WR_RD_TWTR");
        if ( we && !last_cas_we && c - t_any_rd == T_RD2WR) hit("timing_edge", "RD_WR_TRTW");

        if (!act_since_cas[b])      st = "HIT";
        else if (pre_since_cas[b])  st = "CONFLICT";
        else                        st = "MISS";
        if (act_since_cas[b] && ref_since_cas[b] && !pre_since_cas[b]) hit("row_buffer", "MISS_AFTER_REFRESH");
        hit("op_bank_rowstate", $sformatf("%s_B%0d_%s", we ? "WR" : "RD", b, st));

        for (int k = 0; k < NUM_BANKS; k++) if (bank_pend[k] > 0) nb++;
        if (nb > 0) hit("bank_parallelism", $sformatf("BANKS_%0d", nb));

        act_since_cas[b] = 0; pre_since_cas[b] = 0; ref_since_cas[b] = 0;
        cas_since_act[b] = 1;
        t_cas = c; last_cas_we = we;
        if (we) begin t_wr[b] = c; t_any_wr = c; end
        else    begin t_rd[b] = c; t_any_rd = c; end
      end

      CMD_PRE: begin
        if (it.a10) begin
          int n_open = 0;
          for (int k = 0; k < NUM_BANKS; k++) if (open[k]) n_open++;
          hit("refresh_open_banks", $sformatf("OPEN_%0d", n_open));
          refresh_ctx(c);
          prea_since_ref = 1;
          t_prea = c;
        end
        for (int k = 0; k < NUM_BANKS; k++) begin
          if ((it.a10 || k == b) && open[k]) begin
            if (c - t_act[k] == T_RAS)                         hit("timing_edge", "TRAS");
            if (t_rd[k] > t_act[k] && c - t_rd[k] == T_RTP)    hit("timing_edge", "TRTP");
            if (t_wr[k] > t_act[k] && c - t_wr[k] == T_WR2PRE) hit("timing_edge", "TWR");
            open[k] = 0;
            t_pre[k] = c;
            if (it.a10) begin
              ref_since_cas[k] = 1;
              conflict_pre[k]  = 0;
            end else begin
              pre_since_cas[k] = 1;
              conflict_pre[k]  = 1;
              prev_row[k]      = orow[k];
            end
          end
        end
      end

      CMD_REF: begin
        if (!prea_since_ref) begin
          hit("refresh_open_banks", "OPEN_0");
          refresh_ctx(c);
        end
        if (prea_since_ref && c - t_prea == T_RP) hit("timing_edge", "PREA_REF_TRP");
        prea_since_ref  = 0;
        first_after_ref = 1;
        t_ref = c;
        for (int k = 0; k < NUM_BANKS; k++) begin
          ref_since_cas[k] = 1;
          conflict_pre[k]  = 0;
        end
      end
      default: ;
    endcase
  endfunction

  // Context sampled once per refresh, at the start of the drain
  function void refresh_ctx(longint c);
    refresh_start = c;
    if (pend.size() > 0) hit("refresh_interrupt", "PENDING_REQUESTS");
    if (c - t_any_rd < CL) hit("refresh_interrupt", "READ_DATA_IN_FLIGHT");
    for (int k = 0; k < NUM_BANKS; k++)
      if (bank_pend[k] >= QDEPTH) begin
        hit("refresh_interrupt", "QUEUE_FULL_AT_REFRESH");
        break;
      end
  endfunction

  // --------------------------------------------------------------------------
  // Reporting
  // --------------------------------------------------------------------------
  function real percent();
    int h = 0;
    foreach (order[i]) if (bin_hits[order[i]] > 0) h++;
    return order.size() ? 100.0 * h / order.size() : 0.0;
  endfunction

  function void report_phase(uvm_phase phase);
    string s, holes;
    int    n_holes = 0;
    foreach (order[i]) if (bin_hits[order[i]] == 0) begin
      holes = {holes, "\n    ", order[i]};
      n_holes++;
    end
    `uvm_info("COV_SUMMARY", $sformatf("functional coverage %0.1f%% (%0d/%0d bins)%s%s",
              percent(), order.size() - n_holes, order.size(),
              n_holes ? "; holes:" : "", holes), UVM_NONE)
    if (cfg.cov_file != "") write_json(cfg.cov_file);
  endfunction

  function void write_json(string path);
    int fd = $fopen(path, "w");
    if (fd == 0) begin
      `uvm_warning("COV", $sformatf("cannot open %s", path))
      return;
    end
    $fwrite(fd, "{\n  \"test\": \"%s\",\n  \"seed\": %0d,\n  \"bins\": {\n", cfg.test_name, cfg.seed);
    foreach (order[i])
      $fwrite(fd, "    \"%s\": %0d%s\n", order[i], bin_hits[order[i]], (i == order.size() - 1) ? "" : ",");
    $fwrite(fd, "  }\n}\n");
    $fclose(fd);
  endfunction
endclass
