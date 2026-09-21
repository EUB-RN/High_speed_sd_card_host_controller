// -----------------------------------------------------------------------------
// ultra_sd_reg
//   Purpose      : Register file. Implements the normative register map of
//                  Table 5-1 exactly: offsets, access types, bit positions and
//                  widths. It carries no AXI signalling of its own -- the
//                  AXI4-Lite handshake lives in rtl/axi4/axi4_lite_slave.sv and
//                  reaches this block as a plain read/write bus -- and no SD
//                  protocol knowledge (Table 4-1).
//
//                  Access template, uniform across every register here:
//                    * read  -- 0 cycle: rd_data and rresp_r are combinational
//                               from rd_addr, valid in the same cycle as rd_en,
//                               so the bus slave can register them on the same
//                               edge it accepted the address.
//                    * write -- 1 cycle: wr_en is sampled on the edge, so the
//                               new register value and bresp_r are both visible
//                               on the cycle after the request.
//
//   Clock domain : clk (system clock). Status and counter inputs are expected
//                  already synchronised into this domain by their producer --
//                  the SD-clock counters of Table 5-2 cross in ultra_sd_axi.
//   Reset scheme : rst_n, asynchronous assert / synchronous deassert (R-CLK-1)
//   Implements   : Spec Section 5.3 (Table 5-1), 5.4 (Table 5-2 counters),
//                  R-IF-2, R-IF-3, R-IF-4, R-IF-10, R-IF-12,
//                  R-DEG-1, R-DEG-2, R-DEG-4
// -----------------------------------------------------------------------------
module ultra_sd_reg
  import ultra_sd_pkg::*;
#(
  // Byte address of offset 0x00 of this block in the host address map. The
  // block owns the 256-byte window above it; anything else answers SLVERR.
  parameter logic [31:0] SD_ULTRA_BASE_ADDR = 32'h0000_0000,
  parameter logic [7:0]  VERSION_MAJOR      = 8'h01,
  parameter logic [7:0]  VERSION_MINOR      = 8'h00
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- Bus arayuzu: write (1 cycle) ----------------------------------------
  input  logic        wr_en,
  input  logic [31:0] wr_addr,
  input  logic [31:0] wr_data,
  input  logic [3:0]  wr_strb,
  output logic [1:0]  bresp_r,

  // ---- Bus arayuzu: read (0 cycle) -----------------------------------------
  input  logic        rd_en,
  input  logic [31:0] rd_addr,
  output logic [31:0] rd_data,
  output logic [1:0]  rresp_r,

  // ---- CTRL, self-clearing single-cycle pulses (0x04, W1S) -----------------
  output logic        ctrl_start,
  output logic        ctrl_abort,
  output logic        ctrl_stat_clear,
  output logic        ctrl_soft_reset,

  // ---- STATUS inputs (0x08, RO) --------------------------------------------
  input  logic        sts_busy,
  input  logic        sts_done,
  input  logic        sts_card_present, // from sd_cd, active low at the pad
  input  logic        sts_card_ready,
  input  speed_e      sts_speed_mode,   // Table 7-1 fallback, R-DEG-5
  input  logic [1:0]  sts_bus_width,    // 0 = 1-bit, 1 = 4-bit
  input  err_e        sts_err,          // valid while DONE (R-IF-4)
  input  logic [31:0] sts_card_blk,     // capacity in 512 B blocks

  // ---- transfer request, latched at CTRL.START (R-IF-3) --------------------
  output logic [31:0] cfg_lba,
  output logic [23:0] cfg_blocks,
  output logic        cfg_dir,          // 0 = read, 1 = write

  // ---- runtime configuration, live (R-DEG-1, R-DEG-2, R-DEG-4) -------------
  output logic [7:0]  cfg_clk_div,
  output logic [3:0]  cfg_sample_phase,
  output logic        cfg_force_1bit,
  output logic        cfg_force_ds,

  // ---- statistics counters, Table 5-2 (R-IF-11) ----------------------------
  input  logic [31:0] stat_data,
  input  logic [31:0] stat_gap,
  input  logic [31:0] stat_busy,
  input  logic [15:0] stat_retry_crc,
  input  logic [15:0] stat_retry_cmd,

  // ---- interrupt (R-IF-10) --------------------------------------------------
  input  logic        irq_set_done,
  input  logic        irq_set_err,
  input  logic        irq_set_card_change,
  output logic        irq
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  // CTRL bit positions, Table 5-1
  localparam int unsigned CTRL_START_BIT      = 0;
  localparam int unsigned CTRL_ABORT_BIT      = 1;
  localparam int unsigned CTRL_STAT_CLEAR_BIT = 2;
  localparam int unsigned CTRL_SOFT_RESET_BIT = 3;

  // IRQ bit positions, shared by IRQ_EN and IRQ_STAT
  localparam int unsigned IRQ_DONE_BIT        = 0;
  localparam int unsigned IRQ_ERR_BIT         = 1;
  localparam int unsigned IRQ_CARD_CHANGE_BIT = 2;

  // ---------------------------------------------------------------------------
  // Address decode. Word-aligned: the two low address bits select byte lanes
  // within a word and never select a register, and everything above bit 7 is
  // outside this block's 256-byte window.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSED */ // [1:0] are byte lanes, not register select
  logic [31:0] wr_off, rd_off;
  /* verilator lint_on UNUSED */
  logic [7:0]  wr_reg, rd_reg;
  logic        wr_in_window, rd_in_window;

  assign wr_off = wr_addr - SD_ULTRA_BASE_ADDR;
  assign rd_off = rd_addr - SD_ULTRA_BASE_ADDR;

  assign wr_reg = {wr_off[7:2], 2'b00};
  assign rd_reg = {rd_off[7:2], 2'b00};

  assign wr_in_window = (wr_off[31:8] == '0);
  assign rd_in_window = (rd_off[31:8] == '0);

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------
  logic [31:0] lba_q, lba_latched_q;
  logic [23:0] blocks_q, blocks_latched_q;
  logic        xfer_dir_q, xfer_dir_latched_q;
  logic [7:0]  cfg_clk_q;
  logic [3:0]  sample_phase_q;
  logic        force_1bit_q, force_ds_q;
  logic [2:0]  irq_en_q, irq_stat_q;

  assign cfg_lba          = lba_latched_q;
  assign cfg_blocks       = blocks_latched_q;
  assign cfg_dir          = xfer_dir_latched_q;
  assign cfg_clk_div      = cfg_clk_q;
  assign cfg_sample_phase = sample_phase_q;
  assign cfg_force_1bit   = force_1bit_q;
  assign cfg_force_ds     = force_ds_q;

  // Level output, asserted while any enabled and pending source is set. Cleared
  // by writing 1 to the corresponding IRQ_STAT bit, not by this expression.
  assign irq = |(irq_stat_q & irq_en_q);

  // ---------------------------------------------------------------------------
  // Read path -- 0 cycle latency
  // ---------------------------------------------------------------------------
  logic rd_hit;

  always_comb begin
    rd_data = 32'h0;
    rd_hit  = 1'b1;
    unique case (rd_reg)
      REG_VERSION:    rd_data = {VERSION_MAGIC, VERSION_MAJOR, VERSION_MINOR};
      REG_CTRL:       rd_data = 32'h0; // W1S, self-clearing: reads back as zero
      REG_STATUS:     rd_data = {24'h0, sts_bus_width, sts_speed_mode,
                                 sts_card_ready, sts_card_present,
                                 sts_done, sts_busy};
      REG_ERR:        rd_data = {24'h0, sts_err};
      REG_LBA:        rd_data = lba_q;
      REG_BLOCKS:     rd_data = {8'h0, blocks_q};
      REG_XFER:       rd_data = {31'h0, xfer_dir_q};
      REG_CFG_CLK:    rd_data = {24'h0, cfg_clk_q};
      REG_CFG_PHY:    rd_data = {26'h0, force_ds_q, force_1bit_q,
                                 sample_phase_q};
      REG_CARD_BLK:   rd_data = sts_card_blk;
      REG_STAT_DATA:  rd_data = stat_data;
      REG_STAT_GAP:   rd_data = stat_gap;
      REG_STAT_BUSY:  rd_data = stat_busy;
      REG_STAT_RETRY: rd_data = {stat_retry_cmd, stat_retry_crc};
      REG_IRQ_EN:     rd_data = {29'h0, irq_en_q};
      REG_IRQ_STAT:   rd_data = {29'h0, irq_stat_q};
      default:        rd_hit  = 1'b0; // unmapped: SLVERR, never a hang (R-IF-2)
    endcase
  end

  // The response is only meaningful for a cycle the bus slave is actually
  // reading in, so an idle bus never presents a stale error.
  assign rresp_r = (rd_en && !(rd_hit && rd_in_window)) ? RESP_SLVERR
                                                        : RESP_OKAY;

  // ---------------------------------------------------------------------------
  // Write path -- 1 cycle latency
  // ---------------------------------------------------------------------------

  // Byte-strobed update of one 32-bit register.
  function automatic logic [31:0] strb_merge(input logic [31:0] old_val,
                                             input logic [31:0] new_val,
                                             input logic [3:0]  strb);
    logic [31:0] merged;
    for (int unsigned i = 0; i < 4; i++) begin
      merged[i*8 +: 8] = strb[i] ? new_val[i*8 +: 8] : old_val[i*8 +: 8];
    end
    return merged;
  endfunction

  logic [31:0] merged_lba;
  logic [23:0] merged_blocks;

  assign merged_lba = strb_merge(lba_q, wr_data, wr_strb);

  // BLOCKS is 24 bits wide, so only three byte lanes take part.
  assign merged_blocks = {wr_strb[2] ? wr_data[23:16] : blocks_q[23:16],
                          wr_strb[1] ? wr_data[15:8]  : blocks_q[15:8],
                          wr_strb[0] ? wr_data[7:0]   : blocks_q[7:0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bresp_r            <= RESP_OKAY;
      ctrl_start         <= 1'b0;
      ctrl_abort         <= 1'b0;
      ctrl_stat_clear    <= 1'b0;
      ctrl_soft_reset    <= 1'b0;
      lba_q              <= 32'h0;
      blocks_q           <= 24'h1;
      xfer_dir_q         <= 1'b0;
      cfg_clk_q          <= 8'hFF; // slowest division: init runs at <= 400 kHz
      sample_phase_q     <= 4'h0;
      force_1bit_q       <= 1'b0;
      force_ds_q         <= 1'b0;
      irq_en_q           <= 3'h0;
      irq_stat_q         <= 3'h0;
      lba_latched_q      <= 32'h0;
      blocks_latched_q   <= 24'h1;
      xfer_dir_latched_q <= 1'b0;
    end else begin
      // W1S control bits are single-cycle pulses, so they clear themselves
      // whether or not anything downstream consumed them.
      ctrl_start      <= 1'b0;
      ctrl_abort      <= 1'b0;
      ctrl_stat_clear <= 1'b0;
      ctrl_soft_reset <= 1'b0;

      if (wr_en) begin
        bresp_r <= wr_in_window ? RESP_OKAY : RESP_SLVERR;

        unique case (wr_reg)
          REG_CTRL: begin
            ctrl_start      <= wr_strb[0] && wr_data[CTRL_START_BIT];
            ctrl_abort      <= wr_strb[0] && wr_data[CTRL_ABORT_BIT];
            ctrl_stat_clear <= wr_strb[0] && wr_data[CTRL_STAT_CLEAR_BIT];
            ctrl_soft_reset <= wr_strb[0] && wr_data[CTRL_SOFT_RESET_BIT];
            // R-IF-3: the request is sampled here and nowhere else, so writes
            // to LBA / BLOCKS / XFER during a transfer cannot disturb it.
            if (wr_strb[0] && wr_data[CTRL_START_BIT]) begin
              lba_latched_q      <= lba_q;
              blocks_latched_q   <= blocks_q;
              xfer_dir_latched_q <= xfer_dir_q;
            end
          end
          REG_LBA:      lba_q      <= merged_lba;
          REG_BLOCKS:   blocks_q   <= merged_blocks;
          REG_XFER:     if (wr_strb[0]) xfer_dir_q <= wr_data[0];
          REG_CFG_CLK:  if (wr_strb[0]) cfg_clk_q  <= wr_data[7:0];
          REG_CFG_PHY:
            if (wr_strb[0]) begin
              sample_phase_q <= wr_data[3:0];
              force_1bit_q   <= wr_data[4];
              force_ds_q     <= wr_data[5];
            end
          REG_IRQ_EN:   if (wr_strb[0]) irq_en_q <= wr_data[2:0];
          REG_IRQ_STAT: ; // W1C, handled with the set sources below
          REG_VERSION, REG_STATUS, REG_ERR, REG_CARD_BLK, REG_STAT_DATA,
          REG_STAT_GAP, REG_STAT_BUSY, REG_STAT_RETRY: ; // RO: write ignored
          default: bresp_r <= RESP_SLVERR; // unmapped offset (R-IF-2)
        endcase
      end

      // IRQ_STAT: set from hardware, cleared by writing 1. A set arriving in
      // the same cycle as its clear wins, so an event is never lost.
      for (int unsigned i = 0; i < 3; i++) begin
        logic set_i, clr_i;
        set_i = (i == IRQ_DONE_BIT) ? irq_set_done :
                (i == IRQ_ERR_BIT)  ? irq_set_err  : irq_set_card_change;
        clr_i = wr_en && (wr_reg == REG_IRQ_STAT) && wr_strb[0] && wr_data[i];
        if (set_i)      irq_stat_q[i] <= 1'b1;
        else if (clr_i) irq_stat_q[i] <= 1'b0;
      end
    end
  end

endmodule
