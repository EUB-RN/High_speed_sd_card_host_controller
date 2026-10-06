// -----------------------------------------------------------------------------
// clk_controller
//   Purpose      : Iki adet bolunmus saat uretir ve baska hicbir sey yapmaz.
//                    * cmd_clk_o  : CMD hattina giden saat, clk_i / cmd_div_i
//                    * line_clk_o : DAT hatlarina giden saat, clk_i / line_div_i
//
//                  Bolme orani ciftlenir (tek sayi asagi yuvarlanir) ve en az
//                  2 olacak sekilde kirpilir, boylece uretilen saat %50 duty
//                  cycle'a sahiptir.
//
//                  Reset: rst_n, asenkron assert / senkron deassert (repo
//                  konvansiyonu). Reset altinda her iki saat de ALCAKTA park
//                  eder. Guc acilisinda durumu tanimlamak icin `initial`
//                  kullanilmaz; bu simulasyon yapisidir, sentezlenebilir
//                  donanim degildir.
//
//                  Gateleme kombinasyonel DEGILDIR: enable girisi once
//                  flop'lanir, sonra yalnizca periyot sinirinda (alcak fazin
//                  sonunda) devreye girer. Bu yuzden enable'in kalkmasi ya da
//                  dusmesi calismakta olan bir fazi kisaltamaz, runt pulse
//                  uretemez. Saat kapaliyken cikis alcakta park eder ve her
//                  cikis dogrudan bir flop'tan surulur.
//
//   Clock domain : sadece clk_i. cmd_clk_o / line_clk_o uretilmis saatlerdir
//                  ve .sdc icinde generated clock olarak tanimlanir; bu modul
//                  icinde saat olarak kullanilmazlar.
// -----------------------------------------------------------------------------
module clk_controller
  import ultra_sd_pkg::*;
(
  // 1) ana sistem saati
  input  logic                   clk_i,

  // reset: asenkron assert, senkron deassert. Altyapi girisi.
  input  logic                   rst_n,

  // 2) CMD saatinin bolme orani
  input  logic [CFG_CLK_W-1:0]   cmd_div_i,

  // 3) LINE saatinin bolme orani
  input  logic [CFG_CLK_W-1:0]   line_div_i,

  // 4) CMD saatini gateleme (0 = alcakta park et)
  input  logic                   cmd_en_i,

  // 5) LINE saatini gateleme (0 = alcakta park et)
  input  logic                   line_en_i,

  output logic                   cmd_clk_o,
  output logic                   line_clk_o
);

  // Yarim periyot sayaci: oran/2 - 1. Sayac sifira kadar geri sayar.
  localparam int HALF_W = CFG_CLK_W - 1;

  // 0 = CMD kanali, 1 = LINE kanali. Iki kanal da ayni devredir.
  localparam int CH_CMD  = 0;
  localparam int CH_LINE = 1;

  logic [CFG_CLK_W-1:0] div_i   [2];
  logic                 en_i    [2];

  assign div_i[CH_CMD]  = cmd_div_i;
  assign div_i[CH_LINE] = line_div_i;
  assign en_i [CH_CMD]  = cmd_en_i;
  assign en_i [CH_LINE] = line_en_i;

  // Kayitli girisler: istenen yarim periyot ve kapilama istegi.
  logic [HALF_W-1:0] half_s   [2];
  logic              en_s     [2];

  // Uretim durumu.
  logic [HALF_W-1:0] half_cnt [2];
  logic [HALF_W-1:0] half_q   [2];
  logic              clk_q    [2];

  for (genvar ch = 0; ch < 2; ch++) begin : g_ch
    // Yarim periyot bitti mi.
    logic half_done;
    assign half_done = (half_cnt[ch] == '0);

    // Periyot siniri: alcak fazin sonu. Oran ve kapilama yalnizca burada
    // degisir.
    logic period_start;
    assign period_start = half_done & ~clk_q[ch];

    always_ff @(posedge clk_i or negedge rst_n) begin
      if (!rst_n) begin
        // Reset altinda saat ALCAKTA park eder ve sayac sifirdan baslar,
        // boylece reset kalkar kalkmaz ilk periyot sinirina ulasilir.
        half_s  [ch] <= '0;
        en_s    [ch] <= 1'b0;
        half_cnt[ch] <= '0;
        half_q  [ch] <= '0;
        clk_q   [ch] <= 1'b0;
      end else begin
        // ---- giris kaydi: oran ciftlenir, en az 2'ye kirpilir ------------
        if (div_i[ch] < CFG_CLK_W'(2)) begin
          half_s[ch] <= HALF_W'(0);                      // /2
        end else begin
          half_s[ch] <= div_i[ch][CFG_CLK_W-1:1] - HALF_W'(1);
        end

        // ---- giris kaydi: kapilama istegi (kombinasyonel degil) ----------
        en_s[ch] <= en_i[ch];

        // ---- bolucu ------------------------------------------------------
        if (half_done) begin
          if (period_start) begin
            half_cnt[ch] <= half_s[ch];  // yeni oran buradan itibaren gecerli
            half_q  [ch] <= half_s[ch];
            clk_q   [ch] <= en_s[ch];    // yalnizca enable'li periyotta yukselir
          end else begin
            half_cnt[ch] <= half_q[ch];  // periyodun ikinci yarisi ayni oranda
            clk_q   [ch] <= 1'b0;
          end
        end else begin
          half_cnt[ch] <= half_cnt[ch] - HALF_W'(1);
        end
      end
    end
  end

  // Her cikis dogrudan bir flop'tan gelir.
  assign cmd_clk_o  = clk_q[CH_CMD];
  assign line_clk_o = clk_q[CH_LINE];

endmodule
