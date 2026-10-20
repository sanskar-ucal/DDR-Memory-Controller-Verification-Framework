// ============================================================================
// Tests. Each test selects a traffic sequence and a default request count
// (override with +NUM_TXN=<n>). Pass/fail is decided from the UVM report
// server: any UVM_ERROR/UVM_FATAL (scoreboard, SVA, DRAM model) fails the run.
// ============================================================================
// Prefix every warning/error with the bus-cycle number so that SVA, DRAM-model
// and scoreboard messages line up with monitor traces and waveforms.
class ddr_cycle_catcher extends uvm_report_catcher;
  virtual ddr_host_if vif;

  function new(string name = "ddr_cycle_catcher");
    super.new(name);
  endfunction

  function action_e catch();
    if (get_severity() != UVM_INFO)
      set_message($sformatf("(cycle %0d) %s", vif.sampled_cycle(), get_message()));
    return THROW;
  endfunction
endclass


class ddr_base_test extends uvm_test;
  `uvm_component_utils(ddr_base_test)

  ddr_cfg             cfg;
  ddr_env             env;
  virtual ddr_host_if vif;
  int unsigned        default_txn = 1000;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function ddr_base_seq make_seq();
    return ddr_mixed_seq::type_id::create("seq");
  endfunction

  function void build_phase(uvm_phase phase);
    cfg = ddr_cfg::type_id::create("cfg");
    cfg.num_txn   = default_txn;
    cfg.load_plusargs();
    cfg.test_name = get_type_name();
    uvm_config_db#(ddr_cfg)::set(this, "*", "cfg", cfg);
    if (!uvm_config_db#(virtual ddr_host_if)::get(this, "", "host_vif", vif))
      `uvm_fatal("NOVIF", "host_vif not set")
    env = ddr_env::type_id::create("env", this);
    // Bound the log size of failing runs; regressions only need the first errors.
    uvm_top.set_report_max_quit_count(cfg.max_quit);
    begin
      ddr_cycle_catcher c = new("cycle_catcher");
      c.vif = vif;
      uvm_report_cb::add(null, c);
    end
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    `uvm_info("CFG", $sformatf("test=%s seed=%0d num_txn=%0d", cfg.test_name, cfg.seed, cfg.num_txn), UVM_NONE)
  endfunction

  task run_phase(uvm_phase phase);
    ddr_base_seq seq;
    longint unsigned t0;
    phase.raise_objection(this);
    do @(posedge vif.clk); while (!vif.init_done);
    seq   = make_seq();
    seq.n = cfg.num_txn;
    seq.start(env.host.sqr);

    // Drain: wait for every accepted request to complete.
    t0 = vif.cycle;
    while (env.sb.outstanding() > 0 && vif.cycle - t0 < cfg.drain_timeout) @(posedge vif.clk);
    repeat (CL + 8) @(posedge vif.clk);
    `uvm_info("DONE", $sformatf("%0d requests generated, finished at cycle %0d", seq.sent, vif.cycle), UVM_NONE)
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int n_err = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    if (n_err == 0) `uvm_info("RESULT", "*** TEST PASSED ***", UVM_NONE)
    else            `uvm_info("RESULT", $sformatf("*** TEST FAILED *** (%0d errors)", n_err), UVM_NONE)
  endfunction
endclass


`define DDR_TEST(NAME, SEQ, NTXN) \
class NAME extends ddr_base_test; \
  `uvm_component_utils(NAME) \
  function new(string name, uvm_component parent); \
    super.new(name, parent); \
    default_txn = NTXN; \
  endfunction \
  virtual function ddr_base_seq make_seq(); \
    SEQ s = SEQ::type_id::create("seq"); \
    return s; \
  endfunction \
endclass

`DDR_TEST(ddr_smoke_test,         ddr_random_seq,         300)
`DDR_TEST(ddr_rand_test,          ddr_mixed_seq,          5000)
`DDR_TEST(ddr_soak_test,          ddr_mixed_seq,          100000)
`DDR_TEST(ddr_random_only_test,   ddr_random_seq,         5000)
`DDR_TEST(ddr_row_hit_test,       ddr_row_hit_seq,        3000)
`DDR_TEST(ddr_bank_conflict_test, ddr_bank_conflict_seq,  3000)
`DDR_TEST(ddr_hazard_test,        ddr_hazard_seq,         4000)
`DDR_TEST(ddr_b2b_test,           ddr_b2b_seq,            3000)
`DDR_TEST(ddr_refresh_test,       ddr_refresh_seq,        3000)
`DDR_TEST(ddr_row_alias_test,     ddr_row_alias_seq,      2000)
`DDR_TEST(ddr_corner_test,        ddr_corner_seq,         1000)
