`timescale 1ns/1ps

// ultra_sd_line against the behavioural card, on the DAT lines only.
//
// WHY THIS TEST EXISTS
//
// There is a hole between two tests that both pass:
//
//   tb_ultra_sd_line   drives u_line against stimulus written in the same
//                      testbench. It proves u_line is self-consistent.
//   tb_sd_card_model   drives the card model from a real ultra_sd_cmd, but
//                      there is no u_line in it at all -- only the CMD line.
//
// So u_line and sd_card_model have never been connected to each other, and the
// first thing that did connect them (the init ladder's 8-byte SCR read, through
// the whole chain) came back with a CRC16 failure and the frame shifted by one
// byte. Neither existing test can see that, because neither contains both ends.
//
// This test is that seam, and nothing else: no init, no block layer, no AXI. The
// CMD line is bit-banged by the testbench, so the command engine is out of the
// picture too -- what is left is exactly "u_line reads/writes a frame, the card
// model writes/reads the same frame", which is the one thing in question.
//
// IT RUNS TWICE, AND THAT IS THE POINT
//
// Without `LINE_CARD_WITH_PHY, u_line sees the pads directly. With it, the real
// ultra_sd_phy_gowin sits in between, capturing DAT into a flop a programmable
// number of system clocks after the clock edge. The two differ by that capture
// latency, and a frame that is correct one way and shifted the other localises
// the bug to the PHY rather than to the framing -- which is a distinction no
// amount of staring at a waveform of the full chain gives you quickly.
//
// FRAME SIZES ARE THE INTERESTING AXIS
//
// 512 bytes is what the block layer always asks for, so it is the well-trodden
// path. 8 bytes (ACMD51 SCR) and 64 bytes (CMD6 switch status) are what the init
// ladder asks for, they only ever run in 1-bit mode, and they are short enough
// that an off-by-one at the start of the frame eats a meaningful fraction of the
// payload instead of hiding in the middle of a block.
module tb_line_card;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 8;
  localparam logic [15:0] CARD_RCA = 16'h1234;

  // 25 MHz on the DAT lines. Fast enough to keep the run short, slow enough that
  // the PHY variant below has room for a sampling phase.
  localparam real SD_HALF = 20.0;

  logic sd_clk_src = 0;      // the tb's own clock, before any division
  logic rst_n      = 1;      // starts HIGH: the negedge below is the reset

  always #(SD_HALF) sd_clk_src = ~sd_clk_src;

  int checks, failures;

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  // ===========================================================================
  // Pads
  // ===========================================================================
  tri1       sd_cmd;
  tri1 [3:0] sd_dat;

  // The testbench owns CMD. Driven on the falling edge so the bit is settled
  // across the rising edge the card samples on.
  logic cmd_oe  = 1'b0;
  logic cmd_out = 1'b1;
  assign sd_cmd = cmd_oe ? cmd_out : 1'bz;

  // ===========================================================================
  // Clocking, and the DAT path between u_line and the pads
  //
  // Two wirings of the same logic, selected at compile time. Everything the
  // testbench drives is identical in both.
  // ===========================================================================
  logic [3:0] dat_out, dat_oe, dat_in;
  logic       line_clk;
  logic       sd_clk;        // what the CARD sees

`ifdef LINE_CARD_WITH_PHY
  // The real PHY in the loop. The divider now lives inside it, so the tb
  // supplies a RATIO and a gate enable -- which is what system_controller does
  // on the board. Divide by 2 so the PHY has two sampling phases to choose
  // from, exactly as at the 50 MHz operating point (constr/ultra_sd.sdc
  // section 6).
  localparam logic [CFG_CLK_W-1:0] PHY_DIV = CFG_CLK_W'(2);

  logic [CFG_PHY_W-1:0] cfg_phy;
  logic [3:0]           phy_dat_in;
  logic                 phy_cmd_in;

  ultra_sd_phy_gowin u_phy (
    .clk             (sd_clk_src),
    .rst_n           (rst_n),
    .cfg_phy_i       (cfg_phy),
    .clk_div_i       (PHY_DIV),
    .cmd_clk_en_i    (1'b1),
    .line_clk_en_i   (1'b1),
    .pad_line_sel_i  (1'b1),        // the pad clock follows the DAT channel
    .cmd_clk_o       (),
    .line_clk_o      (line_clk),
    .cmd_out_i       (1'b1),
    .cmd_oe_i        (1'b0),        // the tb drives CMD on the pad directly
    .cmd_in_o        (phy_cmd_in),
    .dat_out_i       (dat_out),
    .dat_oe_i        (dat_oe),
    .dat_in_o        (phy_dat_in),
    .sd_clk          (sd_clk),
    .sd_cmd          (sd_cmd),
    .sd_dat          (sd_dat)
  );

  assign dat_in = phy_dat_in;
`else
  // No PHY: u_line sees the pads, and the card's clock is the tb's clock. This
  // is the wiring tb_ultra_sd_line and the block-layer tests use.
  assign line_clk = sd_clk_src;
  assign sd_clk   = sd_clk_src;

  for (genvar d = 0; d < SD_DATA_LANES; d++) begin : g_pad
    assign sd_dat[d] = dat_oe[d] ? dat_out[d] : 1'bz;
  end
  assign dat_in = sd_dat;
`endif

  // ===========================================================================
  // The DAT engine under test
  // ===========================================================================
  logic bus_wide;
  logic                     dir, start;
  logic [10:0]              xfer_bytes;

  logic [31:0] tx_data;
  logic        tx_take, tx_done, tx_status_ok, tx_status_tmo;
  logic [31:0] rx_data;
  logic        rx_valid, rx_busy, rx_done, rx_crc_ok;

  logic        stat_clear_tgl = 1'b0;
  logic [31:0] stat_data_cnt, stat_busy_cnt;

  ultra_sd_line #(.XFER_BYTES(BLOCK_BYTES)) u_line (
    .line_clk        (line_clk),
    .rst_n           (rst_n),
    .bus_wide_i      (bus_wide),
    .stat_clear_tgl_i (stat_clear_tgl),
    .stat_data_o     (stat_data_cnt),
    .stat_busy_o     (stat_busy_cnt),
    .dir_i           (dir),
    .start_i         (start),
    .xfer_bytes_i    (xfer_bytes),
    .tx_data_i       (tx_data),
    .tx_take_o       (tx_take),
    .tx_busy_o       (),
    .tx_done_o       (tx_done),
    .tx_status_o     (),
    .tx_status_ok_o  (tx_status_ok),
    .tx_status_tmo_o (tx_status_tmo),
    .rx_data_o       (rx_data),
    .rx_valid_o      (rx_valid),
    .rx_busy_o       (rx_busy),
    .rx_done_o       (rx_done),
    .rx_crc_ok_o     (rx_crc_ok),
    .dat_active_o    (),
    .card_busy_o     (),
    .dat_out_o       (dat_out),
    .dat_oe_o        (dat_oe),
    .dat_in_i        (dat_in)
  );

  // ===========================================================================
  // The card
  // ===========================================================================
  logic card_protocol_err;

  sd_card_model #(
    .BLOCK_COUNT       (CARD_BLOCKS),
    .NCR_DELAY_CYCLES  (2),
    .NAC_DELAY_CYCLES  (4),
    .WRITE_BUSY_CYCLES (8),
    .ACMD41_BUSY_POLLS (1),
    .RCA               (CARD_RCA)
  ) u_card (
    .sd_clk               (sd_clk),
    .rst_n                (rst_n),
    .card_present_i       (1'b1),
    .sd_cmd               (sd_cmd),
    .sd_dat               (sd_dat),
    .inject_cmd_timeout_i (1'b0),
    .inject_cmd_crc_i     (1'b0),
    .inject_data_crc_i    (1'b0),
    .inject_write_crc_i   (1'b0),
    .inject_busy_stuck_i  (1'b0),
    .protocol_error_o     (card_protocol_err),
    .last_cmd_o           (),
    .command_count_o      (),
    .bus_4bit_o           (),
    .high_speed_o         ()
  );

  // ===========================================================================
  // Bit-banged command issue
  // ===========================================================================
  function automatic logic [6:0] crc7_40(input logic [39:0] value);
    logic [6:0] crc;
    logic       fb;
    crc = 7'h00;
    for (int i = 39; i >= 0; i--) begin
      fb  = crc[6] ^ value[i];
      crc = {crc[5:0], 1'b0} ^ (fb ? CRC7_POLY : 7'h00);
    end
    return crc;
  endfunction

  task automatic send_cmd(input logic [5:0] index, input logic [31:0] argument);
    logic [39:0] header;
    logic [47:0 ] frame;
    header = {1'b0, 1'b1, index, argument};   // start = 0, host -> card
    frame  = {header, crc7_40(header), 1'b1};
    @(negedge sd_clk);
    cmd_oe = 1'b1;
    for (int i = 47; i >= 0; i--) begin
      cmd_out = frame[i];
      @(negedge sd_clk);
    end
    cmd_oe  = 1'b0;
    cmd_out = 1'b1;

    // WAIT FOR THE CARD TO FINISH ANSWERING BEFORE RETURNING.
    //
    // Four clocks is enough for the card to DECODE the command and nowhere near
    // enough for it to ANSWER one. The card drives a 48-bit response starting
    // NCR_DELAY_CYCLES after the frame, so a caller that sends another command
    // straight away -- send_acmd is exactly that, CMD55 then the application
    // command -- drives CMD while the card is still driving it. The net is a
    // tri1: both ends win nothing, the card's own receiver sees a malformed
    // frame, sets protocol_error_o, and decodes no command at all. Downstream
    // that reads as a card which ignored an ACMD, an engine left armed for a
    // frame that never came, and a 4-bit write coming back nibble-swapped
    // because the ACMD6 that was supposed to widen the bus never landed.
    //
    // The real command engine does not have this bug: ultra_sd_cmd waits for the
    // response and then an Ncc gap before the next frame. This task has to model
    // that, not approximate it.
    begin
      int t;
      // Give the card its Ncr to start driving. A command with no response --
      // CMD0 -- never does, and falls through on the timeout.
      t = 0;
      while (!u_card.cmd_oe_q && (t < 16)) begin
        @(negedge sd_clk); t++;
      end
      // Then let it finish.
      t = 0;
      while (u_card.cmd_oe_q && (t < 128)) begin
        @(negedge sd_clk); t++;
      end
      check(t < 128, "card released CMD after its response");
    end

    // Ncc: the minimum gap between one command and the next.
    repeat (8) @(negedge sd_clk);
  endtask

  // CMD55 + the application command, which is how every ACMD reaches the card.
  task automatic send_acmd(input logic [5:0] index, input logic [31:0] argument);
    send_cmd(CMD55_APP_CMD, {CARD_RCA, 16'h0000});
    send_cmd(index, argument);
  endtask

  // ===========================================================================
  // Expected payload
  //
  // The card model's three read sources, mirrored here. Kept as one function so
  // a disagreement about WHICH bytes were expected cannot be confused with a
  // disagreement about the framing around them.
  // ===========================================================================
  localparam int KIND_STORAGE = 0;
  localparam int KIND_SCR     = 1;
  localparam int KIND_SWITCH  = 2;

  function automatic logic [7:0] expect_byte(input int kind,
                                             input int lba,
                                             input int offset);
    case (kind)
      KIND_SCR: begin
        // SD_SPEC = 2, then 1-bit and 4-bit both supported.
        if (offset == 0)      return 8'h02;
        else if (offset == 1) return 8'h05;
        else                  return 8'h00;
      end
      KIND_SWITCH: return (offset == 16) ? 8'h01 : 8'h00;
      default:     return u_card.read_byte(((lba % CARD_BLOCKS) * BLOCK_BYTES) + offset);
    endcase
  endfunction

  // Per-edge trace of the two ends, off unless asked for: +lcdbg. The card's
  // DAT driver state and the engine's cell state side by side are what place a
  // frame that never arrives -- the card not starting, or the engine not
  // listening, look identical from the payload counter alone.
  int lc_card = -1, lc_cell = -1;
  always @(posedge sd_clk_src) begin
    if (rst_n && $test$plusargs("lcdbg") &&
        ((int'(u_card.dat_tx_state_q) != lc_card) || (int'(u_line.cell_q) != lc_cell))) begin
      $display("      [%0t] card_dat=%0d cell=%0d seg=%0d wide=%0b oe=%b busy=%b valid=%b done=%b crcok=%b",
               $time, u_card.dat_tx_state_q, u_line.cell_q, u_line.seg_q,
               bus_wide, u_card.dat_oe_q, rx_busy, rx_valid, rx_done, rx_crc_ok);
      lc_card = int'(u_card.dat_tx_state_q);
      lc_cell = int'(u_line.cell_q);
    end
  end

  // Raw DAT nibbles for the first cycles of a frame: what the card drives, in
  // its own group order, next to what lands in the engine. A frame that arrives
  // misaligned shows the offset directly instead of through assembled words.
  int lc_nib = 0;
  always @(posedge sd_clk_src) begin
    if (rst_n && $test$plusargs("lcnib") && rx_busy && (lc_nib < 24)) begin
      $display("      [nib %0d] dat=%b group=%0d card_dat=%0d cell=%0d seg=%0d valid=%b data=%08h",
               lc_nib, sd_dat, u_card.rd_group_q, u_card.dat_tx_state_q,
               u_line.cell_q, u_line.seg_q, rx_valid, rx_data);
      lc_nib <= lc_nib + 1;
    end
    if (!rx_busy) lc_nib <= 0;
  end

  // When the card QUEUES a read and when it finally starts driving it. A frame
  // that arrives one command late shows up here as a queue time and a start
  // time with a command in between.
  logic lc_q_d;
  always @(posedge sd_clk_src) begin
    if (!rst_n) lc_q_d <= 1'b0;
    else begin
      lc_q_d <= u_card.read_queued_q;
      if ($test$plusargs("lcdbg")) begin
        if (u_card.read_queued_q && !lc_q_d)
          $display("      [%0t] QUEUE  kind=%0d len=%0d lba=%0d  resp_pend=%b cmd_oe=%b",
                   $time, u_card.read_kind_q, u_card.read_length_q,
                   u_card.read_lba_q, u_card.resp_pending_q, u_card.cmd_oe_q);
        if (!u_card.read_queued_q && lc_q_d)
          $display("      [%0t] START  kind=%0d len=%0d",
                   $time, u_card.rd_kind_active_q, u_card.rd_length_active_q);
      end
    end
  end

  // ===========================================================================
  // One read frame, checked word by word
  //
  // WORD_LITTLE_ENDIAN = 1, so the first byte on the wire is bits [7:0] of the
  // first word. Getting that backwards would look exactly like a corrupted card,
  // which is why it is spelled out rather than assumed.
  // ===========================================================================
  // ARM FIRST, THEN COMMAND. ultra_sd_block does it in this order and has to:
  // S_RD_ARM raises dat_start_o and only then S_CMD issues the read, because the
  // card begins driving the data frame NAC cycles after its response and will
  // not wait for a receiver that is not listening yet. A test that sends the
  // command first and arms afterwards races the card for the start bit -- and
  // loses it in 4-bit, where the frame is four times shorter in cycles.
  //
  // So the command is issued HERE rather than by the caller.
  task automatic do_read(input string      name,
                         input int         kind,
                         input int         lba,
                         input int         nbytes,
                         input logic [3:0] lanes,
                         input logic [5:0] index,
                         input logic [31:0] argument,
                         input bit          as_acmd);
    int          words;
    int          got;
    int          timeout;
    logic [31:0] expect_word;
    logic        word_ok;

    words = nbytes / 4;
    got   = 0;

    bus_wide   = (lanes == 4'b1111);
    dir        = 1'b0;
    xfer_bytes = 11'(nbytes);

    @(negedge line_clk);
    start = 1'b1;
    // start_i is a level held until the engine acknowledges by going busy.
    timeout = 0;
    while (!rx_busy && (timeout < 64)) begin
      @(negedge line_clk); timeout++;
    end
    check(timeout < 64, $sformatf("%s: engine accepted the read request", name));
    start = 1'b0;

    // Listening now, so ask for the data.
    if (as_acmd) send_acmd(index, argument);
    else         send_cmd (index, argument);

    // Collect the payload. The frame is bounded, so a word that never arrives is
    // a hang rather than a wrong value, and the timeout has to be generous
    // enough to cover the card's Nac delay.
    timeout = 0;
    while ((got < words) && (timeout < 20 * nbytes + 2000)) begin
      @(posedge line_clk);
      #1;
      if (rx_valid) begin
        expect_word = {expect_byte(kind, lba, got*4 + 3),
                       expect_byte(kind, lba, got*4 + 2),
                       expect_byte(kind, lba, got*4 + 1),
                       expect_byte(kind, lba, got*4 + 0)};
        word_ok = (rx_data == expect_word);
        if (!word_ok)
          $display("      %s: word %0d expected %08h got %08h",
                   name, got, expect_word, rx_data);
        check(word_ok, $sformatf("%s: payload word %0d", name, got));
        got++;
      end
      timeout++;
    end
    check(got == words,
          $sformatf("%s: received %0d of %0d payload words", name, got, words));

    // rx_done may already have fired alongside the last word.
    timeout = 0;
    while (!rx_done && (timeout < 64)) begin
      @(posedge line_clk); #1; timeout++;
    end
    check(rx_done,    $sformatf("%s: frame completed", name));
    check(rx_crc_ok,  $sformatf("%s: CRC16 verified", name));
    repeat (8) @(negedge line_clk);
  endtask

  // ===========================================================================
  // One write frame, checked against what the card actually stored
  // ===========================================================================
  logic [31:0] wr_words [128];
  int          wr_idx;

  // FWFT: the next word must be presented before it is taken.
  assign tx_data = wr_words[wr_idx];

  task automatic do_write(input string      name,
                          input int         lba,
                          input int         nbytes,
                          input logic [3:0] lanes);
    int   timeout;
    int   words;
    logic byte_ok;
    logic load_seen;

    words  = nbytes / 4;
    wr_idx = 0;
    for (int w = 0; w < words; w++)
      wr_words[w] = {8'(w*4 + 3), 8'(w*4 + 2), 8'(w*4 + 1), 8'(w*4 + 0)} ^ 32'h5a5a_5a5a;

    send_cmd(CMD24_WRITE_BLOCK, 32'(lba));

    bus_wide   = (lanes == 4'b1111);
    dir        = 1'b1;
    xfer_bytes = 11'(nbytes);

    @(negedge line_clk);
    start = 1'b1;
    timeout = 0;
    load_seen = 1'b0;
    while (!tx_done && (timeout < 20 * nbytes + 4000)) begin
      @(negedge line_clk);
      // THE FIRST TAKE IS A LOAD, NOT A CONSUME.
      //
      // ultra_sd_line raises tx_take_o during CELL_ARM as well -- the start-bit
      // cell -- and uses it to latch the FIRST word into the shifter
      // (tx_sh_q <= word_swizzle(tx_data_i)). So that take must not advance the
      // source, or word 0 is replaced by word 1 before it is ever sent.
      //
      // ultra_sd_block does not have this problem because it gates on the state:
      // wr_en_o = (step_q == S_WR_DATA) && tx_take_i, and the arm-cell take
      // arrives while it is still in S_WR_ARM. This task has to make the same
      // distinction, and the symptom when it does not is subtle -- every word
      // shifts by one, the CRC16 the card checks is computed over what was
      // actually sent so the card ACCEPTS the block, and only a comparison
      // against the card's storage shows it.
      if (tx_take) begin
        if (!load_seen) load_seen = 1'b1;
        else if (wr_idx < words - 1) wr_idx++;
      end
      timeout++;
      if (timeout == 8) start = 1'b0;
    end
    start = 1'b0;
    check(tx_done,          $sformatf("%s: frame transmitted", name));
    check(!tx_status_tmo,   $sformatf("%s: card returned a CRC status token", name));
    check(tx_status_ok,     $sformatf("%s: card accepted the block", name));

    // The card has the data now; compare against its storage through the model's
    // documented backdoor rather than re-reading it over the bus, so a read bug
    // cannot mask a write bug.
    byte_ok = 1'b1;
    for (int b = 0; b < nbytes; b++) begin
      logic [7:0] want, have;
      want = wr_words[b/4][(b%4)*8 +: 8];
      have = u_card.read_byte(((lba % CARD_BLOCKS) * BLOCK_BYTES) + b);
      if (want !== have) begin
        if (byte_ok)
          $display("      %s: byte %0d expected %02h got %02h", name, b, want, have);
        byte_ok = 1'b0;
      end
    end
    check(byte_ok, $sformatf("%s: every payload byte reached card storage", name));
    repeat (8) @(negedge line_clk);
  endtask

  // ===========================================================================
  // Stimulus
  // ===========================================================================
  initial begin
    checks = 0; failures = 0;
    bus_wide = 1'b0; dir = 1'b0; start = 1'b0; xfer_bytes = 11'(BLOCK_BYTES);
    wr_idx = 0;
    for (int w = 0; w < 128; w++) wr_words[w] = '0;

`ifdef LINE_CARD_WITH_PHY
    // Phase 1 at divide-by-2: the pad is captured a system clock after the SD
    // edge rather than on it. constr/ultra_sd.sdc section 6 derives why this is
    // the correct phase at the fastest ratio.
    cfg_phy = CFG_PHY_W'(1);
    $display("-- ultra_sd_line + ultra_sd_phy_gowin + sd_card_model --");
`else
    $display("-- ultra_sd_line + sd_card_model, pads direct --");
`endif

    #1 rst_n = 0;
    repeat (8) @(negedge sd_clk_src);
    rst_n = 1;
    repeat (8) @(negedge sd_clk_src);

    // Put the card in the transfer state the way the real ladder does.
    send_cmd(CMD0_GO_IDLE_STATE, 32'h0);
    send_cmd(CMD7_SELECT_CARD, {CARD_RCA, 16'h0000});

    // ---- the init ladder's two short reads, both 1-bit ---------------------
    // These are the frames that failed through the full chain. They run before
    // ACMD6, so the bus really is 1 bit wide at this point -- that is not a
    // simplification of the test, it is the order the specification mandates.
    $display("-- 1/5 ACMD51: 8-byte SCR read, 1-bit --");
    do_read("SCR 8B 1-bit", KIND_SCR, 0, 8, 4'b0001,
            ACMD51_SEND_SCR, 32'h0, 1'b1);

    $display("-- 2/5 CMD6: 64-byte switch status, 1-bit --");
    do_read("SWITCH 64B 1-bit", KIND_SWITCH, 0, 64, 4'b0001,
            CMD6_SWITCH_FUNC, 32'h8000_0001, 1'b0);

    // ---- a full block, still 1-bit ----------------------------------------
    $display("-- 3/5 CMD17: 512-byte block read, 1-bit --");
    do_read("BLOCK 512B 1-bit", KIND_STORAGE, 2, BLOCK_BYTES, 4'b0001,
            CMD17_READ_SINGLE_BLOCK, 32'd2, 1'b0);

    // ---- widen the bus and do it again ------------------------------------
    $display("-- 4/5 ACMD6 then CMD17: 512-byte block read, 4-bit --");
    // ACMD6 widens the card; it carries no data frame, so it stays a plain
    // command and is not subject to the arm-first rule.
    send_acmd(ACMD6_SET_BUS_WIDTH, 32'h0000_0002);
    do_read("BLOCK 512B 4-bit", KIND_STORAGE, 3, BLOCK_BYTES, 4'b1111,
            CMD17_READ_SINGLE_BLOCK, 32'd3, 1'b0);

    // ---- and a write, which also exercises the CRC status token -----------
    $display("-- 5/5 CMD24: 512-byte block write, 4-bit --");
    do_write("WRITE 512B 4-bit", 4, BLOCK_BYTES, 4'b1111);

    check(!card_protocol_err, "card model saw no protocol violation");

    if (failures) begin
      $display("tb_line_card: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_line_card: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("line_card.vcd");
      $dumpvars(0, tb_line_card);
    end
  end

  // Nothing here should take anywhere near this long.
  initial begin
    #20_000_000;
    $display("FAIL: tb_line_card timed out");
    $display("tb_line_card: FAILED (%0d/%0d)", failures + 1, checks + 1);
    $fatal(1);
  end

endmodule
