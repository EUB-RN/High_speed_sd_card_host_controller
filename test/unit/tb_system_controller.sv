`timescale 1ns/1ps

module tb_system_controller;
  import ultra_sd_pkg::*;

  logic clk = 0, rst_n_i, soft_reset_i, stat_clear_i, sd_cd_i;
  logic [CFG_CLK_W-1:0] clk_div_i;
  logic init_done_i, start_i, dir_i, abort_i, xfer_done_i, xfer_err_i;
  logic bus_4bit_i;
  logic xfer_launch_o;
  logic rst_n_o, core_rst_n_o, card_present_o, card_change_o;
  logic [CFG_CLK_W-1:0] sd_clk_ratio_o;
  logic sd_clk_en_o;
  logic sd_clk_i;
  logic bus_wide_o;
  sys_phase_e sys_phase_o;
  logic ramp_done_o, cfg_start_o;
  logic xfer_go_o;

  // Table 5-1 bu modulun faz FSM'inin icinde; olaylari burada baglanmis durur
  // (onlari sunan test tb_block_stat). Table 5-2 SAYACLARI burada DEGIL --
  // her biri olayini ureten modulde, bu modulun payi yalnizca silme toggle'i.
  // `.*` her port icin bir net istedigi icin hepsi burada.
  logic accept_i = 0, busy_i = 0;
  err_e fail_code_i = ERR_OK;
  logic card_ready_i = 0;
  speed_e speed_i = SPEED_INIT;
  logic init_err_i = 0;
  err_e init_err_code_i = ERR_OK;
  logic [STATUS_W-1:0] status_o;
  err_e err_o;
  logic [1:0] irq_set_o;
  logic stat_clear_tgl_o;

  int checks, failures;
  logic saw_card_change, saw_cfg_start;

  always #5 clk = ~clk;
  always @(posedge clk) begin
    if (card_change_o) saw_card_change <= 1;
    if (cfg_start_o) saw_cfg_start <= 1;
  end

  system_controller #(
    .CD_DEBOUNCE_CYC(3), .RST_SYNC_STAGES(2),
    .RAMP_CLOCKS(4), .INIT_CLK_DIV(10)
  ) dut (.*);

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  task automatic wait_phase(input sys_phase_e expected, input string message);
    int timeout;
    timeout = 0;
    while (sys_phase_o != expected && timeout < 80) begin @(posedge clk); #1; timeout++; end
    check(sys_phase_o == expected, message);
  endtask

  task automatic pulse_sd_clock;
    @(negedge clk); sd_clk_i = 1;
    repeat (2) @(posedge clk);
    @(negedge clk); sd_clk_i = 0;
    repeat (2) @(posedge clk);
  endtask

  initial begin
    checks = 0; failures = 0; saw_card_change = 0; saw_cfg_start = 0;
    rst_n_i = 0; soft_reset_i = 0; stat_clear_i = 0; sd_cd_i = 1; clk_div_i = 8'd4;
    init_done_i = 0; start_i = 0; dir_i = 0; abort_i = 0;
    xfer_done_i = 0; xfer_err_i = 0; bus_4bit_i = 1;
    sd_clk_i = 0;
    repeat (3) @(posedge clk);
    check(!rst_n_o && !core_rst_n_o && !card_present_o, "external reset state");
    rst_n_i = 1;
    wait_phase(SYS_CARD_DETECT, "synchronous reset release to card detect");
    check(!sd_clk_en_o, "SD clock disabled without card");

    sd_cd_i = 0;
    wait_phase(SYS_RAMP, "active-low card detect and debounce");
    check(card_present_o && saw_card_change && sd_clk_en_o,
          "card status/change and clock enable");
    // Saatin kendisi artik PHY'da uretiliyor; bu modul yalnizca ORANI verir.
    // Rampa boyunca oran INIT_CLK_DIV'e sabitlenir, sonra clk_div_i'ye doner.
    check(sd_clk_ratio_o == CFG_CLK_W'(10), "ramp forces the init clock ratio");
    check(bus_wide_o, "negotiated four-bit bus width before transfer");

    repeat (4) pulse_sd_clock();
    wait_phase(SYS_CONFIG, "configured after required ramp edges");
    check(ramp_done_o && saw_cfg_start, "ramp done and configuration pulse");
    check(sd_clk_ratio_o == clk_div_i, "ratio follows the requested divider after ramp");

    // START before init_done is ignored.
    @(negedge clk); start_i = 1;
    @(posedge clk); #1; @(negedge clk); start_i = 0;
    check(sys_phase_o == SYS_CONFIG, "start ignored before init completion");
    // ...ama SESSIZCE degil: kabul edilemeyen START sebebini ERR'e yazar,
    // yoksa surucu hic degismeyen bir STATUS'u sonsuza yoklar.
    check(err_o == ERR_CARD_STATE, "start before CARD_READY reports ERR_CARD_STATE");
    check(!xfer_launch_o, "a refused start raises no launch pulse");

    // Merdiven bittiginde surucuye haber gider: CARD_READY'nin yukselen
    // kenari da CARD_CHANGE darbesi uretir, yoksa "artik START yazabilirsin"
    // bilgisi yalnizca yoklama ile ogrenilebilirdi.
    // card_ready_i ve init_done_i ustte ayni tele (u_cmd'in init_done'u)
    // baglidir; burada ikisi ayri net oldugu icin birlikte suruluyor.
    @(negedge clk); init_done_i = 1; card_ready_i = 1;
    @(posedge clk); #1;
    check(card_change_o, "CARD_READY rising raises CARD_CHANGE");
    repeat (2) @(posedge clk); #1;
    check(!card_change_o, "the ready notification is a single-cycle pulse");

    init_done_i = 1; dir_i = 0;
    @(negedge clk); start_i = 1;
    @(posedge clk); #1; @(negedge clk); start_i = 0;
    check(sys_phase_o == SYS_READ, "read phase selected");
    // Akis master'i bu darbeyle arm edilir, CTRL.START'in kendisiyle degil.
    check(xfer_launch_o, "an accepted start pulses xfer_launch");
    // L3 START'i bir darbe olarak degil, bu SEVIYE olarak gorur: bolunmus SD
    // saatinde tek cevrimlik bir darbe kaybolurdu.
    check(xfer_go_o, "transfer permission is a level while the phase runs");
    // Genislik artik TEK kaynakta kararlastiriliyor: merdiven CFG_PHY'nin
    // FORCE_1BIT'ini ACMD6'nin argumanina uyguluyor ve sonucu bus_4bit_i
    // olarak buraya veriyor. Bu modulun isi o karari transfer boyunca
    // DONDURMAK; ikinci bir daraltma katmani yok (host 1-bit'e dusup kartin
    // 4-bit'te kalmasi tam olarak oyle olusuyordu).
    bus_4bit_i = 0;
    repeat (2) @(posedge clk); #1;
    check(bus_wide_o, "bus width locked during transfer");
    check(status_o[STATUS_BUS_WIDTH_LSB +: 2] == 2'b01,
          "STATUS reports the width L1 is actually driving");
    @(negedge clk); xfer_done_i = 1;
    @(posedge clk); #1; @(negedge clk); xfer_done_i = 0;
    check(sys_phase_o == SYS_CONFIG, "transfer completion returns to config");
    check(!xfer_go_o, "transfer permission drops with the phase");
    repeat (2) @(posedge clk); #1;
    check(!bus_wide_o, "ladder's width decision applied between transfers");
    check(status_o[STATUS_BUS_WIDTH_LSB +: 2] == 2'b00,
          "STATUS follows the width down, it does not report capability");

    // CTRL.STAT_CLEAR: sayaclar bu modulde degil, ama silme komutu buradan
    // cikar. Darbe tek clk cevrimi, sayaclar ise daha yavas SD saatlerinde --
    // o yuzden toggle'a cevriliyor (cdc.md 9) ve tuketenler DEGISIME bakiyor.
    begin
      logic tgl_before;
      tgl_before = stat_clear_tgl_o;
      @(negedge clk); stat_clear_i = 1;
      @(posedge clk); #1; @(negedge clk); stat_clear_i = 0;
      repeat (2) @(posedge clk); #1;
      check(stat_clear_tgl_o != tgl_before, "STAT_CLEAR pulse flips the toggle");
    end

    @(negedge clk); soft_reset_i = 1;
    @(posedge clk); #1; @(negedge clk); soft_reset_i = 0;
    check(sys_phase_o == SYS_RESET && !core_rst_n_o, "soft reset enters reset phase");
    repeat (18) @(posedge clk); #1;
    check(core_rst_n_o, "soft reset is bounded and releases");

    if (failures) begin
      $display("tb_system_controller: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_system_controller: PASSED (%0d checks)", checks);
    $finish;
  end
endmodule
