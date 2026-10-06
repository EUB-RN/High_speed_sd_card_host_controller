// -----------------------------------------------------------------------------
// ultra_sd_reg
//
//   NAMING CONVENTION IN THIS FILE
//   -----------------------------
//   UPPER_CASE port names are the CPU-visible registers of Table 5-1. Each one
//   is exactly one register, carried on exactly one port, with its bit fields
//   packed in the positions the table specifies -- CTRL[3:0] is the CTRL
//   register, STATUS[7:0] is the STATUS register, and so on. Field positions
//   are named in ultra_sd_pkg (CTRL_START_BIT, STATUS_SPEED_LSB, ...) so that
//   neither side has to write a bare bit number.
//
//   lower_snake_case names are everything the CPU cannot see: the read/write
//   bus from the AXI4-Lite slave, and internal state.
//
//   Splitting a register into one port per bit -- ctrl_start, ctrl_abort,
//   ctrl_stat_clear, ctrl_soft_reset -- scatters one CPU-visible object across
//   four wires and makes the mapping between hardware and software a thing you
//   have to remember rather than read. One port per register keeps the register
//   context intact. It also keeps the interface narrow: the port count of this
//   block roughly halves.
//
//   What this cannot do is compact the address map. Table 5-1 is normative:
//   the offsets, the access types and the bit positions are fixed, and CTRL
//   occupies a full 32-bit word at 0x04 whether it carries four bits or thirty.
//   Merging offsets would make the core unmeasurable by the harness. The
//   saving here is in the RTL interface, not in the bus.
//
//   Purpose      : Register file. Implements the map of Table 5-1 exactly. It
//                  carries no AXI signalling of its own -- the AXI4-Lite
//                  handshake lives in axi4_lite_slave.sv and reaches this block
//                  as a plain read/write bus -- and no SD protocol knowledge
//                  (Table 4-1).
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
//                  the SD-clock counters of Table 5-2 cross in ultra_sd_axi_top.
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
  input  logic                clk,
  input  logic                rst_n,

  // ---- Bus arayuzu: write (1 cycle) ----------------------------------------
  input  logic                wr_en,
  input  logic [31:0]         wr_addr,
  input  logic [31:0]         wr_data,
  input  logic [3:0]          wr_strb,
  output logic [1:0]          bresp_r,

  // ---- Bus arayuzu: read (0 cycle) -----------------------------------------
  input  logic                rd_en,
  input  logic [31:0]         rd_addr,
  output logic [31:0]         rd_data,
  output logic [1:0]          rresp_r,

  // ---- Registers the CPU writes (0x04 .. 0x20) -----------------------------
  // CTRL is W1S and self-clearing, so these are single-cycle pulses.
  //   [0] START  [1] ABORT  [2] STAT_CLEAR  [3] SOFT_RESET
  output logic [CTRL_W-1:0]    CTRL,
  // LBA, BLOCKS and XFER as latched at CTRL.START (R-IF-3), not as last written.
  output logic [LBA_W-1:0]     LBA,
  output logic [BLOCKS_W-1:0]  BLOCKS,
  output logic                 XFER,      // [0] DIR: 0 = read, 1 = write
  output logic [CFG_CLK_W-1:0] CFG_CLK,   // SD clock divisor (R-DEG-1)
  //   [3:0] SAMPLE_PHASE  [4] FORCE_1BIT  [5] FORCE_DS (R-DEG-2, R-DEG-4)
  output logic [CFG_PHY_W-1:0] CFG_PHY,

  // ---- Registers the CPU reads (0x08 .. 0x34) ------------------------------
  //   [0] BUSY  [1] DONE  [2] CARD_PRESENT  [3] CARD_READY
  //   [5:4] SPEED_MODE (speed_e)  [7:6] BUS_WIDTH (0 = 1-bit, 1 = 4-bit)
  input  logic [STATUS_W-1:0]  STATUS,
  input  err_e                 ERR,        // valid while STATUS.DONE (R-IF-4)
  input  logic [31:0]          CARD_BLK,   // capacity in 512 B blocks
  input  logic [31:0]          STAT_DATA,  // Table 5-2 counters, SD clocks
  input  logic [31:0]          STAT_GAP,
  input  logic [31:0]          STAT_BUSY,
  input  logic [31:0]          STAT_RETRY, // [15:0] CRC, [31:16] command

  // ---- Interrupt (0x38 IRQ_EN, 0x3C IRQ_STAT, R-IF-10) ---------------------
  input  logic [IRQ_W-1:0]     IRQ_SET,    // set pulses: DONE, ERR, CARD_CHANGE
  output logic                 irq         // level output pin, not a register
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

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
  // Storage. The _q copies are what the CPU reads back; LBA, BLOCKS and XFER
  // are driven from the latched copies taken at CTRL.START.
  // ---------------------------------------------------------------------------
  logic [LBA_W-1:0]     lba_q;
  logic [BLOCKS_W-1:0]  blocks_q;
  logic                 xfer_q;
  logic [CFG_CLK_W-1:0] cfg_clk_q;
  logic [CFG_PHY_W-1:0] cfg_phy_q;
  logic [IRQ_W-1:0]     irq_en_q, irq_stat_q;

  assign CFG_CLK = cfg_clk_q;
  assign CFG_PHY = cfg_phy_q;

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
      REG_STATUS:     rd_data = {24'h0, STATUS};
      REG_ERR:        rd_data = {24'h0, ERR};
      REG_LBA:        rd_data = lba_q;
      REG_BLOCKS:     rd_data = {8'h0, blocks_q};
      REG_XFER:       rd_data = {31'h0, xfer_q};
      REG_CFG_CLK:    rd_data = {24'h0, cfg_clk_q};
      REG_CFG_PHY:    rd_data = {26'h0, cfg_phy_q};
      REG_CARD_BLK:   rd_data = CARD_BLK;
      REG_STAT_DATA:  rd_data = STAT_DATA;
      REG_STAT_GAP:   rd_data = STAT_GAP;
      REG_STAT_BUSY:  rd_data = STAT_BUSY;
      REG_STAT_RETRY: rd_data = STAT_RETRY;
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
    for (int i = 0; i < 4; i++) begin
      merged[i*8 +: 8] = strb[i] ? new_val[i*8 +: 8] : old_val[i*8 +: 8];
    end
    return merged;
  endfunction

  logic [LBA_W-1:0]    merged_lba;
  logic [BLOCKS_W-1:0] merged_blocks;

  assign merged_lba = strb_merge(lba_q, wr_data, wr_strb);

  // BLOCKS is 24 bits wide, so only three byte lanes take part.
  assign merged_blocks = {wr_strb[2] ? wr_data[23:16] : blocks_q[23:16],
                          wr_strb[1] ? wr_data[15:8]  : blocks_q[15:8],
                          wr_strb[0] ? wr_data[7:0]   : blocks_q[7:0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bresp_r    <= RESP_OKAY;
      CTRL       <= '0;
      LBA        <= '0;
      BLOCKS     <= BLOCKS_W'(1);
      XFER       <= 1'b0;
      lba_q      <= '0;
      blocks_q   <= BLOCKS_W'(1);
      xfer_q     <= 1'b0;
      cfg_clk_q  <= '1;   // slowest division: initialisation runs at <= 400 kHz
      cfg_phy_q  <= '0;
      irq_en_q   <= '0;
      irq_stat_q <= '0;
    end else begin
      // CTRL is W1S and self-clearing, so every bit is a one-cycle pulse and
      // clears whether or not anything downstream consumed it.
      CTRL <= '0;

      if (wr_en) begin
        bresp_r <= wr_in_window ? RESP_OKAY : RESP_SLVERR;

        unique case (wr_reg)
          REG_CTRL: begin
            CTRL <= wr_strb[0] ? wr_data[CTRL_W-1:0] : CTRL_W'(0);
            // R-IF-3: the request is sampled here and nowhere else, so writes
            // to LBA / BLOCKS / XFER during a transfer cannot disturb it.
            if (wr_strb[0] && wr_data[CTRL_START_BIT]) begin
              LBA    <= lba_q;
              BLOCKS <= blocks_q;
              XFER   <= xfer_q;
            end
          end
          REG_LBA:      lba_q     <= merged_lba;
          REG_BLOCKS:   blocks_q  <= merged_blocks;
          REG_XFER:     if (wr_strb[0]) xfer_q    <= wr_data[0];
          REG_CFG_CLK:  if (wr_strb[0]) cfg_clk_q <= wr_data[CFG_CLK_W-1:0];
          REG_CFG_PHY:  if (wr_strb[0]) cfg_phy_q <= wr_data[CFG_PHY_W-1:0];
          REG_IRQ_EN:   if (wr_strb[0]) irq_en_q  <= wr_data[IRQ_W-1:0];
          REG_IRQ_STAT: ; // W1C, handled with the set sources below
          REG_VERSION, REG_STATUS, REG_ERR, REG_CARD_BLK, REG_STAT_DATA,
          REG_STAT_GAP, REG_STAT_BUSY, REG_STAT_RETRY: ; // RO: write ignored
          default: bresp_r <= RESP_SLVERR; // unmapped offset (R-IF-2)
        endcase
      end

      // IRQ_STAT: set from hardware, cleared by writing 1. A set arriving in
      // the same cycle as its clear wins, so an event is never lost.
      for (int i = 0; i < IRQ_W; i++) begin
        logic clr_i;
        clr_i = wr_en && (wr_reg == REG_IRQ_STAT) && wr_strb[0] && wr_data[i];
        if (IRQ_SET[i])  irq_stat_q[i] <= 1'b1;
        else if (clr_i)  irq_stat_q[i] <= 1'b0;
      end
    end
  end

endmodule
