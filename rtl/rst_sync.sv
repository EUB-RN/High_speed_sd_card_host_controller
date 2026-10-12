// -----------------------------------------------------------------------------
// rst_sync
//   Purpose : TEK bir saat alaninin reset kaynaklarini uretmek. Alan basina
//             bir kez ornenklenir ve IKI AYRI sey verir:
//
//               rst_n_o     : YALNIZCA hard reset. Asenkron assert, bu alanin
//                             saatinde senkron deassert (R-CLK-1). Floplarin
//                             asenkron reset pinine giden tek sinyal budur.
//               soft_clr_o  : yazilim reset'inin bu alandaki SENKRON karsiligi.
//                             Floplarin asenkron pinine ASLA gitmez; her
//                             always_ff'in icinde bir `else if` kolu olur.
//
//   NEDEN BOYLE: daha once reset dagitimi soyleydi --
//       core_rst_n_o = rst_n_o & soft_rst_n_q      (kombinasyonel AND)
//   ve bu tek net, clk alaninin da sd_clk_core alaninin da ASENKRON reset
//   pinlerini suruyordu. Iki ayri kusuru vardi:
//
//     1. soft_rst_n_q clk ile saatlenmis bir flop. Onun 0->1 yukselisi
//        sd_clk_core alanindaki floplarin asenkron reset'ini birakiyordu, ve o
//        alanda reset senkronizatoru YOKTU. Birakma kenari sd kenarina rastgele
//        yakin dusebiliyordu: recovery / removal ihlali, ve farkli net
//        gecikmesine sahip floplarin reset'ten TUTARSIZ state'lerde cikmasi.
//        Ayni kusur hard reset'te de vardi, cunku rst_sync_q de clk ile
//        saatliydi.
//     2. Asenkron reset agina kombinasyonel mantik binmesi: o net 4000'den
//        fazla async-clear pinini suruyor (bench raporunda DFFC 534 + DFFCE
//        3496) ve onunde bir LUT duruyordu.
//
//   SENKRON CLEAR BU IKISINI BIRDEN KALDIRIR: senkron bir sinyalin "deassert
//   senkronizasyonu" diye bir problemi yoktur -- iki flop'luk senkronizator
//   metastabiliteyi cozer, gerisi o alanda siradan bir veri yoludur. Ve async
//   reset agi yeniden saf hard reset olur, onunde hicbir hucre kalmaz.
//
//   ACK NEDEN GEREKLI: istegi "yeterince uzun" tutmak icin sayac yazmak hedef
//   alanlarin frekansini bilmeyi gerektirir. axis_clk disardan geliyor ve
//   oranini kimse bilmiyor -- hicbir sabit sayi kanitlanabilir degil.
//   soft_clr_o istek alanina geri senkronlanip onay olarak kullanilir: istek
//   ancak TUM alanlar gordugunu bildirdikten sonra birakilir, yani en yavas
//   alan ne kadar yavassa istek o kadar durur. Toplama ust modulde yapilir.
// -----------------------------------------------------------------------------
module rst_sync #(
  // Deassert zincirinin kademe sayisi; en az 2. 2 metastabilite icin yeterli,
  // 3'u yalnizca cok yuksek saatlerde veya MTBF butcesi sikiysa gerekir.
  parameter int STAGES = 2
) (

  input  logic clk,

  // Bu alanin hard reset'i, CIPLAK ve senkronlanmamis. Senkronlamak bu modulun
  // isi; cagiran onu onceden senkronlamaz.
  input  logic hard_rst_n_i,

  // Yazilim reset istegi (CTRL.SOFT_RESET'ten turetilmis SEVIYE), istek
  // alaninda uretilmis, bu alana gore ASENKRON.
  input  logic soft_req_i,

  // Async assert / bu alanda senkron deassert. SADECE hard reset.
  output logic rst_n_o,

  // Bu alanda SENKRON soft clear. Istek alanina geri senkronlanip onay
  // (ack) olarak da kullanilir -- ayni bit, iki is.
  output logic soft_clr_o
);

  logic [STAGES-1:0] rel_q;
  logic [1:0]        req_sync_q;

  // ---------------------------------------------------------------------------
  // Hard reset birakma zinciri. ASENKRON ASSERT buradaki async pindir; bu
  // modulde de, bu modulu kullanan her yerde de async pine giren tek sinyal
  // hard reset'tir.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge hard_rst_n_i) begin
    if (!hard_rst_n_i) begin
      rel_q <= '0;
    end else begin
      rel_q <= {rel_q[STAGES-2:0], 1'b1};
    end
  end

  assign rst_n_o = rel_q[STAGES-1];

  // ---------------------------------------------------------------------------
  // Soft istek senkronizatoru. Kendisi rst_n_o ile resetlenir: hard reset
  // altinda istek gorulmez ve soft_clr_o 0'da durur. Boylece soft yol hard
  // yola HICBIR noktada mantik olarak karismaz -- sadece sirayla uygulanir.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      req_sync_q <= '0;
    end else begin
      req_sync_q <= {req_sync_q[0], soft_req_i};
    end
  end

  assign soft_clr_o = req_sync_q[1];

endmodule
