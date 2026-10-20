// ============================================================================
// ddr_ctrl -- simplified DDR4-style memory controller, 4 banks, open-page.
//
//  Host side : valid/ready request channel (read or write, tagged with an ID),
//              read-data and write-ack response channels (no back-pressure).
//  DRAM side : JEDEC-style {cs_n,ras_n,cas_n,we_n} command bus, bank address,
//              address bus (A10 = all-bank precharge), single-beat DQ.
//
//  Micro-architecture
//   * One request queue per bank (QDEPTH entries, oldest at index 0).
//   * FR-FCFS per bank: row hits first, preferring the same CAS direction as
//     the previous column command (fewer bus turnarounds). A younger request
//     may only bypass an older one if they target different addresses.
//     After MAX_BYPASS bypasses the oldest entry is forced.
//   * Across banks: column commands beat row commands, round-robin within
//     each class. One DRAM command per cycle.
//   * Per-bank FSM IDLE -> ACTIVATING -> ACTIVE -> PRECHARGING -> IDLE with
//     countdown timers for tRCD/tRP/tRC/tRAS/tRTP/tWR, and global timers for
//     tRRD/tCCD/tWTR/tRTW/tRFC.
//   * Refresh every T_REFI cycles: drain, PREA, wait tRP, REF, wait tRFC.
//   * Power-up: wait T_INIT, MRS (programs CL/CWL), wait tMRD.
//
//  Injectable defects (compile with +define+<NAME>) are marked `ifdef BUG_*.
// ============================================================================
module ddr_ctrl
  import ddr_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  // Host request channel
  input  logic              req_valid,
  output logic              req_ready,
  input  logic              req_we,
  input  logic [ADDR_W-1:0] req_addr,
  input  logic [DQ_W-1:0]   req_wdata,
  input  logic [ID_W-1:0]   req_id,

  // Read response channel
  output logic              rd_valid,
  output logic [ID_W-1:0]   rd_id,
  output logic [DQ_W-1:0]   rd_data,

  // Write acknowledge channel (asserted when write data is driven to DRAM)
  output logic              wr_ack_valid,
  output logic [ID_W-1:0]   wr_ack_id,

  // DRAM interface
  output logic              dram_cs_n,
  output logic              dram_ras_n,
  output logic              dram_cas_n,
  output logic              dram_we_n,
  output logic [BA_W-1:0]   dram_ba,
  output logic [DA_W-1:0]   dram_addr,
  output logic              dram_wdata_valid,
  output logic [DQ_W-1:0]   dram_wdata,
  input  logic              dram_rdata_valid,
  input  logic [DQ_W-1:0]   dram_rdata,

  output logic              init_done
);

  localparam int QI_W = $clog2(QDEPTH);
  localparam int TMR_W = 8;
  typedef logic [TMR_W-1:0] tmr_t;

  // Timer reload values (cycles remaining before the dependent command may be
  // decided; a timer at 0 means the command can go out on the next cycle).
`ifdef BUG_TRCD_SHORT
  localparam int RCD_LOAD = T_RCD - 2;
`else
  localparam int RCD_LOAD = T_RCD - 1;
`endif
`ifdef BUG_TRFC_SHORT
  localparam int RFC_LOAD = T_RFC / 2 - 1;
`else
  localparam int RFC_LOAD = T_RFC - 1;
`endif
`ifdef BUG_WTR
  localparam int WR2RD_LOAD = T_CCD - 1;
`else
  localparam int WR2RD_LOAD = T_WR2RD - 1;
`endif
  localparam int RD2WR_LOAD = ((T_RD2WR > T_CCD) ? T_RD2WR : T_CCD) - 1;

  function automatic tmr_t dec(tmr_t t);
    return (t == '0) ? '0 : t - 1'b1;
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic tmr_t tmax(tmr_t cur, int load);
    return (cur > tmr_t'(load)) ? cur : tmr_t'(load);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic row_match(logic [ROW_W-1:0] open_r, logic [ROW_W-1:0] req_r);
`ifdef BUG_ROW_ALIAS
    return open_r[ROW_W-2:0] == req_r[ROW_W-2:0];
`else
    return open_r == req_r;
`endif
  endfunction

  // --------------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------------
  qentry_t           q          [NUM_BANKS][QDEPTH];
  logic [QCNT_W-1:0] q_cnt      [NUM_BANKS];

  bank_state_e       bank_state [NUM_BANKS];
  logic [ROW_W-1:0]  open_row   [NUM_BANKS];
  tmr_t              rcd_cnt    [NUM_BANKS];
  tmr_t              rp_cnt     [NUM_BANKS];
  tmr_t              rc_cnt     [NUM_BANKS];
  tmr_t              pre_cnt    [NUM_BANKS];
  logic [2:0]        bypass_cnt [NUM_BANKS];

  tmr_t              rrd_cnt, rd_cnt, wr_cnt, rfc_cnt, mrd_cnt;
  logic              last_cas_we;
  logic [BA_W-1:0]   rr_ptr;

  ref_state_e        ref_state;
  logic [$clog2(T_REFI)-1:0] refi_cnt;
  init_state_e       init_state;
  logic [$clog2(T_INIT)-1:0] init_cnt;

  // --------------------------------------------------------------------------
  // Per-bank request selection (FR-FCFS with same-address hazard check)
  // --------------------------------------------------------------------------
  logic [NUM_BANKS-1:0] row_open;
  logic [QDEPTH-1:0]    hit_v [NUM_BANKS];
  logic [QDEPTH-1:0]    haz_v [NUM_BANKS];
  logic [NUM_BANKS-1:0] b_valid, b_hit, b_we;
  logic [QI_W-1:0]      b_sel [NUM_BANKS];
  logic [NUM_BANKS-1:0] cas_ok, act_ok, pre_ok;

  always_comb begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      row_open[b] = (bank_state[b] == B_ACTIVE) || (bank_state[b] == B_ACTIVATING);
      for (int i = 0; i < QDEPTH; i++) begin
        hit_v[b][i] = (QCNT_W'(i) < q_cnt[b]) && row_open[b] &&
                      row_match(open_row[b], q[b][i].row);
        haz_v[b][i] = 1'b0;
`ifndef BUG_RAW_HAZARD
        for (int j = 0; j < i; j++)
          if (q[b][j].row == q[b][i].row && q[b][j].col == q[b][i].col)
            haz_v[b][i] = 1'b1;
`endif
      end
    end
  end

  logic          f_pref, f_any;
  logic [QI_W-1:0] i_pref, i_any;

  always_comb begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      f_pref = 1'b0; f_any = 1'b0; i_pref = '0; i_any = '0;
      // Descending scan so that the lowest (oldest) eligible index wins.
      for (int i = QDEPTH - 1; i >= 0; i--) begin
        if (hit_v[b][i] && !haz_v[b][i]) begin
          f_any = 1'b1; i_any = QI_W'(i);
          if (q[b][i].we == last_cas_we) begin
            f_pref = 1'b1; i_pref = QI_W'(i);
          end
        end
      end
      b_valid[b] = (q_cnt[b] != '0);
      if (bypass_cnt[b] >= 3'(MAX_BYPASS)) b_sel[b] = '0;
      else if (f_pref)                     b_sel[b] = i_pref;
      else if (f_any)                      b_sel[b] = i_any;
      else                                 b_sel[b] = '0;
      b_hit[b] = hit_v[b][b_sel[b]];
      b_we[b]  = q[b][b_sel[b]].we;

      cas_ok[b] = b_valid[b] && b_hit[b] && (bank_state[b] == B_ACTIVE) &&
                  (b_we[b] ? (wr_cnt == '0) : (rd_cnt == '0));
      act_ok[b] = b_valid[b] && (bank_state[b] == B_IDLE) &&
                  (rc_cnt[b] == '0) && (rrd_cnt == '0);
      pre_ok[b] = b_valid[b] && (bank_state[b] == B_ACTIVE) && !b_hit[b] &&
                  (pre_cnt[b] == '0);
    end
  end

  // --------------------------------------------------------------------------
  // Refresh bookkeeping
  // --------------------------------------------------------------------------
  logic any_open, all_idle, all_open_ready;
  logic [2:0] open_cnt;
  logic ref_due;

  always_comb begin
    any_open = 1'b0; all_idle = 1'b1; all_open_ready = 1'b1; open_cnt = '0;
    for (int b = 0; b < NUM_BANKS; b++) begin
      if (row_open[b]) begin
        any_open = 1'b1;
        open_cnt = open_cnt + 3'd1;
      end
      if (bank_state[b] != B_IDLE) all_idle = 1'b0;
      if (bank_state[b] == B_ACTIVATING) all_open_ready = 1'b0;
      if (bank_state[b] == B_ACTIVE && pre_cnt[b] != '0) all_open_ready = 1'b0;
    end
  end

  logic iss_cas;   // forward declaration (driven by the issue logic below)

  always_comb begin
    ref_due = (init_state == I_DONE) && (refi_cnt == ($clog2(T_REFI))'(T_REFI - 1));
`ifdef BUG_REF_DROP
    // Refresh tick is a pulse; it is lost if the scheduler is busy issuing a
    // column command in the same cycle.
    if (iss_cas) ref_due = 1'b0;
`endif
  end

  // --------------------------------------------------------------------------
  // Command issue (decided this cycle, driven on the bus next cycle)
  // --------------------------------------------------------------------------
  dram_cmd_e       iss_cmd;
  logic [BA_W-1:0] iss_ba;
  logic [DA_W-1:0] iss_addr;
  logic [QI_W-1:0] iss_idx;
  logic            found;
  logic [BA_W-1:0] bk;
  /* verilator lint_off UNUSEDSIGNAL */
  qentry_t         iss_entry;   // only wdata/id feed the data path
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    iss_cmd  = CMD_DES;
    iss_ba   = '0;
    iss_addr = '0;
    iss_idx  = '0;
    iss_cas  = 1'b0;
    found    = 1'b0;
    bk       = '0;

    if (init_state == I_WAIT && init_cnt == ($clog2(T_INIT))'(T_INIT - 1)) begin
      iss_cmd  = CMD_MRS;
      iss_addr = mrs_value(CL, CWL);
    end else if (init_state == I_DONE) begin
      unique case (ref_state)
        R_DRAIN: begin
          if (any_open) begin
            if (all_open_ready) begin
`ifdef BUG_REF_SKIP_PRE
              // "Optimization": a single open bank is closed by the FSM
              // without spending a PREA slot.
              if (open_cnt != 3'd1) begin
`else
              begin
`endif
                iss_cmd       = CMD_PRE;
                iss_addr[A10] = 1'b1;
              end
            end
          end else if (all_idle) begin
            iss_cmd = CMD_REF;
          end
        end
        R_PREA_WAIT: begin
`ifdef BUG_PREA_TRP
          iss_cmd = CMD_REF;
`else
          if (all_idle) iss_cmd = CMD_REF;
`endif
        end
        R_REFRESH: ;
        R_IDLE: begin
          if (rfc_cnt == '0) begin
            // Column commands first (round-robin)
            for (int k = 0; k < NUM_BANKS; k++) begin
              bk = rr_ptr + BA_W'(k);
              if (!found && cas_ok[bk]) begin
                found    = 1'b1;
                iss_cas  = 1'b1;
                iss_cmd  = b_we[bk] ? CMD_WR : CMD_RD;
                iss_ba   = bk;
                iss_idx  = b_sel[bk];
                iss_addr = DA_W'(q[bk][b_sel[bk]].col);
              end
            end
            // Then row commands
            for (int k = 0; k < NUM_BANKS; k++) begin
              bk = rr_ptr + BA_W'(k);
              if (!found && (act_ok[bk] || pre_ok[bk])) begin
                found  = 1'b1;
                iss_ba = bk;
                if (act_ok[bk]) begin
                  iss_cmd  = CMD_ACT;
                  iss_addr = DA_W'(q[bk][b_sel[bk]].row);
                end else begin
                  iss_cmd  = CMD_PRE;
                end
              end
            end
          end
        end
        default: ;
      endcase
    end
    iss_entry = q[iss_ba][iss_idx];
  end

  // --------------------------------------------------------------------------
  // Host request acceptance
  // --------------------------------------------------------------------------
  logic [BA_W-1:0] req_ba;
  logic            push;
  assign req_ba    = addr_ba(req_addr);
  assign req_ready = (init_state == I_DONE) && (q_cnt[req_ba] < QCNT_W'(QDEPTH));
  assign push      = req_valid && req_ready;
  assign init_done = (init_state == I_DONE);

  // --------------------------------------------------------------------------
  // Request queues (payload storage needs no reset)
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      if (iss_cas && iss_ba == BA_W'(b)) begin
        for (int i = 0; i < QDEPTH - 1; i++)
          if (i >= int'(iss_idx)) q[b][i] <= q[b][i+1];
      end
      if (push && req_ba == BA_W'(b)) begin
`ifdef BUG_QUEUE_PUSHPOP
        q[b][q_cnt[b][QI_W-1:0]] <= '{req_we, addr_row(req_addr), addr_col(req_addr), req_wdata, req_id};
`else
        q[b][QI_W'(q_cnt[b] - QCNT_W'(iss_cas && iss_ba == BA_W'(b)))] <=
          '{req_we, addr_row(req_addr), addr_col(req_addr), req_wdata, req_id};
`endif
      end
    end
  end

  // --------------------------------------------------------------------------
  // Sequential control
  // --------------------------------------------------------------------------
  logic [NUM_BANKS-1:0] is_act, is_pre, is_rd, is_wr;

  always_comb begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      is_act[b] = (iss_cmd == CMD_ACT) && (iss_ba == BA_W'(b));
      is_pre[b] = (iss_cmd == CMD_PRE) && (iss_addr[A10] || iss_ba == BA_W'(b));
      is_rd[b]  = (iss_cmd == CMD_RD)  && (iss_ba == BA_W'(b));
      is_wr[b]  = (iss_cmd == CMD_WR)  && (iss_ba == BA_W'(b));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      {dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n} <= CMD_DES;
      dram_ba     <= '0;
      dram_addr   <= '0;
      rrd_cnt     <= '0;
      rd_cnt      <= '0;
      wr_cnt      <= '0;
      rfc_cnt     <= '0;
      mrd_cnt     <= '0;
      last_cas_we <= 1'b0;
      rr_ptr      <= '0;
      ref_state   <= R_IDLE;
      refi_cnt    <= '0;
      init_state  <= I_WAIT;
      init_cnt    <= '0;
      for (int b = 0; b < NUM_BANKS; b++) begin
        q_cnt[b]      <= '0;
        bank_state[b] <= B_IDLE;
        open_row[b]   <= '0;
        rcd_cnt[b]    <= '0;
        rp_cnt[b]     <= '0;
        rc_cnt[b]     <= '0;
        pre_cnt[b]    <= '0;
        bypass_cnt[b] <= '0;
      end
    end else begin
      {dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n} <= iss_cmd;
      dram_ba   <= iss_ba;
      dram_addr <= iss_addr;

      // ---------------- init
      unique case (init_state)
        I_WAIT: begin
          if (iss_cmd == CMD_MRS) begin
            init_state <= I_MRD;
            mrd_cnt    <= tmr_t'(T_MRD - 1);
          end else begin
            init_cnt <= init_cnt + 1'b1;
          end
        end
        I_MRD: begin
          mrd_cnt <= dec(mrd_cnt);
          if (mrd_cnt <= tmr_t'(1)) init_state <= I_DONE;
        end
        default: ;
      endcase

      // ---------------- refresh
      if (init_state == I_DONE)
        refi_cnt <= (refi_cnt == ($clog2(T_REFI))'(T_REFI - 1)) ? '0 : refi_cnt + 1'b1;

      unique case (ref_state)
        R_IDLE:      if (ref_due) ref_state <= R_DRAIN;
        R_DRAIN:     if (iss_cmd == CMD_PRE) ref_state <= R_PREA_WAIT;
                     else if (iss_cmd == CMD_REF) ref_state <= R_REFRESH;
        R_PREA_WAIT: if (iss_cmd == CMD_REF) ref_state <= R_REFRESH;
        R_REFRESH:   if (rfc_cnt <= tmr_t'(1)) ref_state <= R_IDLE;
        default: ;
      endcase

      // ---------------- global timers
      rrd_cnt <= (iss_cmd == CMD_ACT) ? tmr_t'(T_RRD - 1) : dec(rrd_cnt);
      rfc_cnt <= (iss_cmd == CMD_REF) ? tmr_t'(RFC_LOAD)  : dec(rfc_cnt);
      if (iss_cmd == CMD_RD) begin
        rd_cnt <= tmax(dec(rd_cnt), T_CCD - 1);
        wr_cnt <= tmax(dec(wr_cnt), RD2WR_LOAD);
      end else if (iss_cmd == CMD_WR) begin
        wr_cnt <= tmax(dec(wr_cnt), T_CCD - 1);
        rd_cnt <= tmax(dec(rd_cnt), WR2RD_LOAD);
      end else begin
        rd_cnt <= dec(rd_cnt);
        wr_cnt <= dec(wr_cnt);
      end
      if (iss_cas) last_cas_we <= (iss_cmd == CMD_WR);
      if (iss_cmd inside {CMD_ACT, CMD_RD, CMD_WR} || (iss_cmd == CMD_PRE && !iss_addr[A10]))
        rr_ptr <= iss_ba + 1'b1;

      // ---------------- per-bank state
      for (int b = 0; b < NUM_BANKS; b++) begin
        q_cnt[b] <= q_cnt[b] - QCNT_W'(is_rd[b] || is_wr[b])
                             + QCNT_W'(push && req_ba == BA_W'(b));

        rcd_cnt[b] <= is_act[b] ? tmr_t'(RCD_LOAD) : dec(rcd_cnt[b]);
        rc_cnt[b]  <= is_act[b] ? tmr_t'(T_RC - 1) : dec(rc_cnt[b]);
        rp_cnt[b]  <= (is_pre[b] && bank_state[b] == B_ACTIVE) ? tmr_t'(T_RP - 1) : dec(rp_cnt[b]);

        if (is_act[b])
`ifdef BUG_TRAS_IGNORED
          pre_cnt[b] <= dec(pre_cnt[b]);
`else
          pre_cnt[b] <= tmax(dec(pre_cnt[b]), T_RAS - 1);
`endif
        else if (is_rd[b]) pre_cnt[b] <= tmax(dec(pre_cnt[b]), T_RTP - 1);
        else if (is_wr[b]) pre_cnt[b] <= tmax(dec(pre_cnt[b]), T_WR2PRE - 1);
        else            pre_cnt[b] <= dec(pre_cnt[b]);

        if (is_rd[b] || is_wr[b])
          bypass_cnt[b] <= (iss_idx != '0) ? bypass_cnt[b] + 3'd1 : 3'd0;

        if (is_act[b]) begin
          bank_state[b] <= (RCD_LOAD == 0) ? B_ACTIVE : B_ACTIVATING;
          open_row[b]   <= iss_addr[ROW_W-1:0];
        end else if (is_pre[b] && bank_state[b] == B_ACTIVE) begin
          bank_state[b] <= B_PRECHARGING;
        end else if (bank_state[b] == B_ACTIVATING && rcd_cnt[b] <= tmr_t'(1)) begin
          bank_state[b] <= B_ACTIVE;
        end else if (bank_state[b] == B_PRECHARGING && rp_cnt[b] <= tmr_t'(1)) begin
          bank_state[b] <= B_IDLE;
        end
`ifdef BUG_REF_SKIP_PRE
        else if (ref_state == R_DRAIN && open_cnt == 3'd1 && all_open_ready &&
                 bank_state[b] == B_ACTIVE) begin
          bank_state[b] <= B_IDLE;
        end
`endif
      end
    end
  end

  // --------------------------------------------------------------------------
  // Data path: write data at +CWL, read capture at +CL
  // --------------------------------------------------------------------------
  logic [CWL:0]    wp_v;
  logic [DQ_W-1:0] wp_d  [CWL+1];
  logic [ID_W-1:0] wp_id [CWL+1];
  logic [CL:0]     rp_v;
  logic [ID_W-1:0] rp_id [CL+1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp_v     <= '0;
      rp_v     <= '0;
      rd_valid <= 1'b0;
    end else begin
      wp_v <= {wp_v[CWL-1:0], iss_cmd == CMD_WR};
      rp_v <= {rp_v[CL-1:0],  iss_cmd == CMD_RD};
      rd_valid <= rp_v[CL];
    end
  end

  always_ff @(posedge clk) begin
    wp_d[0]  <= iss_entry.wdata;
    wp_id[0] <= iss_entry.id;
    rp_id[0] <= iss_entry.id;
    for (int k = 1; k <= CWL; k++) begin
      wp_d[k]  <= wp_d[k-1];
      wp_id[k] <= wp_id[k-1];
    end
    for (int k = 1; k <= CL; k++)
      rp_id[k] <= rp_id[k-1];
    rd_id   <= rp_id[CL];
    rd_data <= dram_rdata;
  end

  assign dram_wdata_valid = wp_v[CWL];
  assign dram_wdata       = wp_d[CWL];
  assign wr_ack_valid     = wp_v[CWL];
  assign wr_ack_id        = wp_id[CWL];

  // Read capture is latency-calibrated (no strobe tracking); exposed so the
  // white-box checker can confirm the DRAM drove data in the capture cycle.
  /* verilator lint_off UNUSEDSIGNAL */
  logic rd_strobe_miss;
  /* verilator lint_on UNUSEDSIGNAL */
  assign rd_strobe_miss = rp_v[CL] && !dram_rdata_valid;

endmodule
