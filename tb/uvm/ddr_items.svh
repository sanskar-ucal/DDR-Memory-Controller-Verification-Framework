// ============================================================================
// Configuration object and transaction types
// ============================================================================

class ddr_cfg extends uvm_object;
  `uvm_object_utils(ddr_cfg)

  int unsigned num_txn       = 1000;   // +NUM_TXN=
  int unsigned max_latency   = MAX_LATENCY;
  int unsigned drain_timeout = 20000;
  bit          trace_cmds    = 0;      // +TRACE: print every DRAM command
  string       cov_file      = "";     // +COV_FILE=
  string       test_name     = "";
  int unsigned seed          = 0;
  int unsigned max_quit      = 25;     // +MAX_QUIT=: stop after this many errors

  function new(string name = "ddr_cfg");
    super.new(name);
  endfunction

  function void load_plusargs();
    void'($value$plusargs("NUM_TXN=%d", num_txn));
    void'($value$plusargs("MAX_LATENCY=%d", max_latency));
    void'($value$plusargs("COV_FILE=%s", cov_file));
    void'($value$plusargs("MAX_QUIT=%d", max_quit));
    if (!$value$plusargs("verilator+seed+%d", seed))
      void'($value$plusargs("SEED=%d", seed));
    trace_cmds = $test$plusargs("TRACE");
  endfunction
endclass


typedef enum {
  PAT_RANDOM, PAT_ZERO, PAT_ONES, PAT_WALK1, PAT_WALK0, PAT_ALT_AA, PAT_ALT_55
} data_pat_e;


// ----------------------------------------------------------------------------
// Host request (sequence item). Randomized by sequences, completed by the
// driver (ID) and annotated by the monitor (acceptance cycle).
// ----------------------------------------------------------------------------
class ddr_txn extends uvm_sequence_item;
  `uvm_object_utils(ddr_txn)

  rand bit                we;
  rand bit [BA_W-1:0]     ba;
  rand bit [ROW_W-1:0]    row;
  rand bit [COL_W-1:0]    col;
  rand bit [DQ_W-1:0]     data;
  rand data_pat_e         pat;
  rand bit [5:0]          shift;
  rand int unsigned       gap;      // idle cycles before the request is presented

  bit [ID_W-1:0]          id;
  longint unsigned        accept_cycle;
  bit [DQ_W-1:0]          exp_data; // reads: expected data from the reference model

  constraint c_gap { gap dist {0 :/ 60, [1:2] :/ 25, [3:8] :/ 10, [9:40] :/ 5}; }
  constraint c_pat { pat dist {PAT_RANDOM := 70, PAT_ZERO := 5, PAT_ONES := 5, PAT_WALK1 := 5,
                               PAT_WALK0 := 5, PAT_ALT_AA := 5, PAT_ALT_55 := 5}; }

  function new(string name = "ddr_txn");
    super.new(name);
  endfunction

  function void post_randomize();
    case (pat)
      PAT_ZERO:   data = '0;
      PAT_ONES:   data = '1;
      PAT_WALK1:  data = 64'h1 << shift;
      PAT_WALK0:  data = ~(64'h1 << shift);
      PAT_ALT_AA: data = {8{8'hAA}};
      PAT_ALT_55: data = {8{8'h55}};
      default: ;
    endcase
  endfunction

  function logic [ADDR_W-1:0] addr();
    return make_addr(ba, row, col);
  endfunction

  function void do_copy(uvm_object rhs);
    ddr_txn t;
    super.do_copy(rhs);
    if (!$cast(t, rhs)) `uvm_fatal("CAST", "do_copy type mismatch")
    we = t.we; ba = t.ba; row = t.row; col = t.col; data = t.data; pat = t.pat;
    shift = t.shift; gap = t.gap; id = t.id; accept_cycle = t.accept_cycle;
    exp_data = t.exp_data;
  endfunction

  function string convert2string();
    return $sformatf("%s id=%0d ba=%0d row=0x%03h col=0x%02h data=0x%016h",
                     we ? "WR" : "RD", id, ba, row, col, data);
  endfunction
endclass


// Request biased toward a hot working set (4 rows per bank, 8 columns) so that
// random traffic produces row hits and same-address reuse. The distribution is
// a class constraint on purpose: Verilator 5.052 silently drops `dist` inside
// inline `randomize() with {}` blocks.
class ddr_hot_txn extends ddr_txn;
  `uvm_object_utils(ddr_hot_txn)

  constraint c_hot_row { row dist { [0:3] :/ 60, [4:31] :/ 20, [32:4095] :/ 20 }; }
  constraint c_hot_col { col dist { [0:7] :/ 50, [8:255] :/ 50 }; }

  function new(string name = "ddr_hot_txn");
    super.new(name);
  endfunction
endclass


// ----------------------------------------------------------------------------
// Host response observed by the monitor
// ----------------------------------------------------------------------------
class ddr_rsp extends uvm_object;
  `uvm_object_utils(ddr_rsp)

  bit                is_write;
  bit [ID_W-1:0]     id;
  bit [DQ_W-1:0]     data;
  longint unsigned   cycle;

  function new(string name = "ddr_rsp");
    super.new(name);
  endfunction

  function string convert2string();
    return is_write ? $sformatf("WR_ACK id=%0d @%0d", id, cycle)
                    : $sformatf("RD_RSP id=%0d data=0x%016h @%0d", id, data, cycle);
  endfunction
endclass


// ----------------------------------------------------------------------------
// DRAM command observed on the command bus
// ----------------------------------------------------------------------------
class ddr_cmd_item extends uvm_object;
  `uvm_object_utils(ddr_cmd_item)

  dram_cmd_e         cmd;
  bit                a10;
  bit [BA_W-1:0]     ba;
  bit [DA_W-1:0]     addr;
  longint unsigned   cycle;

  function new(string name = "ddr_cmd_item");
    super.new(name);
  endfunction

  function bit is_prea(); return cmd == CMD_PRE && a10; endfunction

  function string convert2string();
    case (cmd)
      CMD_ACT:         return $sformatf("@%0d ACT  ba=%0d row=0x%03h", cycle, ba, addr[ROW_W-1:0]);
      CMD_RD, CMD_WR:  return $sformatf("@%0d %-4s ba=%0d col=0x%02h", cycle, cmd_name(cmd), ba, addr[COL_W-1:0]);
      CMD_PRE:         return a10 ? $sformatf("@%0d PREA", cycle) : $sformatf("@%0d PRE  ba=%0d", cycle, ba);
      CMD_MRS:         return $sformatf("@%0d MRS  val=0x%04h", cycle, addr);
      default:         return $sformatf("@%0d %s", cycle, cmd_name(cmd));
    endcase
  endfunction
endclass
