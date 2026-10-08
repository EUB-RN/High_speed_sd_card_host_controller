// -----------------------------------------------------------------------------
// sd_card_model
//   Behavioural SDHC card model for simulation.  It is deliberately plain
//   SystemVerilog (no classes/UVM), so the same model runs under the supported
//   open-source simulators.  It owns the card side of CMD/DAT and implements the
//   command subset used by ultra_sd.
//
//   Supported command path:
//     CMD0/2/3/6/7/8/9/12/13/17/18/24/25/55
//     ACMD6/23/41/51
//   Supported data path:
//     1-bit and 4-bit, CRC16 per lane, single/multiple block reads, block
//     writes, write CRC-status token and programmable busy time.
//
//   Fault inputs affect the next applicable transaction while asserted.  A
//   test normally pulses one input while sending the command/data block.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module sd_card_model
  import ultra_sd_pkg::*;
#(
  parameter int BLOCK_COUNT       = 64,
  parameter int NCR_DELAY_CYCLES  = 2,
  parameter int NAC_DELAY_CYCLES  = 4,
  parameter int WRITE_BUSY_CYCLES = 8,
  parameter int ACMD41_BUSY_POLLS = 2,
  parameter logic [15:0] RCA      = 16'h1234
) (
  input  logic       sd_clk,
  input  logic       rst_n,
  input  logic       card_present_i,
  inout  tri1        sd_cmd,
  inout  tri1 [3:0]  sd_dat,

  input  logic       inject_cmd_timeout_i,
  input  logic       inject_cmd_crc_i,
  input  logic       inject_data_crc_i,
  input  logic       inject_write_crc_i,
  input  logic       inject_busy_stuck_i,

  output logic       protocol_error_o,
  output logic [5:0] last_cmd_o,
  output logic [31:0] command_count_o,
  output logic       bus_4bit_o,
  output logic       high_speed_o
);

  localparam int STORAGE_BYTES = BLOCK_COUNT * BLOCK_BYTES;

  logic       cmd_oe_q, cmd_out_q;
  logic [3:0] dat_oe_q, dat_out_q;
  assign sd_cmd = (card_present_i && cmd_oe_q) ? cmd_out_q : 1'bz;
  generate
    for (genvar d = 0; d < 4; d++) begin : g_dat_driver
      assign sd_dat[d] = (card_present_i && dat_oe_q[d]) ? dat_out_q[d] : 1'bz;
    end
  endgenerate

  logic [7:0] storage [0:STORAGE_BYTES-1];
  logic [7:0] write_buffer [0:BLOCK_BYTES-1];

  function automatic logic [6:0] crc7_40(input logic [39:0] value);
    logic [6:0] crc;
    logic fb;
    begin
      crc = 7'h00;
      for (int i = 39; i >= 0; i--) begin
        fb  = crc[6] ^ value[i];
        crc = {crc[5:0], 1'b0} ^ (fb ? CRC7_POLY : 7'h00);
      end
      crc7_40 = crc;
    end
  endfunction

  function automatic logic [6:0] crc7_120(input logic [119:0] value);
    logic [6:0] crc;
    logic fb;
    begin
      crc = 7'h00;
      for (int i = 119; i >= 0; i--) begin
        fb  = crc[6] ^ value[i];
        crc = {crc[5:0], 1'b0} ^ (fb ? CRC7_POLY : 7'h00);
      end
      crc7_120 = crc;
    end
  endfunction

  function automatic logic [15:0] crc16_bit(input logic [15:0] crc,
                                             input logic bit_in);
    logic fb;
    begin
      fb = crc[15] ^ bit_in;
      crc16_bit = {crc[14:0], 1'b0} ^ (fb ? CRC16_POLY : 16'h0000);
    end
  endfunction

  // Public backdoor helpers.  Tests may use u_card.write_byte()/read_byte()
  // without reaching into the implementation array.
  task automatic write_byte(input integer byte_address, input logic [7:0] value);
    if ((byte_address >= 0) && (byte_address < STORAGE_BYTES))
      storage[byte_address] = value;
  endtask

  function automatic logic [7:0] read_byte(input integer byte_address);
    if ((byte_address >= 0) && (byte_address < STORAGE_BYTES))
      read_byte = storage[byte_address];
    else
      read_byte = 8'h00;
  endfunction

  // ---------------------------------------------------------------------------
  // Card state and response construction
  // ---------------------------------------------------------------------------
  logic app_cmd_q, selected_q, multi_read_q, multi_write_q;
  integer acmd41_polls_q;
  integer active_lba_q;

  function automatic logic [31:0] r1_status(input logic app_cmd);
    logic [31:0] s;
    begin
      s = 32'h0000_0900;              // TRAN state + READY_FOR_DATA
      s[5] = app_cmd;                 // APP_CMD
      r1_status = s;
    end
  endfunction

  logic [135:0] resp_shift_q;
  integer       resp_bits_q;
  integer       resp_delay_q;
  logic         resp_pending_q, resp_finishing_q;

  task automatic queue_short(input logic [5:0] index,
                             input logic [31:0] argument,
                             input logic crc_meaningful);
    logic [39:0] header;
    logic [47:0] frame;
    begin
      header = {1'b0, 1'b0, index, argument};
      frame  = {header, crc_meaningful ? crc7_40(header) : 7'h7f, 1'b1};
      if (inject_cmd_crc_i && crc_meaningful) frame[1] = ~frame[1];
      resp_shift_q   <= {{88{1'b1}}, frame};
      resp_bits_q    <= 48;
      resp_delay_q   <= NCR_DELAY_CYCLES;
      resp_pending_q <= !inject_cmd_timeout_i;
    end
  endtask

  task automatic queue_long(input logic [119:0] content);
    logic [135:0] frame;
    begin
      frame = {8'h3f, content, crc7_120(content), 1'b1};
      if (inject_cmd_crc_i) frame[1] = ~frame[1];
      resp_shift_q   <= frame;
      resp_bits_q    <= 136;
      resp_delay_q   <= NCR_DELAY_CYCLES;
      resp_pending_q <= !inject_cmd_timeout_i;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Read-data request descriptor. kind: 0=storage, 1=SCR, 2=switch status.
  // ---------------------------------------------------------------------------
  logic   read_queued_q;
  integer read_kind_q, read_length_q, read_lba_q;

  function automatic logic [7:0] read_payload_byte(input integer kind,
                                                    input integer lba,
                                                    input integer offset);
    integer a;
    begin
      case (kind)
        1: begin                         // SCR (64 bits, MSB first)
          case (offset)
            0: read_payload_byte = 8'h02; // SD_SPEC = 2
            1: read_payload_byte = 8'h05; // 1-bit + 4-bit supported
            default: read_payload_byte = 8'h00;
          endcase
        end
        2: begin                         // CMD6 switch-function status
          read_payload_byte = (offset == 16) ? 8'h01 : 8'h00;
        end
        default: begin
          a = ((lba % BLOCK_COUNT) * BLOCK_BYTES) + offset;
          read_payload_byte = storage[a];
        end
      endcase
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Command receiver: card samples host CMD at the rising edge.
  // ---------------------------------------------------------------------------
  logic [47:0] cmd_shift_q;
  integer      cmd_bits_q;
  logic        cmd_rx_q;

  always_ff @(posedge sd_clk or negedge rst_n) begin : p_command_receiver
    logic [47:0] frame;
    logic [5:0]  index;
    logic [31:0] argument;
    logic [119:0] long_content;
    logic is_acmd;
    if (!rst_n || !card_present_i) begin
      cmd_shift_q       <= '0;
      cmd_bits_q        <= 0;
      cmd_rx_q          <= 1'b0;
      app_cmd_q         <= 1'b0;
      selected_q        <= 1'b0;
      multi_read_q      <= 1'b0;
      multi_write_q     <= 1'b0;
      bus_4bit_o        <= 1'b0;
      high_speed_o      <= 1'b0;
      acmd41_polls_q    <= 0;
      active_lba_q      <= 0;
      protocol_error_o  <= 1'b0;
      last_cmd_o        <= '0;
      command_count_o   <= '0;
      read_queued_q     <= 1'b0;
    end else if (!cmd_oe_q) begin
      if (!cmd_rx_q) begin
        if (sd_cmd === 1'b0) begin
          cmd_shift_q <= {{47{1'b0}}, 1'b0};
          cmd_bits_q  <= 1;
          cmd_rx_q    <= 1'b1;
        end
      end else begin
        frame = {cmd_shift_q[46:0], sd_cmd};
        cmd_shift_q <= frame;
        if (cmd_bits_q == 47) begin
          cmd_rx_q   <= 1'b0;
          cmd_bits_q <= 0;
          index      = frame[45:40];
          argument   = frame[39:8];
          is_acmd    = app_cmd_q;
          last_cmd_o      <= index;
          command_count_o <= command_count_o + 1'b1;

          if ((frame[47:46] != 2'b01) || !frame[0] ||
              (frame[7:1] != crc7_40(frame[47:8]))) begin
            protocol_error_o <= 1'b1;
          end else begin
            // APP_CMD applies to exactly one following command.
            if (index != CMD55_APP_CMD) app_cmd_q <= 1'b0;
            case (index)
              CMD0_GO_IDLE_STATE: begin
                selected_q    <= 1'b0;
                app_cmd_q     <= 1'b0;
                bus_4bit_o    <= 1'b0;
                high_speed_o  <= 1'b0;
                multi_read_q  <= 1'b0;
                multi_write_q <= 1'b0;
              end

              CMD8_SEND_IF_COND:
                queue_short(index, argument, 1'b1);

              CMD55_APP_CMD: begin
                app_cmd_q <= 1'b1;
                queue_short(index, r1_status(1'b1), 1'b1);
              end

              ACMD41_SD_SEND_OP_COND: if (is_acmd) begin
                acmd41_polls_q <= acmd41_polls_q + 1;
                queue_short(6'h3f,
                            ((acmd41_polls_q + 1) >= ACMD41_BUSY_POLLS)
                              ? 32'hC0FF_8000 : 32'h40FF_8000,
                            1'b0);
              end else begin
                queue_short(index, r1_status(1'b0) | 32'h0040_0000, 1'b1);
              end

              CMD2_ALL_SEND_CID: begin
                long_content = 120'h1D_5344554C545241534430303031;
                queue_long(long_content);
              end

              CMD3_SEND_RELATIVE_ADDR:
                queue_short(index, {RCA, 16'h0900}, 1'b1);

              CMD9_SEND_CSD: begin
                // CSD v2.0. C_SIZE is chosen so the advertised capacity is
                // BLOCK_COUNT sectors (rounded up to the 1024-sector unit).
                long_content = '0;
                long_content[119:118] = 2'b01;
                long_content[61:40]   = ((BLOCK_COUNT + 1023) / 1024) - 1;
                queue_long(long_content);
              end

              CMD7_SELECT_CARD: begin
                selected_q <= (argument[31:16] == RCA);
                queue_short(index, r1_status(1'b0), 1'b1);
              end

              ACMD51_SEND_SCR: if (is_acmd) begin
                queue_short(index, r1_status(1'b0), 1'b1);
                read_kind_q   <= 1;
                read_length_q <= 8;
                read_lba_q    <= 0;
                read_queued_q <= 1'b1;
              end else begin
                queue_short(index, r1_status(1'b0) | 32'h0040_0000, 1'b1);
              end

              CMD6_SWITCH_FUNC: begin
                if (is_acmd) begin
                  bus_4bit_o <= (argument[1:0] == 2'b10);
                  queue_short(index, r1_status(1'b0), 1'b1);
                end else begin
                  high_speed_o <= argument[31] && (argument[3:0] == 4'h1);
                  queue_short(index, r1_status(1'b0), 1'b1);
                  read_kind_q   <= 2;
                  read_length_q <= 64;
                  read_lba_q    <= 0;
                  read_queued_q <= 1'b1;
                end
              end

              ACMD23_SET_WR_BLK_ERASE_CNT: if (is_acmd)
                queue_short(index, r1_status(1'b0), 1'b1);
              else
                queue_short(index, r1_status(1'b0) | 32'h0040_0000, 1'b1);

              CMD17_READ_SINGLE_BLOCK,
              CMD18_READ_MULTIPLE_BLOCK: begin
                active_lba_q  <= argument;
                multi_read_q  <= (index == CMD18_READ_MULTIPLE_BLOCK);
                read_kind_q   <= 0;
                read_length_q <= BLOCK_BYTES;
                read_lba_q    <= argument;
                read_queued_q <= 1'b1;
                queue_short(index, r1_status(1'b0), 1'b1);
              end

              CMD24_WRITE_BLOCK,
              CMD25_WRITE_MULTIPLE_BLK: begin
                active_lba_q   <= argument;
                multi_write_q  <= (index == CMD25_WRITE_MULTIPLE_BLK);
                write_expected_q <= 1'b1;
                queue_short(index, r1_status(1'b0), 1'b1);
              end

              CMD12_STOP_TRANSMISSION: begin
                multi_read_q  <= 1'b0;
                multi_write_q <= 1'b0;
                read_queued_q <= 1'b0;
                queue_short(index, r1_status(1'b0), 1'b1);
              end

              CMD13_SEND_STATUS:
                queue_short(index, r1_status(1'b0), 1'b1);

              default:
                queue_short(index, r1_status(1'b0) | 32'h0040_0000, 1'b1);
            endcase
          end
        end else begin
          cmd_bits_q <= cmd_bits_q + 1;
        end
      end
    end
  end

  // Card changes CMD on falling edges; host samples it on rising edges.
  always_ff @(negedge sd_clk or negedge rst_n) begin
    if (!rst_n || !card_present_i) begin
      cmd_oe_q          <= 1'b0;
      cmd_out_q         <= 1'b1;
      resp_pending_q    <= 1'b0;
      resp_finishing_q  <= 1'b0;
      resp_bits_q       <= 0;
      resp_delay_q      <= 0;
    end else if (resp_finishing_q) begin
      cmd_oe_q         <= 1'b0;
      cmd_out_q        <= 1'b1;
      resp_finishing_q <= 1'b0;
    end else if (resp_pending_q) begin
      if (resp_delay_q > 0) begin
        resp_delay_q <= resp_delay_q - 1;
      end else begin
        cmd_oe_q    <= 1'b1;
        cmd_out_q   <= resp_shift_q[resp_bits_q-1];
        if (resp_bits_q == 1) begin
          resp_pending_q   <= 1'b0;
          resp_finishing_q <= 1'b1;
          resp_bits_q      <= 0;
        end else begin
          resp_bits_q  <= resp_bits_q - 1;
        end
      end
    end else begin
      cmd_oe_q  <= 1'b0;
      cmd_out_q <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // DAT read transmitter and write-response token share the falling-edge
  // driver.  There can only be one card-owned DAT transfer at a time.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    D_IDLE, D_RD_DELAY, D_RD_START, D_RD_DATA, D_RD_CRC, D_RD_END,
    D_TOK_GAP, D_TOK_START, D_TOK_BITS, D_TOK_END, D_BUSY
  } dat_tx_state_e;
  dat_tx_state_e dat_tx_state_q;

  integer rd_delay_q, rd_group_q, rd_crc_bit_q;
  integer rd_kind_active_q, rd_length_active_q, rd_lba_active_q;
  integer tok_gap_q, tok_bit_q, busy_count_q;
  logic [2:0] token_q;
  logic [15:0] rd_crc_q [0:3];

  function automatic logic [3:0] read_group(input integer kind,
                                             input integer lba,
                                             input integer length,
                                             input integer group,
                                             input logic wide);
    logic [7:0] b;
    integer byte_index;
    integer bit_index;
    begin
      if (wide) begin
        byte_index = group / 2;
        b = read_payload_byte(kind, lba, byte_index);
        read_group = (group[0] == 1'b0) ? b[7:4] : b[3:0];
      end else begin
        byte_index = group / 8;
        bit_index  = 7 - (group % 8);
        b = read_payload_byte(kind, lba, byte_index);
        read_group = {3'b111, b[bit_index]};
      end
    end
  endfunction

  // Write receiver state.  It samples host DAT on the rising edge.
  typedef enum logic [2:0] {W_IDLE, W_DATA, W_CRC, W_END} dat_rx_state_e;
  dat_rx_state_e dat_rx_state_q;
  integer wr_group_q, wr_crc_bit_q, wr_byte_q;
  logic [7:0] wr_byte_shift_q;
  logic [15:0] wr_crc_q [0:3];
  logic write_expected_q;
  logic write_result_pending_q;
  logic write_crc_good_q;

  always_ff @(posedge sd_clk or negedge rst_n) begin : p_write_receiver
    logic [7:0] next_byte;
    logic all_zero;
    logic accept_block;
    if (!rst_n || !card_present_i) begin
      dat_rx_state_q       <= W_IDLE;
      wr_group_q           <= 0;
      wr_crc_bit_q         <= 0;
      wr_byte_q            <= 0;
      wr_byte_shift_q      <= '0;
      write_expected_q     <= 1'b0;
      write_result_pending_q <= 1'b0;
      write_crc_good_q     <= 1'b0;
      for (int l = 0; l < 4; l++) wr_crc_q[l] <= '0;
    end else begin
      case (dat_rx_state_q)
        W_IDLE: if (write_expected_q && !write_result_pending_q &&
                   (dat_tx_state_q == D_IDLE) && (sd_dat[0] === 1'b0)) begin
          dat_rx_state_q   <= W_DATA;
          wr_group_q       <= 0;
          wr_byte_q        <= 0;
          wr_byte_shift_q  <= '0;
          write_expected_q <= 1'b0;
          for (int l = 0; l < 4; l++) wr_crc_q[l] <= '0;
        end

        W_DATA: begin
          for (int l = 0; l < 4; l++)
            if (bus_4bit_o || (l == 0))
              wr_crc_q[l] <= crc16_bit(wr_crc_q[l], sd_dat[l]);

          if (bus_4bit_o) begin
            next_byte = {wr_byte_shift_q[3:0], sd_dat};
            wr_byte_shift_q <= next_byte;
            if (wr_group_q[0]) begin
              write_buffer[wr_byte_q] <= next_byte;
              wr_byte_q <= wr_byte_q + 1;
            end
            if (wr_group_q == (BLOCK_BYTES*2 - 1)) begin
              wr_crc_bit_q   <= 15;
              dat_rx_state_q <= W_CRC;
            end else wr_group_q <= wr_group_q + 1;
          end else begin
            next_byte = {wr_byte_shift_q[6:0], sd_dat[0]};
            wr_byte_shift_q <= next_byte;
            if ((wr_group_q % 8) == 7) begin
              write_buffer[wr_byte_q] <= next_byte;
              wr_byte_q <= wr_byte_q + 1;
            end
            if (wr_group_q == (BLOCK_BYTES*8 - 1)) begin
              wr_crc_bit_q   <= 15;
              dat_rx_state_q <= W_CRC;
            end else wr_group_q <= wr_group_q + 1;
          end
        end

        W_CRC: begin
          for (int l = 0; l < 4; l++)
            if (bus_4bit_o || (l == 0))
              wr_crc_q[l] <= crc16_bit(wr_crc_q[l], sd_dat[l]);
          if (wr_crc_bit_q == 0) dat_rx_state_q <= W_END;
          else wr_crc_bit_q <= wr_crc_bit_q - 1;
        end

        W_END: begin
          all_zero = 1'b1;
          for (int l = 0; l < 4; l++)
            if ((bus_4bit_o || (l == 0)) && (wr_crc_q[l] != 16'h0000))
              all_zero = 1'b0;
          accept_block = all_zero && !inject_write_crc_i;
          write_crc_good_q       <= accept_block;
          write_result_pending_q <= 1'b1;
          write_expected_q       <= multi_write_q;
          dat_rx_state_q         <= W_IDLE;
          if (accept_block) begin
            for (int i = 0; i < BLOCK_BYTES; i++)
              storage[((active_lba_q % BLOCK_COUNT) * BLOCK_BYTES) + i]
                <= write_buffer[i];
            if (multi_write_q) active_lba_q <= active_lba_q + 1;
          end
        end
      endcase
    end
  end

  always_ff @(negedge sd_clk or negedge rst_n) begin : p_dat_driver
    logic [3:0] group_bits;
    logic [3:0] mask;
    integer total_groups;
    if (!rst_n || !card_present_i) begin
      dat_tx_state_q   <= D_IDLE;
      dat_oe_q         <= 4'b0000;
      dat_out_q        <= 4'b1111;
      rd_delay_q       <= 0;
      rd_group_q       <= 0;
      rd_crc_bit_q     <= 15;
      tok_gap_q        <= 0;
      tok_bit_q        <= 2;
      busy_count_q     <= 0;
      token_q          <= 3'b010;
      for (int l = 0; l < 4; l++) rd_crc_q[l] <= '0;
    end else begin
      mask = bus_4bit_o ? 4'b1111 : 4'b0001;
      case (dat_tx_state_q)
        D_IDLE: begin
          dat_oe_q  <= 4'b0000;
          dat_out_q <= 4'b1111;
          if (write_result_pending_q) begin
            token_q <= write_crc_good_q ? 3'b010 : 3'b101;
            tok_gap_q <= 2;
            write_result_pending_q <= 1'b0;
            dat_tx_state_q <= D_TOK_GAP;
          end else if (read_queued_q && !resp_pending_q && !cmd_oe_q) begin
            rd_kind_active_q   <= read_kind_q;
            rd_length_active_q <= read_length_q;
            rd_lba_active_q    <= read_lba_q;
            read_queued_q      <= 1'b0;
            rd_delay_q         <= NAC_DELAY_CYCLES;
            dat_tx_state_q     <= D_RD_DELAY;
          end
        end

        D_RD_DELAY: begin
          if (rd_delay_q == 0) dat_tx_state_q <= D_RD_START;
          else rd_delay_q <= rd_delay_q - 1;
        end

        D_RD_START: begin
          dat_oe_q      <= mask;
          dat_out_q     <= ~mask;
          rd_group_q    <= 0;
          for (int l = 0; l < 4; l++) rd_crc_q[l] <= '0;
          dat_tx_state_q <= D_RD_DATA;
        end

        D_RD_DATA: begin
          group_bits = read_group(rd_kind_active_q, rd_lba_active_q,
                                  rd_length_active_q, rd_group_q, bus_4bit_o);
          dat_oe_q  <= mask;
          dat_out_q <= (group_bits & mask) | ~mask;
          for (int l = 0; l < 4; l++)
            if (mask[l]) rd_crc_q[l] <= crc16_bit(rd_crc_q[l], group_bits[l]);
          total_groups = rd_length_active_q * (bus_4bit_o ? 2 : 8);
          if (rd_group_q == total_groups - 1) begin
            rd_crc_bit_q <= 15;
            dat_tx_state_q <= D_RD_CRC;
          end else rd_group_q <= rd_group_q + 1;
        end

        D_RD_CRC: begin
          dat_oe_q <= mask;
          for (int l = 0; l < 4; l++) begin
            if (mask[l])
              dat_out_q[l] <= rd_crc_q[l][rd_crc_bit_q] ^
                              (inject_data_crc_i && (l == 0) && (rd_crc_bit_q == 15));
            else dat_out_q[l] <= 1'b1;
          end
          if (rd_crc_bit_q == 0) dat_tx_state_q <= D_RD_END;
          else rd_crc_bit_q <= rd_crc_bit_q - 1;
        end

        D_RD_END: begin
          dat_oe_q  <= mask;
          dat_out_q <= 4'b1111;
          if (multi_read_q && (rd_kind_active_q == 0)) begin
            read_lba_q    <= rd_lba_active_q + 1;
            read_kind_q   <= 0;
            read_length_q <= BLOCK_BYTES;
            read_queued_q <= 1'b1;
          end
          dat_tx_state_q <= D_IDLE;
        end

        D_TOK_GAP: begin
          dat_oe_q <= 4'b0000;
          if (tok_gap_q == 0) dat_tx_state_q <= D_TOK_START;
          else tok_gap_q <= tok_gap_q - 1;
        end

        D_TOK_START: begin
          dat_oe_q      <= 4'b0001;
          dat_out_q     <= 4'b1110;
          tok_bit_q     <= 2;
          dat_tx_state_q <= D_TOK_BITS;
        end

        D_TOK_BITS: begin
          dat_oe_q     <= 4'b0001;
          dat_out_q    <= {3'b111, token_q[tok_bit_q]};
          if (tok_bit_q == 0) dat_tx_state_q <= D_TOK_END;
          else tok_bit_q <= tok_bit_q - 1;
        end

        D_TOK_END: begin
          dat_oe_q      <= 4'b0001;
          dat_out_q     <= 4'b1111;
          busy_count_q  <= WRITE_BUSY_CYCLES;
          dat_tx_state_q <= D_BUSY;
        end

        D_BUSY: begin
          dat_oe_q  <= 4'b0001;
          dat_out_q <= 4'b1110;
          if (!inject_busy_stuck_i) begin
            if (busy_count_q == 0) begin
              dat_oe_q      <= 4'b0000;
              dat_out_q     <= 4'b1111;
              dat_tx_state_q <= D_IDLE;
            end else busy_count_q <= busy_count_q - 1;
          end
        end

        default: dat_tx_state_q <= D_IDLE;
      endcase
    end
  end

  initial begin
    for (int i = 0; i < STORAGE_BYTES; i++) storage[i] = i[7:0] ^ 8'hA5;
  end

endmodule
