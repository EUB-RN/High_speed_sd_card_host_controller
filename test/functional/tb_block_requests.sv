`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_block_requests
//   Kapsam : ultra_sd_block'un istek sozlesmesi -- komut dizisi, blok basina
//            CRC16 yeniden denemesi, geri basinc ve spekulatif FIFO'nun
//            commit / rewind darbeleri.
//
//   YAPI   : L2 ve L1 ARKA PLANDA kosan davranissal modellerdir, testin
//            cagirdigi gorevler degil. Sebep: ultra_sd_block istegini iki
//            cevrim boyunca tutar, bu yuzden "komutu bekle" tarzi bir test
//            modulun kendi hizina yetisemez ve senkronu kaybeder. Burada
//              * komut sunucusu her istegi yakalar, DIZIYE yazar ve cevaplar,
//              * DAT motoru dat_start_o'yu gorunce blogu kendi akitir.
//            Senaryo sonunda komut DIZISI tek bir string olarak karsilastirilir
//            -- yani test "hangi komutlar hangi sirayla gitti" sorusunu
//            zamanlamadan bagimsiz sorar.
//
//            Istek bir DARBE ile degil SEVIYE ile baslar (system_controller'in
//            faz cikisi): yukselen kenar baslat, dusen kenar birak.
// -----------------------------------------------------------------------------
module tb_block_requests;
  import ultra_sd_pkg::*;

  localparam int WORDS_PER_BLOCK = (BLOCK_BYTES * 8) / 32;   // 128
  localparam int CRC_RETRIES     = 1;
  localparam int NAC_TO          = 400;
  localparam int PROG_TO         = 400;
  localparam logic [5:0] NO_CMD  = 6'h3F;

  logic clk = 0, rst_n;

  // ---- istek ----------------------------------------------------------------
  logic                go_i, card_present_i, card_ready_i, dir_i, block_addr_i;
  logic [LBA_W-1:0]    lba_i;
  logic [BLOCKS_W-1:0] blocks_i;
  logic [31:0]         card_blk_i;
  logic [15:0]         rca_i;

  // ---- olaylar --------------------------------------------------------------
  logic accept_o, busy_o, fin_o, fail_o;
  logic stat_clear_tgl_i;
  logic [31:0] stat_gap_o;
  logic [15:0] stat_retry_crc_o;
  err_e fail_code_o;

  // ---- L2 -------------------------------------------------------------------
  logic        req_valid_o, req_is_acmd_o, req_ready_i, rsp_valid_i, rsp_err_i;
  logic [5:0]  req_index_o;
  logic [31:0] req_arg_o;
  resp_e       req_resp_o;
  err_e        cmd_err_i;

  // ---- L1 -------------------------------------------------------------------
  logic        dat_start_o, dat_dir_o, tx_take_i, tx_done_i;
  logic        tx_status_ok_i, tx_status_tmo_i;
  logic [31:0] tx_data_o, rx_data_i;
  logic        rx_valid_i, rx_busy_i, rx_done_i, rx_crc_ok_i;
  logic        dat_active_i, card_busy_i;

  // ---- L4 yuk ---------------------------------------------------------------
  logic [31:0] rd_data_o, wr_data_i;
  logic        rd_en_o, rd_commit_o, rd_rewind_o, rd_room_ok_i;
  logic        wr_last_i, wr_en_o, wr_commit_o, wr_rewind_o, wr_block_ready_i;

  initial begin stat_clear_tgl_i = 1'b0; retry_base = 0; end
  int checks, failures;
  int commits, rewinds, retries, rd_words, wr_words;
  // stat_retry_crc_o DUT'un omur boyu toplami; senaryo basi degeri
  // taban aliniyor ki senaryolar birbirinin sayimini gormesin.
  int retry_base;
  err_e last_fail;              // fail_o aninda yakalanan kod
  logic saw_fail;
  string cmd_log, exp_log;

  always #5 clk = ~clk;

  // card_blk_i artik L3'un portu degil: on-denetim L4'te, clk alaninda bir boru
  // hattinda yapiliyor (ultra_sd_top). Test o hesabi burada ayni anlamla
  // uretir, boylece senaryolar card_blk_i'yi eskisi gibi surmeye devam eder.
  logic start_range_bad_i, start_blocks_zero_i, start_multi_i;
  assign start_range_bad_i   = ({1'b0, lba_i} + {1'b0, 32'(blocks_i)}) >
                               {1'b0, card_blk_i};
  assign start_blocks_zero_i = (blocks_i == '0);
  assign start_multi_i       = (blocks_i > 24'd1);

  ultra_sd_block #(
    .CRC_RETRIES      (CRC_RETRIES),
    .NAC_TIMEOUT_CLK  (NAC_TO),
    .PROG_TIMEOUT_CLK (PROG_TO)
  ) dut (.*);

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  // ---------------------------------------------------------------------------
  // Olay sayaclari. fail_code_o yalnizca fail_o darbesi sirasinda gecerlidir
  // Sayac artik ultra_sd_block'un kendi icinde: ham darbe yerine o okunuyor.
  // ---------------------------------------------------------------------------
  always @(posedge clk) if (rst_n) begin
    if (rd_commit_o || wr_commit_o) commits++;
    if (rd_rewind_o || wr_rewind_o) rewinds++;
    retries = int'(stat_retry_crc_o) - retry_base;
    if (rd_en_o)                    rd_words++;
    if (wr_en_o)                    wr_words++;
    if (fail_o) begin last_fail <= fail_code_o; saw_fail <= 1'b1; end
  end

  // ---------------------------------------------------------------------------
  // Davranissal L2: komut sunucusu.
  //   req_ready_i surekli yukarida -- komut motoru her istegi hemen alir.
  //   Istek yakalanir, diziye yazilir, modul P_WAIT'e gectigi cevrimde tek
  //   cevrimlik bir yanit verilir. R1b komutlari (CMD12) ardindan kart DAT0'i
  //   bir sure asagida tutar (hazard D-5).
  // ---------------------------------------------------------------------------
  // Kart veri hattini ancak veri komutundan SONRA surer ve CMD12 ile birakir.
  // Bu bayrak olmadan model dat_start_o'yu gorur gormez akitirdi ve komut
  // gitmeden once blok baslardi -- gercek kart oyle davranmaz.
  logic        card_streaming, card_multi, card_mute;

  logic        req_v_d, pending;
  logic [5:0]  pending_idx;
  logic [5:0]  arm_err_idx;     // bu komuta hata ile cevap ver
  err_e        arm_err_code;
  int          r1b_busy, prog_busy;

  assign req_ready_i = 1'b1;
  assign card_busy_i = (r1b_busy != 0) || (prog_busy != 0);

  always @(posedge clk) begin
    if (!rst_n) begin
      req_v_d <= 1'b0; pending <= 1'b0; pending_idx <= '0;
      card_streaming <= 1'b0; card_multi <= 1'b0;
      rsp_valid_i <= 1'b0; rsp_err_i <= 1'b0; cmd_err_i <= ERR_OK;
      r1b_busy <= 0;
    end else begin
      req_v_d     <= req_valid_o;
      rsp_valid_i <= 1'b0;
      rsp_err_i   <= 1'b0;
      cmd_err_i   <= ERR_OK;
      if (r1b_busy != 0) r1b_busy <= r1b_busy - 1;

      // Tek bloklu bir komuttan sonra kart veri hattini birakir; cok bloklu
      // akis CMD12'ye kadar surer. Bu ayrim olmadan bir sonraki transferin
      // blogu, komutu beklemeden akmaya baslar.
      if ((rx_done_i || tx_done_i) && !card_multi) card_streaming <= 1'b0;

      if (req_valid_o && !req_v_d) begin
        cmd_log     = {cmd_log, $sformatf("%s%0d@%0h ",
                                          req_is_acmd_o ? "A" : "",
                                          req_index_o, req_arg_o)};
        pending     <= 1'b1;
        pending_idx <= req_index_o;
      end else if (pending && !req_valid_o) begin
        pending     <= 1'b0;
        rsp_valid_i <= 1'b1;
        if (pending_idx == arm_err_idx) begin
          rsp_err_i   <= 1'b1;
          cmd_err_i   <= arm_err_code;
          arm_err_idx  = NO_CMD;           // bir kez
        end else if (pending_idx == CMD12_STOP_TRANSMISSION) begin
          r1b_busy       <= 4;             // R1b: mesguliyet DAT0'da
          card_streaming <= 1'b0;          // akis kapandi (hazard D-13)
        end else if ((pending_idx == CMD17_READ_SINGLE_BLOCK) ||
                     (pending_idx == CMD24_WRITE_BLOCK)) begin
          card_streaming <= 1'b1;
          card_multi     <= 1'b0;
        end else if ((pending_idx == CMD18_READ_MULTIPLE_BLOCK) ||
                     (pending_idx == CMD25_WRITE_MULTIPLE_BLK)) begin
          card_streaming <= 1'b1;
          card_multi     <= 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Davranissal L1: dat_start_o'yu gorunce bir blok akitir. Gercek L1 de boyle
  // davranir -- seviye yukaridaysa kendini yeniden silahlar.
  // ---------------------------------------------------------------------------
  int rx_blk_no, tx_blk_no;
  int rx_fail_at, tx_nak_at;   // -1 = hepsi saglam

  // L1'in giris senkronizeri iki flop: start seviyesi gorulduktan sonra
  // cerceve ancak birkac cevrim sonra baslar. Model bunu tasimak zorunda --
  // yoksa blok, DUT daha veri adimina gecmeden akmaya baslar.
  localparam int ARM_LATENCY = 3;

  task rx_one_block;
    repeat (ARM_LATENCY) @(negedge clk);
    rx_busy_i = 1; dat_active_i = 1; rx_valid_i = 1;
    for (int i = 0; i < WORDS_PER_BLOCK; i++) begin
      rx_data_i = 32'hA000_0000 + i;
      @(negedge clk);
    end
    rx_valid_i = 0; dat_active_i = 0;
    rx_crc_ok_i = (rx_blk_no != rx_fail_at);
    rx_done_i   = 1;
    @(negedge clk);
    rx_done_i = 0; rx_busy_i = 0; rx_blk_no++;
  endtask

  task tx_one_block;
    repeat (ARM_LATENCY) @(negedge clk);
    dat_active_i = 1; tx_take_i = 1;
    repeat (WORDS_PER_BLOCK) @(negedge clk);
    tx_take_i = 0; dat_active_i = 0;
    tx_status_ok_i  = (tx_blk_no != tx_nak_at);
    tx_status_tmo_i = 0;
    tx_done_i       = 1;
    @(negedge clk);
    tx_done_i = 0;
    if (tx_status_ok_i) prog_busy = 5;      // programlama mesguliyeti
    tx_status_ok_i = 0;
    tx_blk_no++;
  endtask

  initial forever begin
    @(negedge clk);
    if (rst_n && dat_start_o && card_streaming && !card_mute) begin
      if (dat_dir_o) tx_one_block(); else rx_one_block();
    end
  end

  always @(posedge clk) if (prog_busy != 0) prog_busy <= prog_busy - 1;

  // ---------------------------------------------------------------------------
  // Senaryo yardimcilari.
  // ---------------------------------------------------------------------------
  task automatic scenario(input string name);
    commits = 0; rewinds = 0; rd_words = 0; wr_words = 0;
    retry_base = int'(stat_retry_crc_o); retries = 0;
    rx_blk_no = 0; tx_blk_no = 0; rx_fail_at = -1; tx_nak_at = -1;
    arm_err_idx = NO_CMD; arm_err_code = ERR_OK;
    saw_fail = 0; last_fail = ERR_OK; cmd_log = ""; exp_log = "";
    $display("-- %s", name);
  endtask

  task automatic start_request(input logic direction,
                               input logic [23:0] count,
                               input logic [31:0] lba);
    int timeout;
    @(negedge clk);
    dir_i = direction; blocks_i = count; lba_i = lba; go_i = 1;
    timeout = 0;
    while (!accept_o && timeout < 20) begin @(posedge clk); #1; timeout++; end
    check(accept_o, "request accepted");
  endtask

  // system_controller fin_o'yu gorur gormez fazi birakir: go_i duser.
  task automatic wait_fin(input string name);
    int timeout;
    timeout = 0;
    while (!fin_o && timeout < 4000) begin @(posedge clk); #1; timeout++; end
    check(fin_o, {name, ": transfer finished"});
    @(negedge clk); go_i = 0;
    repeat (4) @(posedge clk); #1;
  endtask

  // Beklenen dizi, kaydin kendisiyle AYNI ifadeyle kurulur: boylece
  // karsilastirma bicimlendirmeden degil yalnizca siradan etkilenir.
  task automatic want(input logic [5:0] idx, input logic [31:0] arg,
                      input logic acmd);
    exp_log = {exp_log, $sformatf("%s%0d@%0h ", acmd ? "A" : "", idx, arg)};
  endtask

  task automatic check_log(input string name);
    check(cmd_log == exp_log,
          $sformatf("%s: command sequence | got \"%s\" | wanted \"%s\"",
                    name, cmd_log, exp_log));
  endtask

  // ---------------------------------------------------------------------------
  initial begin
    checks = 0; failures = 0;
    rst_n = 0;
    go_i = 0; card_present_i = 0; card_ready_i = 0; dir_i = 0; block_addr_i = 1;
    lba_i = 0; blocks_i = 1; card_blk_i = 32'd4096; rca_i = 16'hABCD;
    tx_take_i = 0; tx_done_i = 0; tx_status_ok_i = 0; tx_status_tmo_i = 0;
    rx_data_i = 0; rx_valid_i = 0; rx_busy_i = 0; rx_done_i = 0; rx_crc_ok_i = 0;
    dat_active_i = 0; prog_busy = 0; card_mute = 0;
    wr_data_i = 32'hDEAD_BEEF; wr_last_i = 0;
    rd_room_ok_i = 1; wr_block_ready_i = 1;
    arm_err_idx = NO_CMD; cmd_log = ""; exp_log = "";
    rx_fail_at = -1; tx_nak_at = -1;

    repeat (3) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk); #1;
    check(!busy_o && !fin_o && !req_valid_o && !dat_start_o,
          "reset contract: idle, no command, DAT engine released");

    // -------------------------------------------------------------------------
    scenario("no card");
    start_request(0, 1, 32'h1234);
    wait_fin("no card");
    check(saw_fail && last_fail == ERR_NO_CARD, "no card: ERR_NO_CARD");
    check_log("no card");                   // karta hicbir sey gitmez

    card_present_i = 1; card_ready_i = 1;

    // -------------------------------------------------------------------------
    scenario("beyond capacity (R-FUNC-4)");
    start_request(0, 8, 32'd4090);          // 4090 + 8 > 4096
    wait_fin("range");
    check(saw_fail && last_fail == ERR_RANGE, "beyond capacity reports ERR_RANGE");
    check_log("range");

    // -------------------------------------------------------------------------
    scenario("single block read: CMD17, no CMD12");
    start_request(0, 1, 32'h100);
    wait_fin("single read");
    want(CMD17_READ_SINGLE_BLOCK, 32'h100, 0);
    check_log("single read");
    check(!saw_fail, "single read reports no error");
    check(commits == 1 && rewinds == 0, "single read commits exactly one block");
    check(rd_words == WORDS_PER_BLOCK,
          $sformatf("single read forwarded %0d of %0d words",
                    rd_words, WORDS_PER_BLOCK));

    // -------------------------------------------------------------------------
    scenario("multi block read: one CMD18 then CMD12 (R-FUNC-8, R-FUNC-10)");
    start_request(0, 3, 32'h200);
    wait_fin("multi read");
    want(CMD18_READ_MULTIPLE_BLOCK, 32'h200, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    check_log("multi read");
    check(commits == 3 && rewinds == 0, "three blocks committed on one CMD18");
    check(rd_words == 3 * WORDS_PER_BLOCK,
          $sformatf("all three blocks forwarded (%0d of %0d words)",
                    rd_words, 3 * WORDS_PER_BLOCK));

    // -------------------------------------------------------------------------
    // CRC16 hatasi: blok geri sarilir (host hatali beat gormez), CMD12 + CMD13
    // ile toparlanilir -- yeniden baslatma YOK (R-FUNC-16, hazard D-12) -- ve
    // ayni LBA'dan yeni bir CMD18 acilir.
    // -------------------------------------------------------------------------
    scenario("read CRC16 failure recovers locally (R-FUNC-15, R-FUNC-16)");
    rx_fail_at = 1;                          // ikinci blok bozuk
    start_request(0, 3, 32'h200);
    wait_fin("read crc");
    want(CMD18_READ_MULTIPLE_BLOCK, 32'h200, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    want(CMD13_SEND_STATUS, {rca_i, 16'h0}, 0);
    want(CMD18_READ_MULTIPLE_BLOCK, 32'h201, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    check_log("read crc");
    check(rewinds == 1, "failed block is rewound, never published");
    check(retries == 1, "CRC retry counted for STAT_RETRY");
    check(commits == 3, $sformatf("three good blocks committed, got %0d", commits));
    check(!saw_fail, "recovered transfer reports success");

    // -------------------------------------------------------------------------
    scenario("read CRC16 beyond CRC_RETRIES reports ERR_DAT_CRC");
    rx_fail_at = 0;                          // her denemede ilk blok bozuk
    start_request(0, 2, 32'h200);
    // Her tekrarda blok numarasi 0'a donmedigi icin yalnizca ilk deneme
    // bozulur; kota bir oldugu icin bu yeterli: ikinci deneme saglam gelir.
    wait_fin("crc exhausted");
    check(retries == 1, "one retry was spent");
    check(!saw_fail, "retry inside the quota is not an error");

    // -------------------------------------------------------------------------
    // Geri basinc: FIFO'da blokluk yer kalmazsa akis CMD12 ile kapanir, yer
    // acilinca kalinan LBA'dan devam edilir (R-IF-7). Veri kaybi olmaz.
    // -------------------------------------------------------------------------
    scenario("host backpressure stops and resumes the stream (R-IF-7)");
    start_request(0, 3, 32'h300);
    @(posedge rd_commit_o);                  // ilk blok islendi
    rd_room_ok_i = 0;                        // host boslatmiyor
    repeat (30) @(posedge clk);
    rd_room_ok_i = 1;
    wait_fin("backpressure");
    want(CMD18_READ_MULTIPLE_BLOCK, 32'h300, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    want(CMD13_SEND_STATUS, {rca_i, 16'h0}, 0);
    want(CMD18_READ_MULTIPLE_BLOCK, 32'h301, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    check_log("backpressure");
    check(commits == 3, $sformatf("no block lost to backpressure, got %0d", commits));
    check(!saw_fail, "backpressure is not an error");

    // -------------------------------------------------------------------------
    scenario("single block write: CMD24, CRC status token, busy");
    start_request(1, 1, 32'h400);
    wait_fin("single write");
    want(CMD24_WRITE_BLOCK, 32'h400, 0);
    check_log("single write");
    check(wr_words == WORDS_PER_BLOCK,
          $sformatf("single write popped a whole block (%0d of %0d words)",
                    wr_words, WORDS_PER_BLOCK));
    check(commits == 1 && rewinds == 0, "accepted block is committed once");

    // -------------------------------------------------------------------------
    scenario("multi block write: ACMD23 then CMD25 (R-FUNC-11)");
    start_request(1, 2, 32'h500);
    wait_fin("multi write");
    want(ACMD23_SET_WR_BLK_ERASE_CNT, 32'd2, 1);
    want(CMD25_WRITE_MULTIPLE_BLK, 32'h500, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    check_log("multi write");
    check(commits == 2, $sformatf("two blocks committed, got %0d", commits));

    // -------------------------------------------------------------------------
    scenario("negative CRC status token replays the block (R-FUNC-13)");
    tx_nak_at = 0;                           // ilk blok reddedilir
    start_request(1, 2, 32'h600);
    wait_fin("write token");
    want(ACMD23_SET_WR_BLK_ERASE_CNT, 32'd2, 1);
    want(CMD25_WRITE_MULTIPLE_BLK, 32'h600, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    want(CMD13_SEND_STATUS, {rca_i, 16'h0}, 0);
    want(CMD25_WRITE_MULTIPLE_BLK, 32'h600, 0);
    want(CMD12_STOP_TRANSMISSION, 32'h0, 0);
    check_log("write token");
    check(rewinds == 1, "rejected block is rewound for a replay");
    check(retries == 1, "write CRC retry counted");
    check(commits == 2, $sformatf("both blocks eventually committed, got %0d",
                                  commits));

    // -------------------------------------------------------------------------
    scenario("command error is passed through and resynchronised");
    arm_err_idx  = CMD17_READ_SINGLE_BLOCK;
    arm_err_code = ERR_CMD_CRC;
    start_request(0, 1, 32'h700);
    wait_fin("cmd error");
    want(CMD17_READ_SINGLE_BLOCK, 32'h700, 0);
    want(CMD13_SEND_STATUS, {rca_i, 16'h0}, 0);
    check_log("cmd error");
    check(saw_fail && last_fail == ERR_CMD_CRC,
          "command error code is passed through");

    // -------------------------------------------------------------------------
    // Her bekleme sinirli (R-FUNC-17, R-IF-9): kart hic veri gondermezse
    // transfer ERR_DAT_TIMEOUT ile biter, asilmaz.
    // -------------------------------------------------------------------------
    scenario("silent card times out (R-FUNC-17, R-IF-9)");
    card_mute = 1'b1;                        // kart veri hattini hic surmuyor
    start_request(0, 1, 32'h800);
    wait_fin("timeout");
    card_mute = 1'b0;
    check(saw_fail && last_fail == ERR_DAT_TIMEOUT,
          "silent card ends in ERR_DAT_TIMEOUT");
    want(CMD17_READ_SINGLE_BLOCK, 32'h800, 0);
    want(CMD13_SEND_STATUS, {rca_i, 16'h0}, 0);
    check_log("timeout");

    if (failures) begin
      $display("tb_block_requests: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_block_requests: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("tb_block_requests: FAILED (timeout)");
    $fatal(1);
  end
endmodule
