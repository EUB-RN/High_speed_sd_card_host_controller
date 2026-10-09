// -----------------------------------------------------------------------------
// clk_controller
//   Purpose      : SD saatinin bolucusu. Serbest kosan, %50 duty, tek kanal.
//   Clock domain : clk_i (sistem saati)
//
//   Eskiden iki kanalliydi (CMD ve LINE), cunku tasarim ikisini ayri birer
//   saat gibi tasiyordu. Kart'in TEK saat pedi var: iki kanal hicbir zaman
//   farkli bir oranda kosamaz, kosarsa ped hangisini surecegi bir secim
//   sorusu haline gelirdi ki bunun dogru cevabi yok. Ikinci kanal bu yuzden
//   ustteki modulde zaten ayni oranla besleniyor ve cikisi bosta birakiliyordu
//   -- yani sentezde supuruluyordu ama kaynak kodda duruyor ve cdc.md'ye
//   olmayan bir "kanal devri" anlatisi yazdiriyordu. Tek kanal, tek anlati.
//   Birden fazla bagimsiz bolunmus saat gerekirse modul bir kez daha
//   ornenklenir; bu, iki kanali tek modulun icine gommekten hem ucuz hem acik.
// -----------------------------------------------------------------------------
module clk_controller
  import ultra_sd_pkg::*;
(

  input  logic                   clk_i,

  input  logic                   rst_n,

  // Bolme orani. 2'nin altindaki her deger 2'ye kirpilir, tek oranlar asagi
  // yuvarlanir (yarim periyot tam sayi olmak zorunda).
  input  logic [CFG_CLK_W-1:0]   div_i,

  output logic                   clk_o
);

  localparam int HALF_W = CFG_CLK_W - 1;

  logic [HALF_W-1:0] half_s;
  logic [HALF_W-1:0] half_cnt;
  logic [HALF_W-1:0] half_q;
  logic              clk_q;

  logic half_done;
  assign half_done = (half_cnt == '0);

  logic period_start;
  assign period_start = half_done & ~clk_q;

  always_ff @(posedge clk_i or negedge rst_n) begin
    if (!rst_n) begin

      half_s   <= '0;
      half_cnt <= '0;
      half_q   <= '0;
      clk_q    <= 1'b0;
    end else begin

      if (div_i < CFG_CLK_W'(2)) begin
        half_s <= HALF_W'(0);
      end else begin
        half_s <= div_i[CFG_CLK_W-1:1] - HALF_W'(1);
      end

      if (half_done) begin
        if (period_start) begin
          half_cnt <= half_s;
          half_q   <= half_s;
          clk_q    <= 1'b1;
        end else begin
          half_cnt <= half_q;
          clk_q    <= 1'b0;
        end
      end else begin
        half_cnt <= half_cnt - HALF_W'(1);
      end
    end
  end

  assign clk_o = clk_q;

endmodule
