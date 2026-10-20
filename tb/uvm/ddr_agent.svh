// ============================================================================
// Host agent (sequencer + driver + monitor) and passive DRAM bus monitor
// ============================================================================

typedef uvm_sequencer #(ddr_txn) ddr_sequencer;


// ----------------------------------------------------------------------------
// Driver: presents requests on the valid/ready channel, owns the ID pool.
// ----------------------------------------------------------------------------
class ddr_driver extends uvm_driver #(ddr_txn);
  `uvm_component_utils(ddr_driver)

  virtual ddr_host_if vif;
  bit                 busy [1 << ID_W];
  bit [ID_W-1:0]      next_id;
  int unsigned        n_busy;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual ddr_host_if)::get(this, "", "host_vif", vif))
      `uvm_fatal("NOVIF", "host_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    vif.req_valid <= 1'b0;
    vif.req_we    <= 1'b0;
    vif.req_addr  <= '0;
    vif.req_wdata <= '0;
    vif.req_id    <= '0;
    do @(posedge vif.clk); while (!(vif.rst_n && vif.init_done));
    fork
      release_ids();
    join_none
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) @(posedge vif.clk);
      while (n_busy >= (1 << ID_W) - 1) @(posedge vif.clk);
      while (busy[next_id]) next_id++;
      req.id        = next_id;
      busy[next_id] = 1'b1;
      n_busy++;
      next_id++;

      vif.req_valid <= 1'b1;
      vif.req_we    <= req.we;
      vif.req_addr  <= req.addr();
      vif.req_wdata <= req.we ? req.data : '0;
      vif.req_id    <= req.id;
      do @(posedge vif.clk); while (!vif.req_ready);
      vif.req_valid <= 1'b0;
      seq_item_port.item_done();
    end
  endtask

  task release_ids();
    forever begin
      @(posedge vif.clk);
      if (vif.rd_valid && busy[vif.rd_id]) begin
        busy[vif.rd_id] = 1'b0; n_busy--;
      end
      if (vif.wr_ack_valid && busy[vif.wr_ack_id]) begin
        busy[vif.wr_ack_id] = 1'b0; n_busy--;
      end
    end
  endtask
endclass


// ----------------------------------------------------------------------------
// Host monitor: accepted requests, responses and back-pressure events.
// ----------------------------------------------------------------------------
class ddr_host_monitor extends uvm_monitor;
  `uvm_component_utils(ddr_host_monitor)

  virtual ddr_host_if         vif;
  uvm_analysis_port #(ddr_txn) ap_req;
  uvm_analysis_port #(ddr_rsp) ap_rsp;
  uvm_analysis_port #(ddr_txn) ap_stall;   // first cycle of a stalled request

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap_req   = new("ap_req", this);
    ap_rsp   = new("ap_rsp", this);
    ap_stall = new("ap_stall", this);
    if (!uvm_config_db#(virtual ddr_host_if)::get(this, "", "host_vif", vif))
      `uvm_fatal("NOVIF", "host_vif not set")
  endfunction

  function ddr_txn capture_req();
    ddr_txn t;
    t = ddr_txn::type_id::create("req");
    t.we           = vif.req_we;
    t.ba           = addr_ba(vif.req_addr);
    t.row          = addr_row(vif.req_addr);
    t.col          = addr_col(vif.req_addr);
    t.data         = vif.req_wdata;
    t.id           = vif.req_id;
    t.accept_cycle = vif.cycle;
    return t;
  endfunction

  task run_phase(uvm_phase phase);
    bit stalled = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) continue;

      if (vif.req_valid && vif.req_ready) begin
        ap_req.write(capture_req());
        stalled = 0;
      end else if (vif.req_valid && !vif.req_ready && vif.init_done) begin
        if (!stalled) ap_stall.write(capture_req());
        stalled = 1;
      end

      if (vif.rd_valid) begin
        ddr_rsp r = ddr_rsp::type_id::create("rd_rsp");
        r.is_write = 0;
        r.id       = vif.rd_id;
        r.data     = vif.rd_data;
        r.cycle    = vif.cycle;
        ap_rsp.write(r);
      end
      if (vif.wr_ack_valid) begin
        ddr_rsp r = ddr_rsp::type_id::create("wr_ack");
        r.is_write = 1;
        r.id       = vif.wr_ack_id;
        r.cycle    = vif.cycle;
        ap_rsp.write(r);
      end
    end
  endtask
endclass


class ddr_host_agent extends uvm_agent;
  `uvm_component_utils(ddr_host_agent)

  ddr_sequencer    sqr;
  ddr_driver       drv;
  ddr_host_monitor mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    sqr = ddr_sequencer::type_id::create("sqr", this);
    drv = ddr_driver::type_id::create("drv", this);
    mon = ddr_host_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass


// ----------------------------------------------------------------------------
// Passive DRAM command-bus monitor
// ----------------------------------------------------------------------------
class ddr_dram_monitor extends uvm_monitor;
  `uvm_component_utils(ddr_dram_monitor)

  virtual ddr_dram_if               vif;
  uvm_analysis_port #(ddr_cmd_item) ap;
  ddr_cfg                           cfg;
  longint unsigned                  n_cmd [string];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual ddr_dram_if)::get(this, "", "dram_vif", vif))
      `uvm_fatal("NOVIF", "dram_vif not set")
    if (!uvm_config_db#(ddr_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
  endfunction

  task run_phase(uvm_phase phase);
    logic [3:0] c;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) continue;
      c = {vif.cs_n, vif.ras_n, vif.cas_n, vif.we_n};
      if (is_active_cmd(c)) begin
        ddr_cmd_item it = ddr_cmd_item::type_id::create("cmd");
        string nm;
        it.cmd   = dram_cmd_e'(c);
        it.a10   = vif.addr[A10];
        it.ba    = vif.ba;
        it.addr  = vif.addr;
        it.cycle = vif.cycle;
        nm = cmd_name(c, it.a10);
        n_cmd[nm] = n_cmd.exists(nm) ? n_cmd[nm] + 1 : 1;
        if (cfg.trace_cmds) `uvm_info("DRAM_CMD", it.convert2string(), UVM_NONE)
        ap.write(it);
      end
    end
  endtask
endclass
