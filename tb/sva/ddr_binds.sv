// ============================================================================
// Attach all checkers to every ddr_ctrl instance.
// ============================================================================
module ddr_binds;

  bind ddr_ctrl ddr_protocol_sva u_protocol_sva (
    .clk              (clk),
    .rst_n            (rst_n),
    .dram_cs_n        (dram_cs_n),
    .dram_ras_n       (dram_ras_n),
    .dram_cas_n       (dram_cas_n),
    .dram_we_n        (dram_we_n),
    .dram_ba          (dram_ba),
    .dram_addr        (dram_addr),
    .dram_wdata_valid (dram_wdata_valid),
    .dram_rdata_valid (dram_rdata_valid)
  );

  bind ddr_ctrl ddr_host_sva u_host_sva (
    .clk          (clk),
    .rst_n        (rst_n),
    .req_valid    (req_valid),
    .req_ready    (req_ready),
    .req_we       (req_we),
    .req_addr     (req_addr),
    .req_wdata    (req_wdata),
    .req_id       (req_id),
    .rd_valid     (rd_valid),
    .rd_id        (rd_id),
    .wr_ack_valid (wr_ack_valid),
    .wr_ack_id    (wr_ack_id)
  );

  bind ddr_ctrl ddr_ctrl_internal_sva u_internal_sva (
    .clk            (clk),
    .rst_n          (rst_n),
    .bank_state     (bank_state),
    .ref_state      (ref_state),
    .init_state     (init_state),
    .q_cnt          (q_cnt),
    .q              (q),
    .bypass_cnt     (bypass_cnt),
    .refi_cnt       (refi_cnt),
    .iss_cmd        (iss_cmd),
    .iss_ba         (iss_ba),
    .push           (push),
    .req_ba         (req_ba),
    .req_id         (req_id),
    .req_ready      (req_ready),
    .rd_strobe_miss (rd_strobe_miss)
  );

endmodule
