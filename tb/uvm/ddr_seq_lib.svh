// ============================================================================
// Sequence library. Each sequence targets part of the coverage model; the
// mixed sequence interleaves all of them and is the regression workhorse.
// ============================================================================

class ddr_base_seq extends uvm_sequence #(ddr_txn);
  `uvm_object_utils(ddr_base_seq)

  int unsigned n = 100;       // number of requests to generate
  int unsigned sent;

  function new(string name = "ddr_base_seq");
    super.new(name);
  endfunction

  // Fully constrained request: sequence-chosen address/op, random data/pattern.
  task send(bit m_we, bit [BA_W-1:0] m_ba, bit [ROW_W-1:0] m_row, bit [COL_W-1:0] m_col,
            int m_gap = -1);
    ddr_txn t = ddr_txn::type_id::create("t");
    start_item(t);
    if (m_gap < 0) begin
      if (!t.randomize() with { we == m_we; ba == m_ba; row == m_row; col == m_col; })
        `uvm_fatal("RAND", "randomize failed")
    end else begin
      t.c_gap.constraint_mode(0);
      if (!t.randomize() with { we == m_we; ba == m_ba; row == m_row; col == m_col; gap == m_gap; })
        `uvm_fatal("RAND", "randomize failed")
    end
    // Guard against the simulator silently dropping inline constraints.
    if (t.we != m_we || t.ba != m_ba || t.row != m_row || t.col != m_col || (m_gap >= 0 && t.gap != m_gap))
      `uvm_fatal("RAND", $sformatf("inline constraints not honoured: %s gap=%0d", t.convert2string(), t.gap))
    finish_item(t);
    sent++;
  endtask

  function bit [ROW_W-1:0] rand_row();
    return ROW_W'($urandom);
  endfunction
endclass


// ----------------------------------------------------------------------------
// Constrained-random traffic over a hot working set (row hits + misses +
// conflicts, same-address reuse) with occasional far addresses.
// ----------------------------------------------------------------------------
class ddr_random_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_random_seq)
  function new(string name = "ddr_random_seq"); super.new(name); endfunction

  task body();
    repeat (n) begin
      ddr_hot_txn t = ddr_hot_txn::type_id::create("t");
      start_item(t);
      if (!t.randomize())
        `uvm_fatal("RAND", "randomize failed")
      finish_item(t);
      sent++;
    end
  endtask
endclass


// Streams of accesses to one open row (row hits, tCCD back-to-back).
class ddr_row_hit_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_row_hit_seq)
  function new(string name = "ddr_row_hit_seq"); super.new(name); endfunction

  task body();
    while (sent < n) begin
      bit [BA_W-1:0]  b = BA_W'($urandom);
      bit [ROW_W-1:0] r = ROW_W'($urandom_range(0, 15));
      int len = $urandom_range(4, 16);
      bit dir = $urandom_range(0, 1);
      int mode = $urandom_range(0, 2);    // 0: same direction, 1: alternate, 2: random
      for (int i = 0; i < len && sent < n; i++) begin
        bit we = (mode == 0) ? dir : (mode == 1) ? bit'(i[0]) : bit'($urandom_range(0, 1));
        send(we, b, r, COL_W'($urandom), 0);
      end
    end
  endtask
endclass


// Same bank, alternating rows: row conflicts, tRAS/tRC/tRP/tWR/tRTP edges.
class ddr_bank_conflict_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_bank_conflict_seq)
  function new(string name = "ddr_bank_conflict_seq"); super.new(name); endfunction

  task body();
    while (sent < n) begin
      bit [BA_W-1:0]  b = BA_W'($urandom);
      bit [ROW_W-1:0] rows [3];
      int len = $urandom_range(4, 12);
      foreach (rows[i]) rows[i] = rand_row();
      for (int i = 0; i < len && sent < n; i++) begin
        int burst = $urandom_range(1, 3);
        bit [ROW_W-1:0] r = rows[$urandom_range(0, 2)];
        for (int j = 0; j < burst && sent < n; j++)
          send($urandom_range(0, 1), b, r, COL_W'($urandom_range(0, 7)), $urandom_range(0, 3) == 0 ? 2 : 0);
      end
    end
  endtask
endclass


// A few addresses in one row hammered with mixed reads/writes: RAW/WAR/WAW
// hazards while the scheduler is tempted to reorder (direction preference).
class ddr_hazard_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_hazard_seq)
  function new(string name = "ddr_hazard_seq"); super.new(name); endfunction

  task body();
    while (sent < n) begin
      bit [BA_W-1:0]  b = BA_W'($urandom);
      bit [ROW_W-1:0] r = ROW_W'($urandom_range(0, 7));
      bit [COL_W-1:0] cols [3];
      int len = $urandom_range(6, 20);
      foreach (cols[i]) cols[i] = COL_W'($urandom);
      for (int i = 0; i < len && sent < n; i++) begin
        case ($urandom_range(0, 5))
          0, 1, 2: send($urandom_range(0, 1), b, r, cols[$urandom_range(0, 2)], 0);
          3:       send($urandom_range(0, 1), b, r, COL_W'($urandom), 0);           // same row, other column
          4:       send($urandom_range(0, 1), b, rand_row(), cols[0], 0);           // same column, other row
          default: send($urandom_range(0, 1), BA_W'($urandom), r, cols[0], 0);      // other bank
        endcase
      end
    end
  endtask
endclass


// Back-to-back command-bus stress: RD/WR turnarounds and multi-bank ACT trains.
class ddr_b2b_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_b2b_seq)
  function new(string name = "ddr_b2b_seq"); super.new(name); endfunction

  task body();
    bit [ROW_W-1:0] r [NUM_BANKS];
    foreach (r[i]) r[i] = ROW_W'($urandom_range(0, 3));
    while (sent < n) begin
      int len = $urandom_range(4, 16);
      case ($urandom_range(0, 3))
        0: for (int i = 0; i < len && sent < n; i++)   // reads across banks
             send(0, BA_W'(i), r[i % NUM_BANKS], COL_W'($urandom), 0);
        1: for (int i = 0; i < len && sent < n; i++)   // writes across banks
             send(1, BA_W'(i), r[i % NUM_BANKS], COL_W'($urandom), 0);
        2: for (int i = 0; i < len && sent < n; i++)   // alternating directions
             send(bit'(i[0]), BA_W'($urandom), r[$urandom_range(0, NUM_BANKS - 1)], COL_W'($urandom), 0);
        default: begin                                  // open new rows in every bank
          foreach (r[i]) r[i] = rand_row();
          for (int i = 0; i < NUM_BANKS && sent < n; i++)
            send($urandom_range(0, 1), BA_W'(i), r[i], COL_W'($urandom), 0);
        end
      endcase
    end
  endtask
endclass


// Dense bursts separated by idle windows so traffic straddles refresh at many
// different phases: refresh with open banks, full queues, data in flight.
// Occasional idle windows longer than tREFI let a refresh land on a fully
// idle device (open-page policy otherwise always leaves banks open).
class ddr_refresh_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_refresh_seq)
  function new(string name = "ddr_refresh_seq"); super.new(name); endfunction

  task body();
    while (sent < n) begin
      int len  = $urandom_range(8, 32);
      int idle = ($urandom_range(0, 9) == 0) ? $urandom_range(T_REFI + 10, 2 * T_REFI)
                                             : $urandom_range(0, 150);
      for (int i = 0; i < len && sent < n; i++)
        send($urandom_range(0, 1), BA_W'($urandom), ROW_W'($urandom_range(0, 5)), COL_W'($urandom_range(0, 15)),
             (i == 0) ? idle : 0);
    end
  endtask
endclass


// Row-address aliasing: conflicts between rows that differ in exactly one bit,
// for every row-address bit (catches comparator / decoder bit bugs).
class ddr_row_alias_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_row_alias_seq)
  function new(string name = "ddr_row_alias_seq"); super.new(name); endfunction

  task body();
    while (sent < n) begin
      int k = $urandom_range(0, ROW_W - 1);
      bit [BA_W-1:0]  b  = BA_W'($urandom);
      bit [ROW_W-1:0] r0 = rand_row();
      bit [ROW_W-1:0] r1 = r0 ^ (ROW_W'(1) << k);
      bit [COL_W-1:0] c  = COL_W'($urandom);
      send(1, b, r0, c, 0);
      send(1, b, r1, c, 0);
      send(0, b, r0, c, 0);
      send(0, b, r1, c, 0);
    end
  endtask
endclass


// Address and data corners.
class ddr_corner_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_corner_seq)
  function new(string name = "ddr_corner_seq"); super.new(name); endfunction

  task body();
    bit [ROW_W-1:0] rows [2] = '{'0, '1};
    bit [COL_W-1:0] cols [2] = '{'0, '1};
    while (sent < n) begin
      bit [BA_W-1:0]  b = BA_W'($urandom);
      bit [ROW_W-1:0] r = rows[$urandom_range(0, 1)];
      bit [COL_W-1:0] c = cols[$urandom_range(0, 1)];
      send(1, b, r, c);
      send(0, b, r, c);
    end
  endtask
endclass


// ----------------------------------------------------------------------------
// Mixed traffic: random interleaving of all sequences above, in chunks.
// ----------------------------------------------------------------------------
class ddr_mixed_seq extends ddr_base_seq;
  `uvm_object_utils(ddr_mixed_seq)
  function new(string name = "ddr_mixed_seq"); super.new(name); endfunction

  task body();
    while (sent < n) begin
      ddr_base_seq s;
      int chunk = $urandom_range(16, 96);
      randcase
        30: s = ddr_random_seq::type_id::create("random");
        12: s = ddr_row_hit_seq::type_id::create("row_hit");
        12: s = ddr_bank_conflict_seq::type_id::create("bank_conflict");
        14: s = ddr_hazard_seq::type_id::create("hazard");
        12: s = ddr_b2b_seq::type_id::create("b2b");
        10: s = ddr_refresh_seq::type_id::create("refresh");
         6: s = ddr_row_alias_seq::type_id::create("row_alias");
         4: s = ddr_corner_seq::type_id::create("corner");
      endcase
      s.n = (n - sent < chunk) ? n - sent : chunk;
      s.start(m_sequencer, this);
      sent += s.sent;
    end
  endtask
endclass
