// ============================================================================
// ddr_pkg -- shared parameters, command encoding and helpers for the
// DDR4-inspired 4-bank memory controller and its verification environment.
//
// All timing values are expressed in controller clock cycles (1 command slot
// per cycle). Values are scaled down from real DDR4 so that randomized
// simulations reach deep state quickly, but the relationships between them
// (tRC = tRAS + tRP, tRFC >> tRC, tREFI >> tRFC, CL > CWL) are preserved.
// ============================================================================
package ddr_pkg;

  // --------------------------------------------------------------------------
  // Geometry
  // --------------------------------------------------------------------------
  localparam int NUM_BANKS = 4;
  localparam int BA_W      = 2;
  localparam int ROW_W     = 12;
  localparam int COL_W     = 8;
  localparam int DQ_W      = 64;
  localparam int ID_W      = 8;
  localparam int ADDR_W    = BA_W + ROW_W + COL_W;   // host address {ba,row,col}
  localparam int DA_W      = 14;                     // DRAM address pins A[13:0]
  localparam int A10       = 10;                     // A10: all-bank precharge
  localparam int QDEPTH    = 4;                      // per-bank request queue
  localparam int QCNT_W    = $clog2(QDEPTH + 1);

  // --------------------------------------------------------------------------
  // Timing (cycles)
  // --------------------------------------------------------------------------
  localparam int CL        = 5;   // RD command -> read data on DQ
  localparam int CWL       = 4;   // WR command -> write data on DQ
  localparam int T_RCD     = 4;   // ACT -> RD/WR, same bank
  localparam int T_RP      = 4;   // PRE -> ACT, same bank
  localparam int T_RAS     = 10;  // ACT -> PRE, same bank
  localparam int T_RC      = 14;  // ACT -> ACT, same bank
  localparam int T_RRD     = 2;   // ACT -> ACT, different banks
  localparam int T_CCD     = 2;   // CAS -> CAS
  localparam int T_RTP     = 3;   // RD -> PRE, same bank
  localparam int T_WR      = 4;   // end of write data -> PRE (write recovery)
  localparam int T_WTR     = 3;   // end of write data -> RD (turnaround)
  localparam int T_RFC     = 24;  // REF -> any command
  localparam int T_REFI    = 390; // average refresh interval
  localparam int T_MRD     = 4;   // MRS -> any command
  localparam int T_INIT    = 16;  // reset release -> MRS

  // Derived command-to-command spacings
  localparam int T_WR2PRE  = CWL + 1 + T_WR;   // WR cmd -> PRE (same bank)
  localparam int T_WR2RD   = CWL + 1 + T_WTR;  // WR cmd -> RD (any bank)
  localparam int T_RD2WR   = CL + 2 - CWL;     // RD cmd -> WR (bus turnaround)

  // Max cycles from a refresh deadline to the REF command (bank drain:
  // tRAS/tWR recovery + tRP). The controller contract is that every REF
  // interval is <= T_REFI + T_REF_SLACK; there is no postponement.
  localparam int T_REF_SLACK   = 32;
  // JEDEC allows up to 8 postponed refreshes; beyond that cells lose charge.
  localparam int T_RETENTION   = 9 * T_REFI;

  // Request scheduling
  localparam int MAX_BYPASS    = 4;     // starvation guard for FR-FCFS
  localparam int MAX_LATENCY   = 600;   // liveness bound used by checkers

  // --------------------------------------------------------------------------
  // DRAM command encoding: {cs_n, ras_n, cas_n, we_n} (JEDEC truth table)
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    CMD_MRS = 4'b0000,
    CMD_REF = 4'b0001,
    CMD_PRE = 4'b0010,   // A10=1 -> PREA (all banks)
    CMD_ACT = 4'b0011,
    CMD_WR  = 4'b0100,
    CMD_RD  = 4'b0101,
    CMD_ZQ  = 4'b0110,
    CMD_NOP = 4'b0111,
    CMD_DES = 4'b1111    // cs_n high: deselect
  } dram_cmd_e;

  // --------------------------------------------------------------------------
  // Controller state machines (exposed for white-box assertions)
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    B_IDLE        = 2'd0,
    B_ACTIVATING  = 2'd1,   // ACT issued, waiting tRCD
    B_ACTIVE      = 2'd2,   // row open, column commands legal
    B_PRECHARGING = 2'd3    // PRE issued, waiting tRP
  } bank_state_e;

  typedef enum logic [1:0] {
    R_IDLE      = 2'd0,
    R_DRAIN     = 2'd1,     // refresh due: stop traffic, close banks
    R_PREA_WAIT = 2'd2,     // PREA issued, waiting tRP
    R_REFRESH   = 2'd3      // REF issued, waiting tRFC
  } ref_state_e;

  typedef enum logic [1:0] {
    I_WAIT = 2'd0,          // power-up wait
    I_MRD  = 2'd1,          // MRS issued, waiting tMRD
    I_DONE = 2'd2
  } init_state_e;

  // Controller request-queue entry
  typedef struct packed {
    logic              we;
    logic [ROW_W-1:0]  row;
    logic [COL_W-1:0]  col;
    logic [DQ_W-1:0]   wdata;
    logic [ID_W-1:0]   id;
  } qentry_t;

  function automatic string cmd_name(logic [3:0] c, logic a10 = 1'b0);
    case (c)
      CMD_MRS: return "MRS";
      CMD_REF: return "REF";
      CMD_PRE: return a10 ? "PREA" : "PRE";
      CMD_ACT: return "ACT";
      CMD_WR:  return "WR";
      CMD_RD:  return "RD";
      CMD_ZQ:  return "ZQ";
      CMD_NOP: return "NOP";
      default: return (c[3]) ? "DES" : "???";
    endcase
  endfunction

  // Any command that is not a deselect / NOP
  function automatic bit is_active_cmd(logic [3:0] c);
    return !(c[3] || c == CMD_NOP);
  endfunction

  // Mode register encoding used by MRS: A[3:0] = CL, A[7:4] = CWL
  function automatic logic [DA_W-1:0] mrs_value(int cl, int cwl);
    logic [DA_W-1:0] v;
    v = '0;
    v[3:0] = cl[3:0];
    v[7:4] = cwl[3:0];
    return v;
  endfunction

  // --------------------------------------------------------------------------
  // Host address helpers
  // --------------------------------------------------------------------------
  function automatic logic [ADDR_W-1:0] make_addr(logic [BA_W-1:0] ba,
                                                  logic [ROW_W-1:0] row,
                                                  logic [COL_W-1:0] col);
    return {ba, row, col};
  endfunction

  function automatic logic [BA_W-1:0]  addr_ba (logic [ADDR_W-1:0] a); return a[ADDR_W-1 -: BA_W]; endfunction
  function automatic logic [ROW_W-1:0] addr_row(logic [ADDR_W-1:0] a); return a[COL_W +: ROW_W];   endfunction
  function automatic logic [COL_W-1:0] addr_col(logic [ADDR_W-1:0] a); return a[COL_W-1:0];        endfunction

  // Deterministic contents of never-written DRAM locations. Shared by the DRAM
  // model and the reference model so reads of untouched memory are checked too.
  function automatic logic [DQ_W-1:0] background(logic [ADDR_W-1:0] a);
    logic [63:0] x;
    x = {42'h0, a} * 64'h9E37_79B9_7F4A_7C15;
    return x ^ 64'hA5A5_0000_0000_5A5A;
  endfunction

endpackage
