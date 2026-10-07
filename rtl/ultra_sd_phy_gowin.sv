

module ultra_sd_phy_gowin
  import ultra_sd_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,

  /* verilator lint_off UNUSED */
  input  logic [CFG_PHY_W-1:0]   cfg_phy_i,
  /* verilator lint_on UNUSED */

  // Bolme orani; ham saatler artik bu modulun ICINDE uretilir.
  input  logic [CFG_CLK_W-1:0]   clk_div_i,

  input  logic                   cmd_clk_en_i,
  input  logic                   line_clk_en_i,
  input  logic                   pad_line_sel_i,

  output logic                   cmd_clk_o,
  output logic                   line_clk_o,

  input  logic                   cmd_out_i,
  input  logic                   cmd_oe_i,
  output logic                   cmd_in_o,

  input  logic [SD_DATA_LANES-1:0] dat_out_i,
  input  logic [SD_DATA_LANES-1:0] dat_oe_i,
  output logic [SD_DATA_LANES-1:0] dat_in_o,

  output logic                   sd_clk,
  inout  wire                    sd_cmd,
  inout  wire  [3:0]             sd_dat
);

  // ---------------------------------------------------------------------------
  // Ham (gate'lenmemis, serbest kosan) SD saatleri. Bolucu sahibin yaninda
  // duruyor: saat uretimi, gate'leme ve ped mux'u artik tek modulde, boylece
  // bolunmus saat fabric'te modul siniri gecmiyor. CMD ve LINE kanallari ayni
  // orandan beslenir, yani faz kilitlidir (doc/cdc.md).
  // ---------------------------------------------------------------------------
  logic cmd_clk_div;
  logic line_clk_div;

  /* verilator lint_off PINCONNECTEMPTY */
  clk_controller u_clk_controller (
    .clk_i      (clk),
    .rst_n      (rst_n),
    .cmd_div_i  (clk_div_i),
    .line_div_i (clk_div_i),
    .cmd_clk_o  (cmd_clk_div),
    .line_clk_o ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // Tek bolucu iki kanali da besler: oranlar esit oldugu icin ikinci kanal
  // yalnizca kopya flop olurdu.
  assign line_clk_div = cmd_clk_div;

  logic [CFG_PHY_PHASE_W-1:0] phase_q;
  logic                       sd_clk_q;
  logic [CFG_PHY_PHASE_W-1:0] phase_cnt_q;
  logic                       samp_pend_q;

  logic sd_clk_fab;
  assign sd_clk_fab = pad_line_sel_i ? (line_clk_div & line_clk_en_i)
                                     : (cmd_clk_div  & cmd_clk_en_i);

  logic sd_rise;
  assign sd_rise = sd_clk_fab & ~sd_clk_q;

  logic samp_en;
  assign samp_en = sd_rise ? ((phase_q == '0) | samp_pend_q)
                           : (samp_pend_q & (phase_cnt_q == '0));

  logic                     cmd_in_q;
  logic [SD_DATA_LANES-1:0] dat_in_q;
  logic                     pad_en_q;

  logic                     cmd_pad_in;
  logic [SD_DATA_LANES-1:0] dat_pad_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

      pad_en_q    <= 1'b0;
      cmd_in_q    <= 1'b1;
      dat_in_q    <= {SD_DATA_LANES{1'b1}};
      phase_q     <= '0;
      sd_clk_q    <= 1'b0;
      phase_cnt_q <= '0;
      samp_pend_q <= 1'b0;
    end else begin

      pad_en_q <= 1'b1;

      phase_q  <= cfg_phy_i[CFG_PHY_PHASE_LSB +: CFG_PHY_PHASE_W];

      sd_clk_q <= sd_clk_fab;

      if (sd_rise) begin

        samp_pend_q <= (phase_q != '0);
        phase_cnt_q <= (phase_q == '0) ? '0
                                       : (phase_q - CFG_PHY_PHASE_W'(1));
      end else if (samp_pend_q) begin
        if (phase_cnt_q != '0) begin
          phase_cnt_q <= phase_cnt_q - CFG_PHY_PHASE_W'(1);
        end else begin
          samp_pend_q <= 1'b0;
        end
      end

      if (samp_en) begin
        cmd_in_q <= cmd_pad_in;
        dat_in_q <= dat_pad_in;
      end
    end
  end

  assign cmd_in_o = cmd_in_q;
  assign dat_in_o = dat_in_q;

  logic                     cmd_oe;
  logic [SD_DATA_LANES-1:0] dat_oe;

  assign cmd_oe = pad_en_q & cmd_oe_i;
  assign dat_oe = {SD_DATA_LANES{pad_en_q}} & dat_oe_i;

  logic cmd_clk_g;
  logic line_clk_g;
  logic sd_clk_pad;

`ifdef ULTRA_SD_NO_VENDOR_PRIM

  logic cmd_ce_q, line_ce_q;

  always_ff @(negedge cmd_clk_div or negedge rst_n) begin
    if (!rst_n) cmd_ce_q <= 1'b0;
    else        cmd_ce_q <= cmd_clk_en_i;
  end

  always_ff @(negedge line_clk_div or negedge rst_n) begin
    if (!rst_n) line_ce_q <= 1'b0;
    else        line_ce_q <= line_clk_en_i;
  end

  assign cmd_clk_g  = cmd_clk_div  & cmd_ce_q;
  assign line_clk_g = line_clk_div & line_ce_q;

  logic dcs_sel_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                           dcs_sel_q <= 1'b0;
    else if (!cmd_clk_g && !line_clk_g)   dcs_sel_q <= pad_line_sel_i;
  end

  assign sd_clk_pad = dcs_sel_q ? line_clk_g : cmd_clk_g;
`else
  DQCE u_dqce_cmd (
    .CLKOUT (cmd_clk_g),
    .CLKIN  (cmd_clk_div),
    .CE     (cmd_clk_en_i)
  );

  DQCE u_dqce_line (
    .CLKOUT (line_clk_g),
    .CLKIN  (line_clk_div),
    .CE     (line_clk_en_i)
  );

  DCS u_dcs_pad (
    .CLKOUT   (sd_clk_pad),
    .CLK0     (cmd_clk_g),
    .CLK1     (line_clk_g),
    .CLK2     (1'b0),
    .CLK3     (1'b0),
    .CLKSEL   ({2'b00, pad_line_sel_i, ~pad_line_sel_i}),
    .SELFORCE (1'b0)
  );
  defparam u_dcs_pad.DCS_MODE = "RISING";
`endif

  assign cmd_clk_o  = cmd_clk_g;
  assign line_clk_o = line_clk_g;

  assign sd_clk = sd_clk_pad;

`ifdef ULTRA_SD_NO_VENDOR_PRIM
  assign sd_cmd     = cmd_oe ? cmd_out_i : 1'bz;
  assign cmd_pad_in = sd_cmd;

  for (genvar ln = 0; ln < SD_DATA_LANES; ln++) begin : g_dat_pad
    assign sd_dat[ln]     = dat_oe[ln] ? dat_out_i[ln] : 1'bz;
    assign dat_pad_in[ln] = sd_dat[ln];
  end
`else
  IOBUF u_iobuf_cmd (
    .O   (cmd_pad_in),
    .IO  (sd_cmd),
    .I   (cmd_out_i),
    .OEN (~cmd_oe)
  );

  for (genvar ln = 0; ln < SD_DATA_LANES; ln++) begin : g_dat_pad
    IOBUF u_iobuf_dat (
      .O   (dat_pad_in[ln]),
      .IO  (sd_dat[ln]),
      .I   (dat_out_i[ln]),
      .OEN (~dat_oe[ln])
    );
  end
`endif

endmodule
