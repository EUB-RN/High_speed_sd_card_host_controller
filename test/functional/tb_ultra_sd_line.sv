`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_ultra_sd_line
//   Kapsam : ultra_sd_line'in DAT cerceveleme sozlesmesi, SD'nin iki veri
//            yolu genisliginde: 1-bit (DAT0) ve 4-bit (DAT3..DAT0).
//            Tanimsiz bir maskenin 1-bit moda dustugu de kontrol edilir.
//
//            Veri arayuzu 32 bit: besleme ve kontrol kelime bazlidir, bayt
//            bazli bir port yoktur. Kelime ici bayt sirasi (varsayilan
//            little endian) da ilk yuk hucresi kontrolu ile dogrulanir.
//
//            Her genislik icin:
//              1) Yazma. FWFT bayt beslemesi verilir, TX motorunun dusen
//                 kenarda surdugu her hucre KARTIN ornekleme kenarinda
//                 (posedge) kaydedilir. Hucre sayisi start + yuk + CRC16 +
//                 end ile karsilastirilir, start bitinin aktif hatlarda 0
//                 oldugu ve ilk yuk hucresinin bit haritasi (grubun MSB'si
//                 en yuksek aktif hatta) dogrulanir.
//              2) Okuma. Kaydedilen dalga formu ayni modulun RX motoruna geri
//                 beslenir: cozulen kelimeler kaynak bellekle ayni olmali ve
//                 rx_crc_ok yukari cikmali. Bu, TX'in hat basina urettigi
//                 CRC16 ile RX'in hat basina hesapladigini uctan uca
//                 karsilastirir (hazard D-1).
//              3) Bagimsiz CRC referansi. Hattan yakalanan yuk hucreleri
//                 TB icinde hat basina yeniden CRC'lenir ve hattaki 16 CRC
//                 hucresi ile karsilastirilir. Bu, DUT'un CRC'yi
//                 toplayicinin kendisini kaydirarak surmesinden bagimsiz
//                 bir kontroldur.
//              4) Negatif. Tek bir yuk biti ters cevrilir; rx_crc_ok DUSMELI.
//
//   Not    : start_i seviye olarak verilir ve busy yukselene kadar tutulur --
//            modulun el sikisma sozlesmesi bu.
// -----------------------------------------------------------------------------
module tb_ultra_sd_line;
  import ultra_sd_pkg::*;
  localparam int NB = 8;              // yuk bayti (4'un kati)
  localparam int NW = NB / 4;         // kelime sayisi

  logic line_clk = 1'b0, rst_n = 1'b0;
  logic bus_wide; logic dir, start;
  logic [31:0] tx_data; logic tx_take, tx_busy, tx_done;
  logic [31:0] rx_data; logic rx_valid, rx_busy, rx_done, rx_crc_ok;
  logic [2:0]  tx_status; logic tx_status_ok, tx_status_tmo, card_busy;
  logic [3:0] dat_out, dat_oe, dat_in;
  // Table 5-2'nin iki sayaci artik bu modulun icinde (olaylari onun case
  // kollari), o yuzden test onlari dogrudan okuyabiliyor.
  logic stat_clear_tgl = 1'b0;
  logic [31:0] stat_data_cnt, stat_busy_cnt;

  ultra_sd_line #(.XFER_BYTES(BLOCK_BYTES)) dut (
    .line_clk, .rst_n, .bus_wide_i(bus_wide), .dir_i(dir), .start_i(start),
    .stat_clear_tgl_i(stat_clear_tgl), .stat_data_o(stat_data_cnt), .stat_busy_o(stat_busy_cnt),
        .xfer_bytes_i(11'(NB)),
    .tx_data_i(tx_data), .tx_take_o(tx_take), .tx_busy_o(tx_busy), .tx_done_o(tx_done),
    .tx_status_o(tx_status), .tx_status_ok_o(tx_status_ok),
    .tx_status_tmo_o(tx_status_tmo), .card_busy_o(card_busy),
    .rx_data_o(rx_data), .rx_valid_o(rx_valid), .rx_busy_o(rx_busy),
    .rx_done_o(rx_done), .rx_crc_ok_o(rx_crc_ok),
    .dat_out_o(dat_out), .dat_oe_o(dat_oe), .dat_in_i(dat_in));

  always #5 line_clk = ~line_clk;

  logic [31:0] mem [NW];

  int widx, ridx, errs;
  logic [3:0] cells [$];   // kartin ornekleme kenarinda yakalanan hucreler


  // FWFT besleme
  assign tx_data = mem[widx < NW ? widx : NW-1];
  always @(negedge line_clk) if (rst_n && tx_take) widx <= widx + 1;

  // Kart gibi ornekle: posedge'de surulen hucreyi kaydet
  logic capture;
  always @(posedge line_clk) if (capture && dat_oe[0]) cells.push_back(dat_out);

  // RX kontrolu
  // Tek saatlik darbeler yapiskan bayrakla yakalanir; wait() bir darbeyi
  // kacirirsa test kilitlenmesin.
  logic tx_done_seen, rx_done_seen;
  always @(posedge line_clk) begin
    if (tx_done) tx_done_seen <= 1'b1;
    if (rx_done) rx_done_seen <= 1'b1;
  end

  // card_busy yapiskan gozlemci: programlama hucrelerinde yukari cikmali.
  logic busy_seen;
  always @(posedge line_clk) if (card_busy) busy_seen <= 1'b1;

  logic check_bytes = 1;
  always @(posedge line_clk) if (rx_valid) begin
    if (!check_bytes) ridx++; else begin
    if (rx_data !== mem[ridx]) begin
      $display("HATA kelime %0d: beklenen %08h alinan %08h", ridx, mem[ridx], rx_data);
      errs++;
    end
    ridx++;
    end
  end

  // Kart modeli: yazmanin end bitinden sonra DAT0 uzerinde "0 sss 1"
  // token'i, ardindan birkac hucre programlama (busy, DAT0 asagida).
  task automatic card_status_token(input logic [2:0] sss, input int gap,
                                   input int busy_cells);
    repeat (gap) @(negedge line_clk) dat_in = 4'b1111;
    @(negedge line_clk) dat_in = 4'b1110;                 // start biti
    for (int i = 2; i >= 0; i--) begin
      @(negedge line_clk) dat_in = {3'b111, sss[i]};      // sss, MSB-first
    end
    @(negedge line_clk) dat_in = 4'b1111;                 // end biti
    repeat (busy_cells) @(negedge line_clk) dat_in = 4'b1110;  // programlama
    @(negedge line_clk) dat_in = 4'b1111;
  endtask

  task automatic run_width(input logic [3:0] m, input string nm);
    int ci; int exp; int pay; logic [3:0] c0, c1, cj, eff;
    logic [31:0] w0; logic [15:0] ref_crc; logic fb;
    cells.delete(); widx = 0; ridx = 0; capture = 1;
    bus_wide = (m == 4'b1111);
    // ---- yazma ----
    tx_done_seen = 0; rx_done_seen = 0;
    dir = 1; start = 1;
    wait (tx_busy); start = 0;
    // Once surme baslasin, sonra cerceve bitip pedler birakilsin.
    wait (dat_oe != 4'b0000);
    wait (dat_oe == 4'b0000);
    capture = 0;
    card_status_token(3'b010, 2, 3);
    wait (tx_done_seen);
    if (!tx_status_ok || tx_status !== 3'b010 || tx_status_tmo) begin
      $display("HATA %s: durum token'i yanlis (status=%03b ok=%b tmo=%b)",
               nm, tx_status, tx_status_ok, tx_status_tmo);
      errs++;
    end
    @(posedge line_clk);
    // start + yuk + CRC + end. Yalniz 4'b1111 4-bit moddur; geri kalan her
    // maske 1-bit moda duser.
    exp = 1 + NB*8/((m == 4'b1111) ? 4 : 1) + 16 + 1;
    $display("%s: yazma bitti, %0d hucre surudu (beklenen %0d)", nm, cells.size(), exp);
    if (cells.size() != exp) begin
      $display("HATA %s: hucre sayisi yanlis", nm); errs++;
    end
    c0 = cells[0]; c1 = cells[1]; w0 = mem[0];
    eff = (m == 4'b1111) ? 4'b1111 : 4'b0001;   // modulun gercekte kullandigi
    // start biti: aktif hatlar asagi
    if ((c0 & eff) !== 4'b0000) begin
      $display("HATA %s: start biti %04b", nm, c0); errs++;
    end
    // ilk yuk hucresi: grubun MSB'si en yuksek aktif hatta
    case (eff)
      4'b1111: if (c1[3:0] !== w0[7:4]) begin
                 $display("HATA %s: ilk nibble %04b, beklenen %04b", nm, c1[3:0], w0[7:4]); errs++; end
      default: if (c1[0] !== w0[7]) begin
                 $display("HATA %s: ilk bit %b, beklenen %b", nm, c1[0], w0[7]); errs++; end
    endcase
    // ---- bagimsiz CRC referansi: hattaki CRC hucreleri dogru mu ----
    pay = NB*8/((m == 4'b1111) ? 4 : 1);   // yuk hucresi sayisi
    for (int l = 0; l < 4; l++) begin
      if (eff[l]) begin
        // Bagimsiz referans: bu hattin yuk bitleri uzerinden CRC16-CCITT,
        // init = 0, son XOR yok, MSB-first.
        ref_crc = 16'h0000;
        for (int k = 0; k < pay; k++) begin
          cj     = cells[1 + k];
          fb     = ref_crc[15] ^ cj[l];
          ref_crc = {ref_crc[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
        end
        for (int j = 0; j < 16; j++) begin
          cj = cells[1 + pay + j];
          if (cj[l] !== ref_crc[15-j]) begin
            $display("HATA %s: DAT%0d CRC biti %0d hatali (hat %b, referans %b)",
                     nm, l, j, cj[l], ref_crc[15-j]);
            errs++;
          end
        end
      end
    end

    // ---- okuma: kaydedilen dalgayi geri besle ----
    rx_done_seen = 0;
    dir = 0; start = 1; dat_in = 4'hF;
    wait (rx_busy); start = 0;
    ci = 0;
    while (ci < cells.size()) begin
      @(negedge line_clk);
      dat_in = cells[ci]; ci++;
    end
    @(negedge line_clk) dat_in = 4'hF;  // end biti
    wait (rx_done_seen);
    if (!rx_crc_ok) begin $display("HATA %s: rx_crc_ok dusuk", nm); errs++; end
    if (ridx != NW) begin $display("HATA %s: %0d kelime alindi", nm, ridx); errs++; end
    else $display("%s: okuma OK, %0d kelime, crc_ok=%b", nm, ridx, rx_crc_ok);
    @(posedge line_clk);

    check_bytes = 0;
    // ---- negatif: bir yuk bitini boz, CRC dusmeli ----
    cells[5] = cells[5] ^ 4'b0001;
    ridx = 0; rx_done_seen = 0; dir = 0; start = 1; dat_in = 4'hF;
    wait (rx_busy); start = 0;
    ci = 0;
    while (ci < cells.size()) begin
      @(negedge line_clk);
      dat_in = cells[ci]; ci++;
    end
    @(negedge line_clk) dat_in = 4'hF;
    wait (rx_done_seen);
    if (rx_crc_ok) begin
      $display("HATA %s: bozuk bit CRC'yi dusurmedi", nm); errs++;
    end else begin
      $display("%s: bozuk bit yakalandi (crc_ok=0) OK", nm);
    end
    cells[5] = cells[5] ^ 4'b0001;
    check_bytes = 1;
    @(posedge line_clk);
  endtask

  // Yazma + verilen CRC durum token'i. send = 0 ise kart hic cevap vermez
  // ve zaman asimi beklenir.
  task automatic run_status_case(input logic [2:0] sss, input bit send,
                                 input string nm);
    tx_done_seen = 0; busy_seen = 0; widx = 0; check_bytes = 0;
    bus_wide = 1'b1; dir = 1; start = 1;
    wait (tx_busy); start = 0;
    wait (dat_oe != 4'b0000);
    wait (dat_oe == 4'b0000);
    // Token fazi boyunca tx_busy yukarida kalmali: cerceve daha bitmedi.
    if (!tx_busy) begin
      $display("HATA %s: pedler birakilinca tx_busy dustu", nm); errs++;
    end
    if (send) card_status_token(sss, 2, 4);
    wait (tx_done_seen);
    if (send) begin
      if (tx_status !== sss || tx_status_tmo ||
          (tx_status_ok !== (sss == 3'b010))) begin
        $display("HATA %s: status=%03b ok=%b tmo=%b (beklenen %03b, ok=%b)",
                 nm, tx_status, tx_status_ok, tx_status_tmo, sss,
                 (sss == 3'b010));
        errs++;
      end else begin
        $display("%s: status=%03b ok=%b OK", nm, tx_status, tx_status_ok);
      end
      if (!busy_seen) begin
        $display("HATA %s: card_busy hic yukselmedi", nm); errs++;
      end
    end else begin
      if (!tx_status_tmo || tx_status_ok) begin
        $display("HATA %s: zaman asimi bildirilmedi (tmo=%b ok=%b)",
                 nm, tx_status_tmo, tx_status_ok);
        errs++;
      end else begin
        $display("%s: token gelmedi, zaman asimi bildirildi OK", nm);
      end
    end
    if (tx_busy) begin
      $display("HATA %s: done sonrasi tx_busy dusmedi", nm); errs++;
    end
    check_bytes = 1;
    @(posedge line_clk);
  endtask

  initial begin
    foreach (mem[i]) mem[i] = 32'hA5C3_0F51 ^ (i * 32'h0101_1011);
    bus_wide = 1'b1; dir = 0; start = 0; dat_in = 4'hF;
    widx = 0; ridx = 0; errs = 0; capture = 0;
    tx_done_seen = 0; rx_done_seen = 0;
    repeat (3) @(posedge line_clk);
    rst_n = 1;
    repeat (3) @(posedge line_clk);

    // ilk baytin bit sirasi: 4-bit modda ilk hucre DAT3=bit7..DAT0=bit4
    run_width(4'b1111, "4-bit");
    run_width(4'b0001, "1-bit");
    // Tanimsiz maske: guvenli taraf 1-bit mod. Hucre sayisi 1-bit modun
    // sayisi ile ayni cikmali, cerceve de 1-bit mod gibi cozulmeli.
    run_width(4'b0100, "tanimsiz maske -> 1-bit");

    // ---- CRC durum token'i senaryolari (4-bit mod) ----
    run_status_case(3'b101, 1, "token CRC hatasi");
    run_status_case(3'b110, 1, "token yazma hatasi");
    run_status_case(3'b010, 0, "token yok");

    if (errs == 0) begin
      $display("tb_ultra_sd_line: PASSED");
      $finish;
    end else begin
      $display("tb_ultra_sd_line: FAILED (%0d hata)", errs);
      $fatal(1);
    end
  end

  // Guvenlik agi: cerceve asla bu kadar surmez.
  initial begin
    #200000;
    $display("tb_ultra_sd_line: FAILED (timeout)");
    $fatal(1);
  end
endmodule
