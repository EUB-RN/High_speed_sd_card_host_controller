// -----------------------------------------------------------------------------
// ultra_sd_block
//   L3: LBA siralamasi, blok akisi, toparlanma ve zaman asimlari.
//   Modul ici sorumluluklar temiz ve bagimsiz always bloklarina ayrilmistir:
//     1. Giris senkronizasyonu ve on-denetim
//     2. Blok ve adres takibi (LBA, blok sayaci, retry bütçesi)
//     3. Komut uretimi ve el sikismasi (CMD17/18, CMD24/25, CMD12, ACMD23, CMD13)
//     4. Veri hatti (Line) kontrolu ve arm yonetimi
//     5. Zaman asimi (Timeout) sayaci
//     6. Ana islem FSM'i (step_q / post_q / drop_q / stopped_q)
//     7. FIFO arayuzu (rd/wr veri, commit ve rewind)
//     8. Istatistik sayaclari (STAT_GAP, STAT_RETRY_CRC)
// -----------------------------------------------------------------------------

module ultra_sd_block #(
  parameter int DATA_W           = 32,
  parameter int CRC_RETRIES      = 3,
  parameter int NAC_TIMEOUT_CLK  = 5_000_000,
  parameter int PROG_TIMEOUT_CLK = 25_000_000
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              soft_clr,   // SENKRON yazilim clear'i

  // ---- L4 / System Controller Kontrol Girisleri -----------------------------
  input  logic                              go_i,
  input  logic                              card_present_i,
  input  logic                              card_ready_i,
  input  logic [ultra_sd_pkg::LBA_W-1:0]    lba_i,
  input  logic [ultra_sd_pkg::BLOCKS_W-1:0] blocks_i,
  input  logic                              dir_i,
  input  logic [31:0]                       card_blk_i,
  input  logic [15:0]                       rca_i,

  // ---- L4 Durum ve Hata Bildirimleri ----------------------------------------
  output logic                              accept_o,
  output logic                              busy_o,
  output logic                              fin_o,
  output logic                              fail_o,
  output ultra_sd_pkg::err_e                fail_code_o,

  // ---- Table 5-2 Istatistik Sayaclari ---------------------------------------
  input  logic                              stat_clear_tgl_i,
  output logic [31:0]                       stat_gap_o,
  output logic [15:0]                       stat_retry_crc_o,

  // ---- L2 (ultra_sd_cmd) Komut Arayuzu --------------------------------------
  output logic                              req_valid_o,
  output logic [5:0]                        req_index_o,
  output logic [31:0]                       req_arg_o,
  output ultra_sd_pkg::resp_e               req_resp_o,
  output logic                              req_is_acmd_o,
  input  logic                              req_ready_i,
  input  logic                              rsp_valid_i,
  input  logic                              rsp_err_i,
  input  ultra_sd_pkg::err_e                cmd_err_i,

  // ---- L1 (ultra_sd_line) Veri Hatti Arayuzu --------------------------------
  output logic                              dat_start_o,
  output logic                              dat_dir_o,
  output logic [31:0]                       tx_data_o,
  input  logic                              tx_take_i,
  input  logic                              tx_done_i,
  input  logic                              tx_status_ok_i,
  input  logic                              tx_status_tmo_i,
  input  logic [31:0]                       rx_data_i,
  input  logic                              rx_valid_i,
  input  logic                              rx_busy_i,
  input  logic                              rx_done_i,
  input  logic                              rx_crc_ok_i,
  input  logic                              dat_active_i,
  input  logic                              card_busy_i,

  // ---- FIFO Okuma Arayuzu (SD -> Host) --------------------------------------
  output logic [DATA_W-1:0]                 rd_data_o,
  output logic                              rd_en_o,
  output logic                              rd_commit_o,
  output logic                              rd_rewind_o,
  input  logic                              rd_room_ok_i,

  // ---- FIFO Yazma Arayuzu (Host -> SD) --------------------------------------
  input  logic [DATA_W-1:0]                 wr_data_i,
  input  logic                              wr_last_i,
  output logic                              wr_en_o,
  output logic                              wr_commit_o,
  output logic                              wr_rewind_o,
  input  logic                              wr_block_ready_i
);

  import ultra_sd_pkg::*;

  localparam int TO_W  = $clog2((NAC_TIMEOUT_CLK > PROG_TIMEOUT_CLK)
                                ? NAC_TIMEOUT_CLK + 1 : PROG_TIMEOUT_CLK + 1);
  localparam int RTY_W = $clog2(CRC_RETRIES + 2);
  localparam int BLOCK_SHIFT = $clog2(BLOCK_BYTES);

  // ---- FSM Durum Tanimlari --------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_PRE_ERASE,
    S_RD_ARM,
    S_CMD,
    S_RD_DATA,
    S_WR_ARM,
    S_WR_DATA,
    S_BUSY,
    S_STOP,
    S_STATUS,
    S_DONE,
    S_ERROR
  } step_e;

  typedef enum logic [1:0] { P_ISSUE, P_ACC, P_WAIT } cphase_e;

  typedef enum logic [1:0] {
    POST_NEXT,
    POST_RETRY,
    POST_DONE,
    POST_ERROR
  } post_e;

  // ---- Dahili Sinyaller ve Register'lar --------------------------------------
  step_e               step_q;
  cphase_e             cphase_q;
  post_e               post_q;

  logic [LBA_W-1:0]    lba_q;
  logic [BLOCKS_W-1:0] blocks_left_q;
  logic                dir_q;
  logic                multi_q;
  logic [RTY_W-1:0]    retry_q;

  logic [BLOCKS_W-1:0] arm_left_q;
  logic                rx_busy_q;
  logic [2:0]          arm_idle_q;
  // Settling delay before S_BUSY is allowed to believe card_busy_i. See the
  // counter itself for the race it closes.
  logic [1:0]          busy_settle_q;

  logic [TO_W-1:0]     to_q;
  logic                drop_q;
  logic                stopped_q;

  logic                rd_rewind_q;
  logic                wr_rewind_q;

  logic [STAT_DUR_W-1:0] stat_gap_q;
  logic [STAT_RTY_W-1:0] stat_rty_crc_q;
  logic [1:0]            clr_sync_q;
  logic                  clr_q;
  logic                  stat_clear;

  logic [1:0]          go_sync_q, pres_sync_q;
  logic                go_q;
  logic                go_rise, go_fall;
  logic                abort_evt;

  logic                start_arg_bad;
  err_e                start_arg_err;
  logic                start_bad;
  err_e                start_err;

  logic [5:0]          nx_index;
  logic [31:0]         nx_arg;
  resp_e               nx_resp;
  logic                nx_acmd;
  logic [31:0]         dat_addr;

  logic                cmd_step;
  logic                cmd_ack, cmd_fail, cmd_ok;

  logic                last_block, need_stop, retry_left, retry_crc;
  logic                recover_step;

  logic                rx_arm_taken;
  logic                rd_block_ok, rd_crc_fail, rd_tmo;
  logic                wr_block_ok, wr_nak, wr_tmo, wr_proto;
  logic                busy_tmo;

  logic                in_stream, gap_active;
  logic                past_first_q;

  // Combinational twins of the five L4-facing status outputs. The outputs
  // themselves are registered; see section 8 for why.
  logic                accept_evt, busy_evt, fin_evt, fail_evt;
  err_e                fail_code_evt;


  // ===========================================================================
  // 1. GIRIS SENKRONIZASYONU VE ON-DENETIM (Input Sync & Pre-validation)
  // ===========================================================================
  assign go_rise   =  go_sync_q[1] & ~go_q;
  assign go_fall   = ~go_sync_q[1] &  go_q;
  assign abort_evt = go_fall && (step_q != S_IDLE) &&
                     (step_q != S_DONE) && (step_q != S_ERROR);

  // Giris kontrol sinyalleri senkronizasyonu
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      go_sync_q   <= 2'b00;
      go_q        <= 1'b0;
      pres_sync_q <= 2'b00;
    end else begin
      go_sync_q   <= {go_sync_q[0],   go_i};
      go_q        <= go_sync_q[1];
      pres_sync_q <= {pres_sync_q[0], card_present_i};
    end
  end

  // Baslatma argumanlarinin on-denetimi (LBA + BLOCKS ve CARD_BLK kontrolu)
  logic [32:0] last_blk_q;
  logic        start_range_bad_q;
  logic        start_blocks_zero_q;
  logic        start_multi_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_blk_q          <= '0;
      start_range_bad_q   <= 1'b0;
      start_blocks_zero_q <= 1'b1;
      start_multi_q       <= 1'b0;
    end else if (soft_clr) begin
      last_blk_q          <= '0;
      start_range_bad_q   <= 1'b0;
      start_blocks_zero_q <= 1'b1;
      start_multi_q       <= 1'b0;
    end else begin
      last_blk_q          <= {1'b0, lba_i} + {1'b0, 32'(blocks_i)};
      start_range_bad_q   <= (last_blk_q > {1'b0, card_blk_i});
      start_blocks_zero_q <= (blocks_i == '0);
      start_multi_q       <= (blocks_i > BLOCKS_W'(1));

    end
  end

  // THE PRE-CHECK HAS TO BE READY ON THE SAME EDGE go_rise IS SAMPLED, AND IT
  // WAS ONE STAGE LATE.
  //
  // go_i is three flops deep (go_sync_q[0], go_sync_q[1], go_q), so the FSM
  // samples go_rise on the third clk edge after the host wrote CTRL.START --
  // and lba_i / blocks_i / card_blk_i were latched by the same write, so they
  // changed on the same edge. The verdict therefore has to be valid on edge 3:
  //
  //   edge 1   last_blk_q          = lba + blocks
  //   edge 2   start_range_bad_q   = last_blk_q > card_blk
  //   edge 3   go_rise sampled, start_bad consumed
  //
  // start_arg_bad_q used to be a third registered stage, so on edge 3 it still
  // held the verdict for the PREVIOUS request. The symptom was one transfer of
  // lag in the refusal path: a legal single-block read issued straight after a
  // rejected out-of-range request went to S_ERROR with ERR_RANGE and never put
  // a command on the bus, while the out-of-range request itself was only
  // refused because the request before IT had also been bad.
  //
  // These two are an OR and a 2:1 of bits that are already registered, so
  // collapsing the stage costs nothing on the path the pipeline exists to
  // keep short -- the adder and the comparison against card_blk are still
  // registered, which is what was making a 15-level cone out of the go_rise
  // branch.
  assign start_arg_bad = start_blocks_zero_q || start_range_bad_q;
  assign start_arg_err = start_blocks_zero_q ? ERR_PROTOCOL
                       : start_range_bad_q   ? ERR_RANGE
                                             : ERR_OK;

  assign start_err = !pres_sync_q[1] ? ERR_NO_CARD
                   : !card_ready_i   ? ERR_CARD_STATE
                                     : start_arg_err;

  assign start_bad = (step_q == S_IDLE) && go_rise &&
                     (!pres_sync_q[1] || !card_ready_i || start_arg_bad);


  // ===========================================================================
  // 2. BLOK AKTARIM VE ADRES TAKIBI (Block Accounting & LBA Tracking)
  // ===========================================================================
  assign last_block   = (blocks_left_q == BLOCKS_W'(1));
  assign need_stop    = multi_q;
  assign retry_left   = (retry_q < RTY_W'(CRC_RETRIES));
  assign retry_crc    = (rd_crc_fail || wr_nak) && retry_left;
  assign recover_step = need_stop && !stopped_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lba_q         <= '0;
      blocks_left_q <= '0;
      past_first_q  <= 1'b0;
      dir_q         <= 1'b0;
      multi_q       <= 1'b0;
      retry_q       <= '0;
    end else if (soft_clr) begin
      lba_q         <= '0;
      blocks_left_q <= '0;
      past_first_q  <= 1'b0;
      dir_q         <= 1'b0;
      multi_q       <= 1'b0;
      retry_q       <= '0;
    end else if (accept_evt) begin
      past_first_q  <= 1'b0;
      lba_q         <= lba_i;
      blocks_left_q <= blocks_i;
      dir_q         <= dir_i;
      multi_q       <= start_multi_q;
      retry_q       <= '0;
    end else if (rd_block_ok || wr_block_ok) begin
      lba_q         <= lba_q + LBA_W'(1);
      past_first_q  <= 1'b1;
      blocks_left_q <= blocks_left_q - BLOCKS_W'(1);
      retry_q       <= '0;
    end else if (retry_crc) begin
      retry_q       <= retry_q + RTY_W'(1);
    end
  end


  // ===========================================================================
  // 3. KOMUT URETIMI VE EL SIKISMASI (Command Generation & Handshake)
  // ===========================================================================
  // The card is always block-addressed: an SDSC card (OCR.CCS = 0) is
  // rejected during initialisation (Section 3.2), so the LBA goes to the
  // card as-is and the byte-address shift has no reachable input.
  assign dat_addr = lba_q;

  // Komut arguman ve indeks secici (Kombinasyonel uretim)
  always_comb begin
    unique case (step_q)
      S_PRE_ERASE: begin
        nx_index = ACMD23_SET_WR_BLK_ERASE_CNT;
        // S_PRE_ERASE is only ever entered straight out of the accept
        // transition, before any block has completed, so blocks_left_q is
        // still the whole request -- no separate total register needed.
        nx_arg   = {9'h0, (blocks_left_q[23] ? 23'h7F_FFFF
                                             : blocks_left_q[22:0])};
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b1;
      end
      S_STOP: begin
        nx_index = CMD12_STOP_TRANSMISSION;
        nx_arg   = 32'h0;
        nx_resp  = RESP_R1B;
        nx_acmd  = 1'b0;
      end
      S_STATUS: begin
        nx_index = CMD13_SEND_STATUS;
        nx_arg   = {rca_i, 16'h0};
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b0;
      end
      default: begin
        nx_index = dir_q ? (multi_q ? CMD25_WRITE_MULTIPLE_BLK
                                    : CMD24_WRITE_BLOCK)
                         : (multi_q ? CMD18_READ_MULTIPLE_BLOCK
                                    : CMD17_READ_SINGLE_BLOCK);
        nx_arg   = dat_addr;
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b0;
      end
    endcase
  end

  assign cmd_step = (step_q == S_PRE_ERASE) || (step_q == S_CMD) ||
                    (step_q == S_STOP)      || (step_q == S_STATUS);

  assign req_valid_o   = cmd_step && (cphase_q != P_WAIT);
  assign req_index_o   = nx_index;
  assign req_arg_o     = nx_arg;
  assign req_resp_o    = nx_resp;
  assign req_is_acmd_o = nx_acmd;

  assign cmd_ack  = cmd_step && (cphase_q == P_WAIT) && rsp_valid_i;
  assign cmd_fail = cmd_ack &&  rsp_err_i;
  assign cmd_ok   = cmd_ack && !rsp_err_i;

  // Komut istek el sikisma fazi (cphase) FSM'i
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cphase_q <= P_ISSUE;
    end else if (soft_clr || !cmd_step || cmd_ack || abort_evt) begin
      cphase_q <= P_ISSUE;
    end else begin
      unique case (cphase_q)
        P_ISSUE: cphase_q <= req_ready_i ? P_WAIT : P_ACC;
        P_ACC:   if (req_ready_i) cphase_q <= P_WAIT;
        default: ;
      endcase
    end
  end


  // ===========================================================================
  // 4. VERI HATTI (LINE) KONTROLU VE ARM YONETIMI (Line Control & Arm)
  // ===========================================================================
  // Karti arm etmeden once 8 cevrim sessizlik filtresi
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arm_idle_q <= '0;
    end else if (soft_clr) begin
      arm_idle_q <= '0;
    end else begin
      if (((step_q != S_RD_ARM) && (step_q != S_WR_ARM)) || card_busy_i)
        arm_idle_q <= '0;
      else if (arm_idle_q != 3'd7)
        arm_idle_q <= arm_idle_q + 3'd1;
    end
  end

  // CARD_BUSY IS NOT TRUSTWORTHY IN THE FIRST CYCLES OF S_BUSY.
  //
  // The card drives DAT0 low to signal programming only after it has finished
  // the CRC status token (spec 4.6.2), and ultra_sd_line registers that into
  // card_busy_q, which it only drives meaningfully once its cell is idle. The
  // block layer, meanwhile, enters S_BUSY on tx_done -- the same edge the cell
  // goes idle. So for the first couple of cycles card_busy_i still reads 0
  // because nothing has sampled the low DAT0 yet, not because the card is
  // free.
  //
  // Left unguarded, S_BUSY reads that 0 and walks straight out to S_DONE. The
  // transfer then reports success while the card is still programming, and the
  // next block is armed into a busy card. It was caught by the dat_stuck_busy
  // scenario, where the card is made to hold DAT0 low forever and the core
  // reported ERR_OK anyway: the probe shows S_BUSY entered with busy=0 and
  // left one cycle before busy rose.
  //
  // Three cycles is enough -- the line needs one to sample and one to
  // register -- and the cost is nothing: a real card's programming window is
  // thousands of cycles (STAT_BUSY measures it), and on the CMD12 path into
  // S_BUSY three SD clocks is 0.3 % of one 1042-cycle block.
  localparam logic [1:0] BUSY_SETTLE = 2'd3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_settle_q <= '0;
    end else if (soft_clr) begin
      busy_settle_q <= '0;
    end else if (step_q != S_BUSY) begin
      busy_settle_q <= BUSY_SETTLE;
    end else if (busy_settle_q != 2'd0) begin
      busy_settle_q <= busy_settle_q - 2'd1;
    end
  end

  // Hat arm butcesi ve RX mesguliyet takibi
  assign rx_arm_taken = !dir_q && rx_busy_i && !rx_busy_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_busy_q  <= 1'b0;
      arm_left_q <= '0;
    end else if (soft_clr) begin
      rx_busy_q  <= 1'b0;
      arm_left_q <= '0;
    end else begin
      rx_busy_q <= rx_busy_i;
      if (step_q == S_RD_ARM)
        arm_left_q <= blocks_left_q;
      else if (rx_arm_taken && (arm_left_q != BLOCKS_W'(0)))
        arm_left_q <= arm_left_q - BLOCKS_W'(1);
    end
  end

  // Hat tetikleme (dat_start_o) cikislari
  assign dat_start_o = ((step_q == S_RD_ARM) && (arm_idle_q == 3'd7))
                    || ((step_q == S_RD_DATA) && !drop_q && rd_room_ok_i
                        && (arm_left_q != BLOCKS_W'(0)))
                    || ((step_q == S_WR_ARM) && (arm_idle_q == 3'd7)
                        && wr_block_ready_i);
  assign dat_dir_o   = dir_q;

  // Hat durum ve transfer sonuclarinin cozumu
  assign rd_block_ok = (step_q == S_RD_DATA) && rx_done_i &&  rx_crc_ok_i;
  assign rd_crc_fail = (step_q == S_RD_DATA) && rx_done_i && !rx_crc_ok_i;
  assign wr_block_ok = (step_q == S_WR_DATA) && tx_done_i &&  tx_status_ok_i;
  assign wr_tmo      = (step_q == S_WR_DATA) && tx_done_i &&  tx_status_tmo_i;
  assign wr_nak      = (step_q == S_WR_DATA) && tx_done_i && !tx_status_ok_i &&
                       !tx_status_tmo_i;
  assign wr_proto    = wr_en_o && wr_last_i && !last_block;


  // ===========================================================================
  // 5. ZAMAN ASIMI (TIMEOUT) SAYACI (Timeout Counter)
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      to_q <= '0;
    end else if (soft_clr) begin
      to_q <= '0;
    end else begin
      if (!abort_evt && !(fail_evt && (step_q != S_IDLE)) && !retry_crc) begin
        if ((step_q == S_CMD) && cmd_ok) begin
          to_q <= dir_q ? TO_W'(PROG_TIMEOUT_CLK)
                        : TO_W'(NAC_TIMEOUT_CLK);
        end else if ((step_q == S_RD_DATA) && rd_block_ok) begin
          to_q <= TO_W'(NAC_TIMEOUT_CLK);
        end else if ((step_q == S_WR_ARM) && wr_block_ready_i && (arm_idle_q == 3'd7)) begin
          to_q <= TO_W'(NAC_TIMEOUT_CLK);
        end else if ((step_q == S_WR_DATA) && wr_block_ok) begin
          to_q <= TO_W'(PROG_TIMEOUT_CLK);
        end else if ((step_q == S_STOP) && cmd_ok) begin
          to_q <= TO_W'(PROG_TIMEOUT_CLK);
        end else if (to_q != '0) begin
          to_q <= to_q - TO_W'(1);
        end
      end else if (to_q != '0) begin
        to_q <= to_q - TO_W'(1);
      end
    end
  end

  assign rd_tmo   = (step_q == S_RD_DATA) && (to_q == '0) && !dat_active_i;
  // S_BUSY now also waits for the receive cell (see the state itself), so the
  // timeout has to cover that wait too or R-FUNC-17 loses its bound on a card
  // that starts a block and stops clocking data out of it.
  assign busy_tmo = ((step_q == S_BUSY) || (step_q == S_WR_ARM)) &&
                    (to_q == '0) && (card_busy_i || rx_busy_i);


  // ===========================================================================
  // 6. ANA ISLEM FSM'I (Main Step FSM & State Transitions)
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step_q    <= S_IDLE;
      post_q    <= POST_NEXT;
      drop_q    <= 1'b0;
      stopped_q <= 1'b0;
    end else if (soft_clr) begin
      step_q    <= S_IDLE;
      post_q    <= POST_NEXT;
      drop_q    <= 1'b0;
      stopped_q <= 1'b0;
    end else begin
      // Oncelikli hata ve iptal dallanmalari
      if (abort_evt) begin
        drop_q <= 1'b1;
        post_q <= pres_sync_q[1] ? POST_DONE : POST_ERROR;
        step_q <= recover_step ? S_STOP : S_STATUS;
      end else if (fail_evt && (step_q != S_IDLE)) begin
        drop_q <= 1'b1;
        post_q <= POST_ERROR;
        step_q <= (step_q == S_STATUS) ? S_ERROR
                : recover_step         ? S_STOP : S_STATUS;
      end else if (retry_crc) begin
        drop_q <= 1'b1;
        post_q <= POST_RETRY;
        step_q <= recover_step ? S_STOP : S_STATUS;
      end else begin
        // Normal durum gecisleri
        unique case (step_q)
          S_IDLE: if (go_rise) begin
            drop_q    <= 1'b0;
            stopped_q <= 1'b0;
            step_q    <= start_bad ? S_ERROR
                       : dir_i     ? (start_multi_q ? S_PRE_ERASE : S_CMD)
                                   : S_RD_ARM;
          end

          S_RD_ARM: if (rd_room_ok_i && (arm_idle_q == 3'd7)) begin
            step_q <= S_CMD;
          end

          S_PRE_ERASE: if (cmd_ok) begin
            step_q <= S_CMD;
          end

          S_CMD: if (cmd_ok) begin
            drop_q    <= 1'b0;
            stopped_q <= 1'b0;
            step_q    <= dir_q ? S_WR_ARM : S_RD_DATA;
          end

          S_RD_DATA: if (rd_block_ok) begin
            if (last_block) begin
              drop_q <= 1'b1;
              post_q <= POST_DONE;
              step_q <= need_stop ? S_STOP : S_DONE;
            end else if (!rd_room_ok_i) begin
              drop_q <= 1'b1;
              post_q <= POST_RETRY;
              step_q <= S_STOP;
            end
          end

          S_WR_ARM: if (wr_block_ready_i && (arm_idle_q == 3'd7)) begin
            step_q <= S_WR_DATA;
          end

          S_WR_DATA: if (wr_block_ok) begin
            post_q <= last_block ? POST_DONE : POST_NEXT;
            step_q <= S_BUSY;
          end

          // card_busy_i alone is not enough to say the bus is free. It is only
          // meaningful while L1's cell is IDLE (ultra_sd_line header), and
          // after CMD12 the card still finishes the block already in flight --
          // spec 4.12.2, STOP_TRANSMISSION ends the stream after the current
          // block, not inside it. Leaving on card_busy_i alone reported DONE
          // with DAT still driven and started the next transfer into it: two
          // drivers, one bus. rx_busy_i covers the whole receive cell, not
          // just its payload segment, so the tail CRC and end bit are included.
          S_BUSY: if ((busy_settle_q == 2'd0) && !card_busy_i && !rx_busy_i) begin
            unique case (post_q)
              POST_DONE: step_q <= recover_step ? S_STOP : S_DONE;
              POST_NEXT: step_q <= S_WR_ARM;
              default:   step_q <= S_STATUS;
            endcase
          end

          S_STOP: if (cmd_ok) begin
            stopped_q <= 1'b1;
            step_q    <= S_BUSY;
          end

          S_STATUS: if (cmd_ok) begin
            unique case (post_q)
              POST_RETRY: begin
                drop_q    <= 1'b0;
                stopped_q <= 1'b0;
                step_q    <= dir_q ? S_CMD : S_RD_ARM;
              end
              POST_ERROR: step_q <= S_ERROR;
              default:    step_q <= S_DONE;
            endcase
          end

          default: begin
            drop_q <= 1'b0;
            if (!go_sync_q[1]) step_q <= S_IDLE;
          end
        endcase
      end
    end
  end


  // ===========================================================================
  // 7. FIFO YONETIMI (FIFO Control: Data, Enable, Commit, Rewind)
  // ===========================================================================
  assign rd_data_o   = rx_data_i;
  assign rd_en_o     = !dir_q && ((step_q == S_CMD) || (step_q == S_RD_DATA)) &&
                       rx_valid_i && !drop_q;

  assign tx_data_o   = wr_data_i;
  assign wr_en_o     = (step_q == S_WR_DATA) && tx_take_i;

  assign rd_commit_o = rd_block_ok;
  assign wr_commit_o = wr_block_ok;

  // Blok hatasi veya iptalde FIFO geri sarma (rewind) darbeleri
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_rewind_q <= 1'b0;
      wr_rewind_q <= 1'b0;
    end else if (soft_clr) begin
      rd_rewind_q <= 1'b0;
      wr_rewind_q <= 1'b0;
    end else begin
      rd_rewind_q <= (fail_evt || retry_crc || abort_evt) &&
                     (step_q == S_RD_DATA);
      wr_rewind_q <= (fail_evt || retry_crc || abort_evt) &&
                     (step_q == S_WR_DATA);
    end
  end

  assign rd_rewind_o = rd_rewind_q;
  assign wr_rewind_o = wr_rewind_q;


  // ===========================================================================
  // 8. ISTATISTIK VE DURUM CIKISLARI (Statistics & Status Outputs)
  // ===========================================================================
  // Inside the module these stay combinational: the FSM and the FIFO rewind
  // decide on the event in the cycle it happens.
  assign accept_evt = (step_q == S_IDLE) && go_rise;
  assign busy_evt   = (step_q != S_IDLE) && (step_q != S_DONE) &&
                      (step_q != S_ERROR);
  assign fin_evt    = (step_q == S_DONE) || (step_q == S_ERROR);

  assign fail_evt = start_bad || cmd_fail || rd_tmo || wr_tmo || wr_proto ||
                    busy_tmo || (rd_crc_fail && !retry_left) ||
                    (wr_nak && !retry_left) || (abort_evt && !pres_sync_q[1]);

  assign fail_code_evt = start_bad               ? start_err
                       : cmd_fail                ? cmd_err_i
                       : abort_evt               ? ERR_NO_CARD
                       : wr_proto                ? ERR_PROTOCOL
                       : (rd_tmo || wr_tmo || busy_tmo) ? ERR_DAT_TIMEOUT
                       : rd_crc_fail             ? ERR_DAT_CRC
                                                 : ERR_WR_CRC_TOKEN;

  // ---- the L4-facing copies are REGISTERED --------------------------------
  // These five are the only signals that leave this module for the system
  // clock domain (cdc.md row 12), and before this register stage they were
  // the longest path in the design by a wide margin: step_q -> this module's
  // fail_evt / busy_evt decode -> the route across to system_controller ->
  // system_controller's own decode -> its flops. 9.901 ns of it, which is
  // 98 % of a 10.101 ns period and the single reason the design could not be
  // constrained 20 % faster (constr/ultra_sd_margin20.sdc).
  //
  // Registering them costs five flip-flops and one sd_clk_core cycle of
  // latency. The cycle is free: all five move together, so fin / fail /
  // fail_code stay aligned with each other exactly as system_controller's
  // event logic expects, and nothing downstream measures their absolute
  // arrival -- STAT_GAP and the Table 11-1 latencies are all counted inside
  // the SD domain, upstream of here.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      accept_o    <= 1'b0;
      busy_o      <= 1'b0;
      fin_o       <= 1'b0;
      fail_o      <= 1'b0;
      fail_code_o <= ERR_OK;
    end else if (soft_clr) begin
      accept_o    <= 1'b0;
      busy_o      <= 1'b0;
      fin_o       <= 1'b0;
      fail_o      <= 1'b0;
      fail_code_o <= ERR_OK;
    end else begin
      accept_o    <= accept_evt;
      busy_o      <= busy_evt;
      fin_o       <= fin_evt;
      fail_o      <= fail_evt;
      fail_code_o <= fail_code_evt;
    end
  end

  assign in_stream  = (step_q == S_RD_DATA) || (step_q == S_WR_ARM) ||
                      (step_q == S_WR_DATA);
  assign gap_active = in_stream && !dat_active_i && !card_busy_i && multi_q &&
                      past_first_q;

  assign stat_clear = clr_sync_q[1] ^ clr_q;

  // STAT_GAP sayaci (akistayken bos gecen cevrimler)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clr_sync_q <= 2'b00;
      clr_q      <= 1'b0;
      stat_gap_q <= '0;
    end else begin
      clr_sync_q <= {clr_sync_q[0], stat_clear_tgl_i};
      clr_q      <= clr_sync_q[1];

      if (stat_clear) begin
        stat_gap_q <= '0;
      end else if (gap_active && !(&stat_gap_q)) begin
        stat_gap_q <= stat_gap_q + STAT_DUR_W'(1);
      end
    end
  end

  // STAT_RETRY CRC sayaci (omur boyu toplam CRC tekrar denemeleri)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stat_rty_crc_q <= '0;
    end else if (stat_clear) begin
      stat_rty_crc_q <= '0;
    end else if (retry_crc && !(&stat_rty_crc_q)) begin
      stat_rty_crc_q <= stat_rty_crc_q + STAT_RTY_W'(1);
    end
  end

  assign stat_gap_o       = {{(32-STAT_DUR_W){1'b0}}, stat_gap_q};
  assign stat_retry_crc_o = {{(16-STAT_RTY_W){1'b0}}, stat_rty_crc_q};

endmodule
