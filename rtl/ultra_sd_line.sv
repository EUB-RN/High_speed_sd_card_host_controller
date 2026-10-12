
module ultra_sd_line
  import ultra_sd_pkg::*;
#(

  parameter int XFER_BYTES = BLOCK_BYTES,

  parameter bit          WORD_LITTLE_ENDIAN = 1'b1,

  parameter int STAT_WAIT_MAX = 16
) (

  input  logic                     line_clk,
  input  logic                     rst_n,
  input  logic                     soft_clr,   // SENKRON yazilim clear'i

  input  logic                     bus_wide_i,  // 1 = 4-bit, 0 = 1-bit

  // Table 5-2'nin iki sayaci bu modulde, cunku olaylari bu FSM'in kollari:
  // veri hucresi SEG_DATA, kart mesguliyeti CELL_IDLE'da DAT0'in alcak
  // kalmasi. Silme komutu toggle olarak gelir (cdc.md 9).
  input  logic                     stat_clear_tgl_i,
  output logic [31:0]              stat_data_o,
  output logic [31:0]              stat_busy_o,
  input  logic                     dir_i,
  input  logic                     start_i,
  input  logic [10:0]              xfer_bytes_i,

  input  logic [31:0]              tx_data_i,
  output logic                     tx_take_o,
  output logic                     tx_busy_o,
  output logic                     tx_done_o,
  output logic [2:0]               tx_status_o,
  output logic                     tx_status_ok_o,
  output logic                     tx_status_tmo_o,

  output logic [31:0]              rx_data_o,
  output logic                     rx_valid_o,
  output logic                     rx_busy_o,
  output logic                     rx_done_o,
  output logic                     rx_crc_ok_o,

  output logic                     dat_active_o,

  output logic                     card_busy_o,

  output logic [SD_DATA_LANES-1:0] dat_out_o,
  output logic [SD_DATA_LANES-1:0] dat_oe_o,
  input  logic [SD_DATA_LANES-1:0] dat_in_i
);

  // ---------------------------------------------------------------------------
  // CERCEVE = TEK SERILESTIRICI
  // ---------------------------------------------------------------------------
  // SD'nin veri cercevesi, yonden bagimsiz olarak ayni uc parcadir:
  //
  //   ARM          TX: start bitini sur        RX: start bitini bekle
  //   XFER/SEG_DATA  N grup yuk  (hat genisligi kadar bit / cevrim)
  //   XFER/SEG_CRC   16 grup CRC16 (TX: kaydir-cikar, RX: katla-dogrula)
  //   XFER/SEG_TAIL  TX'in stop biti (RX'te yok, cerceve CRC'de biter)
  //
  // Eskiden her parca icin ayri bir durum vardi (TX_DATA/TX_CRC/TX_END ve
  // RX_ARM/RX_DATA/RX_CRC/RX_END). Oysa parcalarin FARKI yalnizca iki mux:
  // bitin kaynagi (kaydirici / CRC / '1') ve CRC'nin katlanip mi kaydirilip mi
  // isletildigi. Yon de bir muxtan fazlasi degil. Dolayisiyla TX ve RX ayni
  // durumlari paylasir; dir_q sadece bir secim bitidir.
  //
  // Ayrica sayac TEK: her parca "yukle, geri say, sifirda kol degistir" der.
  // Grup sayaci, CRC sayaci ve durum token'i sayaci ayni cnt_q'dur -- donanimin
  // hangi parcada oldugunu seg_q disinda bir yerde ikinci kez bilmesi gerekmez.
  //
  // Donanimin BILMEDIGI seyler: blok sinirlari, retry, endian politikasi
  // (parametre, kosullu mantik degil), hangi komutun sonucu oldugu. Cerceve
  // uzunlugu disaridan xfer_bytes_i ile gelir; burada yalnizca sozlesme disi
  // degerin FSM'i kilitlemesini onleyen tek bir geri donus var.
  // ---------------------------------------------------------------------------

  localparam int WORD_W     = 32;
  localparam int XFER_WORDS = XFER_BYTES / 4;

  localparam int WORD_CNT_W = $clog2(XFER_WORDS + 1);

  localparam int WIDE_BITS   = 4;
  localparam int NARROW_BITS = 1;

  // Tek sayac: en genis kol yuk grubu (1-bit modda 32), geri kalanlar CRC16 ve
  // durum token'i beklemesi.
  localparam int CNT_LIM0 = (WORD_W > CRC16_W) ? WORD_W : CRC16_W;
  localparam int CNT_LIM  = (CNT_LIM0 > STAT_WAIT_MAX) ? CNT_LIM0 : STAT_WAIT_MAX;
  localparam int CNT_W    = $clog2(CNT_LIM + 1);

  initial begin
    if ((XFER_BYTES % 4) != 0) begin
      $fatal(1, "ultra_sd_line: XFER_BYTES (%0d) 4'un kati olmali", XFER_BYTES);
    end
  end

  function automatic logic [CNT_W-1:0] groups_per_word(logic wide);
    groups_per_word = wide ? CNT_W'(WORD_W / WIDE_BITS)
                           : CNT_W'(WORD_W / NARROW_BITS);
  endfunction

  function automatic logic [WORD_W-1:0] word_swizzle(logic [WORD_W-1:0] d);
    if (WORD_LITTLE_ENDIAN) begin
      word_swizzle = {d[7:0], d[15:8], d[23:16], d[31:24]};
    end else begin
      word_swizzle = d;
    end
  endfunction

  typedef enum logic [2:0] {
    CELL_IDLE,
    CELL_ARM,    // TX: start biti  / RX: start bitini bekle
    CELL_XFER,   // yuk + CRC + (TX) stop biti
    CELL_SWAIT,  // TX: CRC durum token'inin start bitini bekle
    CELL_SREAD   // TX: 3 bitlik durum
  } cell_e;

  typedef enum logic [1:0] { SEG_DATA, SEG_CRC, SEG_TAIL } seg_e;

  cell_e                     cell_q;
  seg_e                      seg_q;
  logic                      wide_q;
  logic                      dir_q;
  logic [CNT_W-1:0]          cnt_q;
  logic [WORD_CNT_W-1:0]     word_q;
  logic [WORD_CNT_W-1:0]     xfer_words_q;
  // start_i / dir_i artik AYNI saatten gelir: L3 (ultra_sd_block) saat
  // birlestirmesinden sonra bu modulle ayni agda kosuyor. Asagidaki iki
  // kademe bu yuzden SENKRONIZER DEGIL, bilincli bir boru hatti: L3'un arm
  // muhasebesi (arm_left_q / rx_arm_taken) tam bu gecikmeye gore kurulu.
  logic [1:0]                start_sync_q;
  logic                      dir_sync_q;

  // bus_wide_i ise GERCEK bir crossing: system_controller clk alaninda uretir
  // (cdc.md 6). Tek bit, dolayisiyla iki flopluk senkronizer yeterli ve
  // gereklidir -- eskiden dogrudan ornekleniyordu, yani belgelenen yapi RTL'de
  // yoktu. Transfer basinda wide_q'ya kilitlenir, L1 maskeyi ondan turetir.
  logic [1:0]                wide_sync_q;

  logic [CRC16_W-1:0]        crc_q [SD_DATA_LANES];
  logic [CRC16_W-1:0]        crc_d [SD_DATA_LANES];

  logic [WORD_W-2:0]         rx_sh_q;
  logic [WORD_W-1:0]         rx_data_q;
  logic                      rx_valid_q;
  logic                      rx_done_q;
  logic                      rx_crc_ok_q;
  logic                      tx_done_q;
  logic [1:0]                stat_sh_q;   // token'in ilk 2 biti; 3.'su anlik
  logic [2:0]                tx_status_q;
  logic                      tx_status_ok_q;
  logic                      tx_status_tmo_q;
  logic                      card_busy_q;

  logic [WORD_W-1:0]         tx_sh_q;
  logic [SD_DATA_LANES-1:0]  dat_out_q;
  logic [SD_DATA_LANES-1:0]  dat_oe_q;

  // Table 5-2 sayaclari ve silme komutunun senkronizeri (cdc.md 9). Sayaclar
  // bu modulun saatinde, yani SD cevrimi sayar (R-IF-11).
  logic [STAT_DUR_W-1:0]     stat_data_q;
  logic [STAT_DUR_W-1:0]     stat_busy_q;
  logic [1:0]                clr_sync_q;
  logic                      clr_q;
  logic                      stat_clear;

  assign stat_clear = clr_sync_q[1] ^ clr_q;

  // Hat maskesi wide_q'nun saf bir fonksiyonudur: kendi flopunu tutmasi
  // gereksiz. Genislik transfer basinda wide_q'ya kilitlenir, maske onu izler.
  logic [SD_DATA_LANES-1:0]  lane_mask;
  assign lane_mask = wide_q ? 4'b1111 : 4'b0001;

  // Cerceve icinde miyiz: durum kodunun kendisi soyler, ayrica kod cozmeye
  // gerek yok. Yon tek bir latch'li bit.
  logic cell_busy;
  assign cell_busy = (cell_q != CELL_IDLE);

  logic in_data;
  logic in_crc;
  assign in_data = (cell_q == CELL_XFER) && (seg_q == SEG_DATA);
  assign in_crc  = (cell_q == CELL_XFER) && (seg_q == SEG_CRC);

  // Tek sayacin tek yorumu: "bu kolun son cevrimi".
  logic cnt_last;
  logic block_last;
  assign cnt_last   = (cnt_q == CNT_W'(1));
  assign block_last = (word_q == (xfer_words_q - WORD_CNT_W'(1)));

  // ---------------------------------------------------------------------------
  // CRC16: hat basina bir ornek. Besleme biti yone gore tek mux.
  // ---------------------------------------------------------------------------
  logic [SD_DATA_LANES-1:0] crc_bit;
  assign crc_bit = dir_q ? dat_out_q : dat_in_i;

  for (genvar l = 0; l < SD_DATA_LANES; l++) begin : g_crc
    ultra_sd_crc16 #(
      .IN_WIDTH (1)
    ) u_crc16 (
      .crc_i  (crc_q[l]),
      .data_i (crc_bit[l]),
      .crc_o  (crc_d[l])
    );
  end

  // TX yukte katlar, CRC kolunda kaydirip disari verir. RX hem yukte hem CRC
  // kolunda katlar; 16 bit sonra kalan sifirsa cerceve saglamdir.
  logic crc_fold_en;
  logic crc_shift_en;
  assign crc_fold_en  = in_data || (in_crc && !dir_q);
  assign crc_shift_en = in_crc && dir_q;

  // Son katlamanin sonucu (crc_d), cunku RX'in kararini verdigi cevrim CRC
  // kolunun son cevrimidir: ayri bir bitis durumu gerekmez.
  logic rx_crc_zero;
  always_comb begin
    rx_crc_zero = 1'b1;
    for (int i = 0; i < SD_DATA_LANES; i++) begin
      if (lane_mask[i] && (crc_d[i] != '0)) rx_crc_zero = 1'b0;
    end
  end

  logic [WORD_W-1:0] rx_sh_next;
  always_comb begin
    if (wide_q) begin
      rx_sh_next = {rx_sh_q[WORD_W-1-WIDE_BITS:0], dat_in_i[WIDE_BITS-1:0]};
    end else begin
      rx_sh_next = {rx_sh_q, dat_in_i[0]};
    end
  end

  always_ff @(posedge line_clk or negedge rst_n) begin
    if (!rst_n) begin
      cell_q       <= CELL_IDLE;
      seg_q        <= SEG_DATA;
      wide_q       <= 1'b0;
      dir_q        <= 1'b0;
      cnt_q        <= '0;
      word_q       <= '0;
      xfer_words_q <= WORD_CNT_W'(XFER_WORDS);
      start_sync_q <= '0;
      dir_sync_q   <= 1'b0;
      wide_sync_q  <= '0;
      rx_sh_q      <= '0;
      rx_data_q    <= '0;
      rx_valid_q   <= 1'b0;
      rx_done_q    <= 1'b0;
      rx_crc_ok_q  <= 1'b0;
      tx_done_q       <= 1'b0;
      stat_sh_q       <= '0;
      tx_status_q     <= '0;
      tx_status_ok_q  <= 1'b0;
      tx_status_tmo_q <= 1'b0;
      card_busy_q     <= 1'b0;
      stat_data_q     <= '0;
      stat_busy_q     <= '0;
      clr_sync_q      <= 2'b00;
      clr_q           <= 1'b0;
      for (int i = 0; i < SD_DATA_LANES; i++) begin
        crc_q[i] <= CRC16_INIT;
      end
    end else begin
      start_sync_q <= {start_sync_q[0], start_i};
      dir_sync_q   <= dir_i;
      wide_sync_q  <= {wide_sync_q[0], bus_wide_i};

      rx_valid_q <= 1'b0;
      rx_done_q  <= 1'b0;
      tx_done_q  <= 1'b0;

      clr_sync_q <= {clr_sync_q[0], stat_clear_tgl_i};
      clr_q      <= clr_sync_q[1];

      // STAT_BUSY: kart mesguliyeti, card_busy_q'nun ta kendisi -- ayni
      // satirin yaninda sayiliyor. Saturasyonlu.
      card_busy_q <= !cell_busy && !dat_in_i[0];

      if (stat_clear) begin
        stat_data_q <= '0;
        stat_busy_q <= '0;
      end else begin
        // STAT_DATA yalniz yuk kolunda, STAT_BUSY yalniz bostayken sayar;
        // ikisi de ayri bir kol degil, ayni FSM'in iki sifati. Saturasyonlu.
        if (in_data && !(&stat_data_q)) begin
          stat_data_q <= stat_data_q + STAT_DUR_W'(1);
        end
        if (!cell_busy && !dat_in_i[0] && !(&stat_busy_q)) begin
          stat_busy_q <= stat_busy_q + STAT_DUR_W'(1);
        end
      end

      for (int i = 0; i < SD_DATA_LANES; i++) begin
        if (lane_mask[i]) begin
          if (crc_fold_en) begin
            crc_q[i] <= crc_d[i];
          end else if (crc_shift_en) begin
            crc_q[i] <= {crc_q[i][CRC16_W-2:0], 1'b0};
          end
        end
      end

      case (cell_q)

        CELL_IDLE: begin
          if (start_sync_q[1]) begin

            wide_q <= wide_sync_q[1];
            dir_q  <= dir_sync_q;
            word_q <= '0;

            // Uzunluk disaridan gelir. Tek kontrol, FSM'i sonsuza kilitleyecek
            // (0 ya da tasmis) degere karsi: donanim politika uretmez, sadece
            // kendini kilitlemez.
            if ((xfer_bytes_i >= 11'd4) &&
                (xfer_bytes_i <= 11'(XFER_BYTES)) &&
                (xfer_bytes_i[1:0] == 2'b00))
              xfer_words_q <= WORD_CNT_W'(xfer_bytes_i >> 2);
            else
              xfer_words_q <= WORD_CNT_W'(XFER_WORDS);

            for (int i = 0; i < SD_DATA_LANES; i++) begin
              crc_q[i] <= CRC16_INIT;
            end
            cell_q <= CELL_ARM;
          end
        end

        // TX icin tek cevrim (start biti negedge'de surulur), RX icin start
        // bitini bekleme. Ayni kol, tek kosul.
        CELL_ARM: begin
          if (dir_q || !dat_in_i[0]) begin
            rx_sh_q <= '0;
            cnt_q   <= groups_per_word(wide_q);
            seg_q   <= SEG_DATA;
            cell_q  <= CELL_XFER;
          end
        end

        CELL_XFER: begin
          case (seg_q)

            SEG_DATA: begin
              if (!dir_q) rx_sh_q <= rx_sh_next[WORD_W-2:0];

              if (!cnt_last) begin
                cnt_q <= cnt_q - CNT_W'(1);
              end else begin
                // Kelime siniri: RX kelimeyi teslim eder, TX siradakini ister
                // (tx_take_o). Son kelimeden sonra CRC koluna gecilir.
                if (!dir_q) begin
                  rx_data_q  <= word_swizzle(rx_sh_next);
                  rx_valid_q <= 1'b1;
                end
                if (!block_last) begin
                  cnt_q  <= groups_per_word(wide_q);
                  word_q <= word_q + WORD_CNT_W'(1);
                end else begin
                  cnt_q <= CNT_W'(CRC16_W);
                  seg_q <= SEG_CRC;
                end
              end
            end

            SEG_CRC: begin
              if (!cnt_last) begin
                cnt_q <= cnt_q - CNT_W'(1);
              end else if (dir_q) begin
                seg_q <= SEG_TAIL;
              end else begin
                // RX'in cercevesi CRC ile biter: kalan bu cevrimde sifir mi?
                rx_crc_ok_q <= rx_crc_zero;
                rx_done_q   <= 1'b1;
                cell_q      <= CELL_IDLE;
              end
            end

            default: begin  // SEG_TAIL: stop biti surulurken token beklemesi
              tx_status_tmo_q <= 1'b0;
              cnt_q           <= CNT_W'(STAT_WAIT_MAX);
              cell_q          <= CELL_SWAIT;
            end
          endcase
        end

        CELL_SWAIT: begin
          if (!dat_in_i[0]) begin
            cnt_q  <= CNT_W'(3);
            cell_q <= CELL_SREAD;
          end else if (cnt_last) begin
            tx_status_tmo_q <= 1'b1;
            tx_status_ok_q  <= 1'b0;
            tx_done_q       <= 1'b1;
            cell_q          <= CELL_IDLE;
          end else begin
            cnt_q <= cnt_q - CNT_W'(1);
          end
        end

        // Durum token'i: 3 bit. Son bit icin ayri bir durum tutmak yerine o
        // cevrimde kaydiricinin sonuna eklenir.
        CELL_SREAD: begin
          stat_sh_q <= {stat_sh_q[0], dat_in_i[0]};
          if (!cnt_last) begin
            cnt_q <= cnt_q - CNT_W'(1);
          end else begin
            tx_status_q    <= {stat_sh_q, dat_in_i[0]};
            tx_status_ok_q <= ({stat_sh_q, dat_in_i[0]} == 3'b010);
            tx_done_q      <= 1'b1;
            cell_q         <= CELL_IDLE;
          end
        end

        default: cell_q <= CELL_IDLE;
      endcase

      if (soft_clr) begin
        cell_q       <= CELL_IDLE;
        seg_q        <= SEG_DATA;
        dir_q        <= 1'b0;
        cnt_q        <= '0;
        rx_valid_q   <= 1'b0;
        rx_done_q    <= 1'b0;
        rx_crc_ok_q  <= 1'b0;
        tx_done_q       <= 1'b0;
        tx_status_q     <= '0;
        tx_status_ok_q  <= 1'b0;
        tx_status_tmo_q <= 1'b0;
        card_busy_q     <= 1'b0;
        for (int i = 0; i < SD_DATA_LANES; i++) begin
          crc_q[i] <= CRC16_INIT;
        end

        // Preserve registers not reset by software clear.
        clr_q <= clr_q;
        clr_sync_q <= clr_sync_q;
        dir_sync_q <= dir_sync_q;
        rx_data_q <= rx_data_q;
        rx_sh_q <= rx_sh_q;
        start_sync_q <= start_sync_q;
        stat_busy_q <= stat_busy_q;
        stat_data_q <= stat_data_q;
        stat_sh_q <= stat_sh_q;
        wide_q <= wide_q;
        wide_sync_q <= wide_sync_q;
        word_q <= word_q;
        xfer_words_q <= xfer_words_q;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TX cikis yolu: tek mux, tek kaydirici. Hangi parcada oldugumuzu seg_q
  // soyler; pedler yalnizca yon TX oldugunda ve cerceve icinde surulur.
  // ---------------------------------------------------------------------------
  logic [SD_DATA_LANES-1:0] crc_top;
  for (genvar l = 0; l < SD_DATA_LANES; l++) begin : g_crc_top
    assign crc_top[l] = crc_q[l][CRC16_W-1];
  end

  logic [SD_DATA_LANES-1:0] grp_bits;
  always_comb begin
    if (wide_q) begin
      grp_bits = tx_sh_q[WORD_W-1 -: WIDE_BITS];
    end else begin
      grp_bits = {{(SD_DATA_LANES-1){1'b1}}, tx_sh_q[WORD_W-1]};
    end
  end

  logic [SD_DATA_LANES-1:0] tx_grp;
  always_comb begin
    if (cell_q == CELL_ARM)        tx_grp = '0;             // start biti
    else if (seg_q == SEG_DATA)    tx_grp = grp_bits;       // yuk
    else if (seg_q == SEG_CRC)     tx_grp = crc_top;        // CRC16
    else                           tx_grp = '1;             // stop biti
  end

  logic tx_drive;
  assign tx_drive = dir_q && ((cell_q == CELL_ARM) || (cell_q == CELL_XFER));

  logic [WORD_W-1:0] tx_sh_shift;
  always_comb begin
    if (wide_q) begin
      tx_sh_shift = {tx_sh_q[WORD_W-1-WIDE_BITS:0], {WIDE_BITS{1'b0}}};
    end else begin
      tx_sh_shift = {tx_sh_q[WORD_W-1-NARROW_BITS:0], {NARROW_BITS{1'b0}}};
    end
  end

  assign tx_take_o = dir_q && (((cell_q == CELL_ARM)) ||
                               (in_data && cnt_last && !block_last));

  always_ff @(negedge line_clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_sh_q   <= '0;
      dat_out_q <= {SD_DATA_LANES{1'b1}};
      dat_oe_q  <= '0;
    end else begin
      if (tx_drive) begin
        dat_out_q <= (tx_grp & lane_mask) | ~lane_mask;
        dat_oe_q  <= lane_mask;
      end else begin
        dat_out_q <= {SD_DATA_LANES{1'b1}};
        dat_oe_q  <= '0;
      end

      // Kaydiricinin tek kurali var: istedigimiz cevrimde yukle, yuk kolunda
      // kaydir, baska her yerde dur. (tx_take_o start bitinde de yukselir.)
      if (tx_take_o)                      tx_sh_q <= word_swizzle(tx_data_i);
      else if (tx_drive && in_data)       tx_sh_q <= tx_sh_shift;

      if (soft_clr) begin
        dat_oe_q  <= '0;

        // Preserve registers not reset by software clear.
        dat_out_q <= dat_out_q;
        tx_sh_q <= tx_sh_q;
      end
    end
  end

  assign dat_out_o   = dat_out_q;
  assign dat_oe_o    = dat_oe_q;

  assign dat_active_o    = in_data;
  assign tx_busy_o       = cell_busy &&  dir_q;
  assign tx_done_o       = tx_done_q;
  assign tx_status_o     = tx_status_q;
  assign tx_status_ok_o  = tx_status_ok_q;
  assign tx_status_tmo_o = tx_status_tmo_q;
  assign card_busy_o     = card_busy_q;

  assign rx_data_o   = rx_data_q;
  assign rx_valid_o  = rx_valid_q;
  assign rx_busy_o   = cell_busy && !dir_q;
  assign rx_done_o   = rx_done_q;
  assign rx_crc_ok_o = rx_crc_ok_q;

  // Register goruntusu 32 bit kalir (Table 5-2 sozlesmesi); ust bitler sifir.
  assign stat_data_o = {{(32-STAT_DUR_W){1'b0}}, stat_data_q};
  assign stat_busy_o = {{(32-STAT_DUR_W){1'b0}}, stat_busy_q};

endmodule
