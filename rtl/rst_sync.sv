// -----------------------------------------------------------------------------
// rst_sync
//   Purpose : TEK bir saat alaninin reset'ini uretmek: asenkron assert, O
//             ALANIN SAATINDE senkron deassert (R-CLK-1). Alan basina bir kez
//             ornenklenir.
//
//   NEDEN VAR: tasarimda reset dagitimi daha once soyleydi --
//       rst_sync_q         : clk ile saatlenmis 2 kademeli zincir
//       soft_rst_n_q       : clk ile saatlenmis tek flop
//       core_rst_n_o       = rst_n_o & soft_rst_n_q      (kombinasyonel AND)
//   ve bu TEK net, clk alaninin da sd_clk_core alaninin da async reset pinlerini
//   suruyordu (ultra_sd_top'ta u_block / u_cmd / u_line, system_controller'da
//   sd_clk_i ile saatlenen iki blok). Uc modulun hicbirinde reset senkronizatoru
//   yoktu.
//
//   AND kombinasyonel olmasi SORUN DEGIL: assert yolunun kombinasyonel olmasi
//   reset gating'in tanimidir. Sorun DEASSERT'ti. Birakma kenarini clk'e gore
//   senkronlamak, sd_clk_core alanindaki floplar icin bir sey ifade etmez:
//   birakma o alanin kenarina rastgele yakin dusebilir ve fabric'te farkli net
//   gecikmesi olan floplar onu kenarin iki ayri yaninda gorebilir -- recovery /
//   removal ihlali, ve FSM'lerin birbiriyle TUTARSIZ state'lerde reset'ten
//   cikmasi.
//
//   Bugune kadar ayakta kalmasinin sebebi sd_clk_core'un clk/N olmasi: ayni
//   kok, cakisik kenarlar, dolayisiyla clk'e gore temiz bir birakma sd kenarina
//   gore de sabit fazda. Yani doguluk, cdc.md'nin "asenkron" dedigi iki saatin
//   aslinda ILISKILI olmasina yasliyordu. axis_clk gercekten asenkron oldugunda
//   yaslanacak hicbir hizalama kalmiyor.
//
//   ACK NEDEN VAR: istegi "yeterince uzun" tutmak icin sayac yazmak hedef
//   alanlarin frekansini bilmeyi gerektirir. axis_clk disardan geliyor ve
//   oranini kimse bilmiyor -- hicbir sabit sayi kanitlanabilir degil. ack yolu
//   istegi kendi kendine zamanlar: en yavas alan ne kadar yavassa istek o kadar
//   durur. Toplama ust modulde yapilir (bkz. ultra_sd_top).
// -----------------------------------------------------------------------------
module rst_sync #(
  // Deassert zincirinin kademe sayisi. 2 metastabilite icin yeterli; 3'u
  // yalnizca cok yuksek saatlerde veya MTBF butcesi sikiysa gerekir.
  parameter int STAGES = 2
) (

  input  logic clk,

  // Bu alanin hard reset'i. CIPLAK, senkronlanmamis gelir -- senkronlamak bu
  // modulun isi.
  input  logic hard_rst_n_i,

  // Yazilim tarafindan istenen reset (CTRL.SOFT_RESET gibi), istek alaninda
  // uretilmis bir SEVIYE. Bu alanda once senkronlanir, sonra reset'e katilir.
  input  logic soft_req_i,

  // Bu alanin reset'i: async assert, bu alanin saatinde senkron deassert.
  output logic rst_n_o,

  // "Istegi gordum ve reset'imi tutuyorum." Istek alanina geri senkronlanir;
  // istek ancak TUM alanlar onayladiktan sonra birakilabilir.
  output logic ack_o
);

  logic [1:0]        req_sync_q;
  logic [STAGES-1:0] rel_q;

  always_ff @(posedge clk or negedge hard_rst_n_i) begin
    if (!hard_rst_n_i) begin
      // Hard reset altinda istek GORULMUS kabul edilir: boylece hard reset de
      // yumusak reset ile AYNI yoldan dagitilir ve iki yol birbirinden
      // ayrismaz.
      req_sync_q <= 2'b11;
      rel_q      <= '0;
    end else begin
      req_sync_q <= {req_sync_q[0], soft_req_i};

      // Birakma zinciri: istek bu alanda gorulmezken 1'ler kayar. Istek
      // gorulur gorulmez zincir temizlenir, yani assert ANINDA, deassert
      // STAGES cevrim sonra olur.
      rel_q <= req_sync_q[1] ? '0 : {rel_q[STAGES-2:0], 1'b1};
    end
  end

  assign rst_n_o = rel_q[STAGES-1];
  assign ack_o   = req_sync_q[1];

endmodule
