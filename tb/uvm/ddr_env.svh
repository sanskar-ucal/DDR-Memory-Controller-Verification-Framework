// ============================================================================
// Environment
// ============================================================================
class ddr_env extends uvm_env;
  `uvm_component_utils(ddr_env)

  ddr_cfg          cfg;
  ddr_host_agent   host;
  ddr_dram_monitor dram_mon;
  ddr_scoreboard   sb;
  ddr_coverage     cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(ddr_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    host     = ddr_host_agent::type_id::create("host", this);
    dram_mon = ddr_dram_monitor::type_id::create("dram_mon", this);
    sb       = ddr_scoreboard::type_id::create("sb", this);
    cov      = ddr_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    host.mon.ap_req.connect(sb.req_imp);
    host.mon.ap_rsp.connect(sb.rsp_imp);
    host.mon.ap_req.connect(cov.req_imp);
    host.mon.ap_rsp.connect(cov.rsp_imp);
    host.mon.ap_stall.connect(cov.stall_imp);
    dram_mon.ap.connect(cov.cmd_imp);
  endfunction
endclass
