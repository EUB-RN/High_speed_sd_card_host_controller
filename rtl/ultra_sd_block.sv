

module ultra_sd_block #(

  parameter int DATA_W = 32,

  parameter int CRC_RETRIES = 3,

  parameter int NAC_TIMEOUT_CLK  = 5_000_000,

  parameter int PROG_TIMEOUT_CLK = 25_000_000
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 go_i,
  input  logic                 card_present_i,
  input  logic                 card_ready_i,
  input  logic [ultra_sd_pkg::LBA_W-1:0]    lba_i,
  input  logic [ultra_sd_pkg::BLOCKS_W-1:0] blocks_i,
  input  logic                 dir_i,
  // Baslatma argumanlarinin on-denetimi L4'te, clk alaninda yapilir ve buraya
  // tek bit olarak gelir. Sebebi zamanlama: lba+blocks toplamasi ile card_blk
  // karsilastirmasi burada, go_rise kolunun ortasinda kombinasyonel dururken
  // BLOCKS flopundan step_q / post_q ve u_sysctl'in CE'lerine kadar 15-16
  // mantik seviyesi uzayan tek bir koni olusuyordu; clk'in Fmax'ini asagi
  // ceken yol oydu. Ucu de go'ya gore quasi-statiktir (ultra_sd_top'taki
  // uretim yerine bak).
  input  logic                 start_range_bad_i,    // lba + blocks > card_blk
  input  logic                 start_blocks_zero_i,  // blocks == 0
  input  logic                 start_multi_i,        // blocks > 1
  input  logic                 block_addr_i,
  input  logic [15:0]          rca_i,

  output logic                 accept_o,
  output logic                 busy_o,
  output logic                 fin_o,
  output logic                 fail_o,
  output ultra_sd_pkg::err_e   fail_code_o,
  // Table 5-2'nin iki sayaci bu modulde, cunku olaylari bu FSM'in kollari:
  // bos gecen akis cevrimleri (gap) ve CRC yeniden denemesi. Eskiden ikisi de
  // ham sinyal olarak disari cikip baska bir modulde sayiliyordu; artik olayin
  // dogdugu yerde sayiliyor, dolayisiyla o portlar da yok. Silme komutu
  // toggle olarak gelir (cdc.md 9).
  input  logic                 stat_clear_tgl_i,
  output logic [31:0]          stat_gap_o,
  output logic [15:0]          stat_retry_crc_o,

  output logic                 req_valid_o,
  output logic [5:0]           req_index_o,
  output logic [31:0]          req_arg_o,
  output ultra_sd_pkg::resp_e  req_resp_o,
  output logic                 req_is_acmd_o,
  input  logic                 req_ready_i,
  input  logic                 rsp_valid_i,
  input  logic                 rsp_err_i,
  input  ultra_sd_pkg::err_e   cmd_err_i,

  output logic                 dat_start_o,
  output logic                 dat_dir_o,
  output logic [31:0]          tx_data_o,
  input  logic                 tx_take_i,
  input  logic                 tx_done_i,
  input  logic                 tx_status_ok_i,
  input  logic                 tx_status_tmo_i,
  input  logic [31:0]          rx_data_i,
  input  logic                 rx_valid_i,
  input  logic                 rx_busy_i,
  input  logic                 rx_done_i,
  input  logic                 rx_crc_ok_i,
  input  logic                 dat_active_i,
  input  logic                 card_busy_i,

  output logic [DATA_W-1:0]    rd_data_o,
  output logic                 rd_en_o,
  output logic                 rd_commit_o,
  output logic                 rd_rewind_o,
  input  logic                 rd_room_ok_i,

  input  logic [DATA_W-1:0]    wr_data_i,
  input  logic                 wr_last_i,
  output logic                 wr_en_o,
  output logic                 wr_commit_o,
  output logic                 wr_rewind_o,
  input  logic                 wr_block_ready_i
);

  import ultra_sd_pkg::*;

  localparam int TO_W  = $clog2((NAC_TIMEOUT_CLK > PROG_TIMEOUT_CLK)
                                ? NAC_TIMEOUT_CLK + 1 : PROG_TIMEOUT_CLK + 1);
  localparam int RTY_W = $clog2(CRC_RETRIES + 2);

  localparam int BLOCK_SHIFT = $clog2(BLOCK_BYTES);

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

  step_e               step_q;
  cphase_e             cphase_q;
  post_e               post_q;

  logic [LBA_W-1:0]    lba_q;
  logic [BLOCKS_W-1:0] blocks_left_q;
  logic [BLOCKS_W-1:0] blocks_tot_q;
  logic                dir_q;
  logic                multi_q;
  logic [TO_W-1:0]     to_q;
  logic [RTY_W-1:0]    retry_q;
  logic                drop_q;
  logic                stopped_q;
  logic [2:0]          rd_idle_q;
  logic                rd_rewind_q;
  logic                wr_rewind_q;

  logic [1:0] go_sync_q, pres_sync_q;
  logic       go_q;

  logic go_rise, go_fall;
  assign go_rise =  go_sync_q[1] & ~go_q;
  assign go_fall = ~go_sync_q[1] &  go_q;

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

  logic [5:0]  nx_index;
  logic [31:0] nx_arg;
  resp_e       nx_resp;
  logic        nx_acmd;
  logic [31:0] dat_addr;

  assign dat_addr = block_addr_i ? lba_q : (lba_q << BLOCK_SHIFT);

  always_comb begin
    unique case (step_q)
      S_PRE_ERASE: begin
        nx_index = ACMD23_SET_WR_BLK_ERASE_CNT;
        nx_arg   = {9'h0, blocks_tot_q[22:0]};
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

  logic cmd_step;
  assign cmd_step = (step_q == S_PRE_ERASE) || (step_q == S_CMD) ||
                    (step_q == S_STOP)      || (step_q == S_STATUS);

  assign req_valid_o   = cmd_step && (cphase_q != P_WAIT);
  assign req_index_o   = nx_index;
  assign req_arg_o     = nx_arg;
  assign req_resp_o    = nx_resp;
  assign req_is_acmd_o = nx_acmd;

  assign rd_data_o = rx_data_i;

  assign rd_en_o   = !dir_q && ((step_q == S_CMD) || (step_q == S_RD_DATA)) &&
                     rx_valid_i && !drop_q;

  assign tx_data_o = wr_data_i;
  assign wr_en_o   = (step_q == S_WR_DATA) && tx_take_i;

  assign dat_start_o = ((step_q == S_RD_ARM) && (rd_idle_q == 3'd7))
                    || ((step_q == S_RD_DATA) && !drop_q && rd_room_ok_i)
                    || (step_q == S_WR_ARM);
  assign dat_dir_o   = dir_q;

  logic cmd_ack, cmd_fail, cmd_ok;
  assign cmd_ack  = cmd_step && (cphase_q == P_WAIT) && rsp_valid_i;
  assign cmd_fail = cmd_ack &&  rsp_err_i;
  assign cmd_ok   = cmd_ack && !rsp_err_i;

  logic last_block, need_stop, retry_left;
  assign last_block = (blocks_left_q == BLOCKS_W'(1));
  assign need_stop  = multi_q;
  assign retry_left = (retry_q < RTY_W'(CRC_RETRIES));

  logic rd_block_ok, rd_crc_fail, rd_tmo;
  assign rd_block_ok = (step_q == S_RD_DATA) && rx_done_i &&  rx_crc_ok_i;
  assign rd_crc_fail = (step_q == S_RD_DATA) && rx_done_i && !rx_crc_ok_i;
  assign rd_tmo      = (step_q == S_RD_DATA) && (to_q == '0) && !rx_busy_i;

  logic wr_block_ok, wr_nak, wr_tmo, wr_proto;
  assign wr_block_ok = (step_q == S_WR_DATA) && tx_done_i &&  tx_status_ok_i;
  assign wr_tmo      = (step_q == S_WR_DATA) && tx_done_i &&  tx_status_tmo_i;
  assign wr_nak      = (step_q == S_WR_DATA) && tx_done_i && !tx_status_ok_i &&
                       !tx_status_tmo_i;

  assign wr_proto    = wr_en_o && wr_last_i && !last_block;

  logic busy_tmo;
  assign busy_tmo = ((step_q == S_BUSY) || (step_q == S_WR_ARM)) &&
                    (to_q == '0) && card_busy_i;

  logic        abort_evt, start_bad;
  err_e        start_err;

  assign abort_evt = go_fall && (step_q != S_IDLE) &&
                     (step_q != S_DONE) && (step_q != S_ERROR);

  // Kart varligi ve init tamam dinamik terimler, bu yuzden hala burada ve
  // kombinasyonel: ikisi de tek bit, yolu kisa, ve kart cikarma karari bir
  // cevrim bayatlamamali. Aritmetik olan iki terim L4'ten geliyor.
  assign start_err = !pres_sync_q[1]    ? ERR_NO_CARD
                   : !card_ready_i      ? ERR_CARD_STATE
                   : start_blocks_zero_i ? ERR_PROTOCOL
                   : start_range_bad_i   ? ERR_RANGE
                                         : ERR_OK;
  assign start_bad = (step_q == S_IDLE) && go_rise && (start_err != ERR_OK);

  assign fail_o = start_bad || cmd_fail || rd_tmo || wr_tmo || wr_proto ||
                  busy_tmo || (rd_crc_fail && !retry_left) ||
                  (wr_nak && !retry_left) || (abort_evt && !pres_sync_q[1]);

  assign fail_code_o = start_bad               ? start_err
                     : cmd_fail                ? cmd_err_i
                     : abort_evt               ? ERR_NO_CARD
                     : wr_proto                ? ERR_PROTOCOL
                     : (rd_tmo || wr_tmo || busy_tmo) ? ERR_DAT_TIMEOUT
                     : rd_crc_fail             ? ERR_DAT_CRC
                                               : ERR_WR_CRC_TOKEN;

  logic [STAT_DUR_W-1:0] stat_gap_q;
  logic [STAT_RTY_W-1:0] stat_rty_crc_q;
  logic [1:0]            clr_sync_q;
  logic                  clr_q;
  logic                  stat_clear;

  assign stat_clear = clr_sync_q[1] ^ clr_q;

  logic retry_crc;
  assign retry_crc = (rd_crc_fail || wr_nak) && retry_left;

  logic recover_step;
  assign recover_step = need_stop && !stopped_q;

  assign accept_o = (step_q == S_IDLE) && go_rise;
  assign busy_o   = (step_q != S_IDLE) && (step_q != S_DONE) &&
                    (step_q != S_ERROR);
  assign fin_o    = (step_q == S_DONE) || (step_q == S_ERROR);

  logic in_stream;
  assign in_stream    = (step_q == S_RD_DATA) || (step_q == S_WR_ARM) ||
                        (step_q == S_WR_DATA);
  logic gap_active;
  assign gap_active = in_stream && !dat_active_i && !card_busy_i && multi_q &&
                      (blocks_left_q != blocks_tot_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step_q     <= S_IDLE;
      post_q     <= POST_NEXT;
      to_q       <= '0;
      drop_q     <= 1'b0;
      stopped_q  <= 1'b0;
      rd_idle_q  <= '0;
      stat_gap_q <= '0;
      clr_sync_q <= 2'b00;
      clr_q      <= 1'b0;
    end else begin
      if (to_q != '0) to_q <= to_q - TO_W'(1);

      // STAT_GAP: akistayken bos gecen her SD cevrimi. gap_active'in
      // uretildigi yerin yanindaki tek sayac; saturasyonlu.
      clr_sync_q <= {clr_sync_q[0], stat_clear_tgl_i};
      clr_q      <= clr_sync_q[1];

      if (stat_clear) begin
        stat_gap_q <= '0;
      end else if (gap_active && !(&stat_gap_q)) begin
        stat_gap_q <= stat_gap_q + STAT_DUR_W'(1);
      end

      if ((step_q != S_RD_ARM) || card_busy_i) rd_idle_q <= '0;
      else if (rd_idle_q != 3'd7)               rd_idle_q <= rd_idle_q + 3'd1;

      if (abort_evt) begin
        drop_q <= 1'b1;
        post_q <= pres_sync_q[1] ? POST_DONE : POST_ERROR;
        step_q <= recover_step ? S_STOP : S_STATUS;
      end else if (fail_o && (step_q != S_IDLE)) begin
        drop_q <= 1'b1;
        post_q <= POST_ERROR;
        step_q <= (step_q == S_STATUS) ? S_ERROR
                : recover_step         ? S_STOP : S_STATUS;
      end else if (retry_crc) begin
        drop_q <= 1'b1;
        post_q <= POST_RETRY;
        step_q <= recover_step ? S_STOP : S_STATUS;
      end else begin
        unique case (step_q)
          S_IDLE: if (go_rise) begin
            drop_q    <= 1'b0;
            stopped_q <= 1'b0;
            step_q    <= start_bad ? S_ERROR
                       : dir_i     ? (start_multi_i ? S_PRE_ERASE : S_CMD)
                                   : S_RD_ARM;
          end

          S_RD_ARM:    if (rd_room_ok_i && (rd_idle_q == 3'd7)) step_q <= S_CMD;
          S_PRE_ERASE: if (cmd_ok)       step_q <= S_CMD;

          S_CMD: if (cmd_ok) begin
            drop_q    <= 1'b0;
            stopped_q <= 1'b0;
            to_q      <= dir_q ? TO_W'(PROG_TIMEOUT_CLK)
                               : TO_W'(NAC_TIMEOUT_CLK);
            step_q    <= dir_q ? S_WR_ARM : S_RD_DATA;
          end

          S_RD_DATA: if (rd_block_ok) begin
            to_q <= TO_W'(NAC_TIMEOUT_CLK);
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

          S_WR_ARM: if (!card_busy_i && wr_block_ready_i) begin
            to_q   <= TO_W'(NAC_TIMEOUT_CLK);
            step_q <= S_WR_DATA;
          end

          S_WR_DATA: if (wr_block_ok) begin
            to_q   <= TO_W'(PROG_TIMEOUT_CLK);
            post_q <= last_block ? POST_DONE : POST_NEXT;
            step_q <= S_BUSY;
          end

          S_BUSY: if (!card_busy_i) begin
            unique case (post_q)
              POST_DONE: step_q <= recover_step ? S_STOP : S_DONE;
              POST_NEXT: step_q <= S_WR_ARM;
              default:   step_q <= S_STATUS;
            endcase
          end

          S_STOP: if (cmd_ok) begin
            stopped_q <= 1'b1;
            to_q      <= TO_W'(PROG_TIMEOUT_CLK);
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lba_q         <= '0;
      blocks_left_q <= '0;
      blocks_tot_q  <= '0;
      dir_q         <= 1'b0;
      multi_q       <= 1'b0;
      retry_q       <= '0;
    end else if (accept_o) begin
      lba_q         <= lba_i;
      blocks_left_q <= blocks_i;
      blocks_tot_q  <= blocks_i;
      dir_q         <= dir_i;
      multi_q       <= start_multi_i;
      retry_q       <= '0;
    end else if (rd_block_ok || wr_block_ok) begin
      lba_q         <= lba_q + LBA_W'(1);
      blocks_left_q <= blocks_left_q - BLOCKS_W'(1);
      retry_q       <= '0;
    end else if (retry_crc) begin
      retry_q       <= retry_q + RTY_W'(1);
    end

    // STAT_RETRY'nin CRC yarisi: retry_q blok basina sifirlanan deneme
    // sayacidir, bu ise omur boyu toplam. Ayni kosulun yaninda duruyor ki
    // ikisi hic ayrisamasin. Silme ve saturasyon kendi kurallarinda.
    if (!rst_n) begin
      stat_rty_crc_q <= '0;
    end else if (stat_clear) begin
      stat_rty_crc_q <= '0;
    end else if (retry_crc && !(&stat_rty_crc_q)) begin
      stat_rty_crc_q <= stat_rty_crc_q + STAT_RTY_W'(1);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_rewind_q <= 1'b0;
      wr_rewind_q <= 1'b0;
    end else begin
      rd_rewind_q <= (fail_o || retry_crc || abort_evt) &&
                     (step_q == S_RD_DATA);
      wr_rewind_q <= (fail_o || retry_crc || abort_evt) &&
                     (step_q == S_WR_DATA);
    end
  end

  // Register goruntusu 32 / 16 bit kalir; kullanilmayan ust bitler sifir.
  assign stat_gap_o       = {{(32-STAT_DUR_W){1'b0}}, stat_gap_q};
  assign stat_retry_crc_o = {{(16-STAT_RTY_W){1'b0}}, stat_rty_crc_q};

  assign rd_commit_o = rd_block_ok;
  assign rd_rewind_o = rd_rewind_q;
  assign wr_commit_o = wr_block_ok;
  assign wr_rewind_o = wr_rewind_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cphase_q <= P_ISSUE;
    end else if (!cmd_step || cmd_ack || abort_evt) begin
      cphase_q <= P_ISSUE;
    end else begin
      unique case (cphase_q)
        P_ISSUE: cphase_q <= P_ACC;
        P_ACC:   if (req_ready_i) cphase_q <= P_WAIT;
        default: ;
      endcase
    end
  end

endmodule
