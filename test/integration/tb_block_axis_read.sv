`timescale 1ns/1ps

module tb_block_axis_read;
  import ultra_sd_pkg::*;
  localparam int WORDS = 128;
  logic clk=0,axi_clk=0,rst_n,go_i,card_present_i,card_ready_i,dir_i;
  logic [31:0] lba_i,card_blk_i;logic[23:0]blocks_i;logic block_addr_i;logic[15:0]rca_i;
  logic accept_o,busy_o,fin_o,fail_o;err_e fail_code_o,cmd_err_i;
  logic stat_clear_tgl_i=1'b0;logic [31:0] stat_gap_o;logic [15:0] stat_retry_crc_o;
  logic req_valid_o,req_is_acmd_o,req_ready_i,rsp_valid_i,rsp_err_i;logic[5:0]req_index_o;
  logic[31:0]req_arg_o;resp_e req_resp_o;logic dat_start_o,dat_dir_o,tx_take_i,tx_done_i;
  logic tx_status_ok_i,tx_status_tmo_i;logic[31:0]tx_data_o,rx_data_i;logic rx_valid_i,rx_busy_i;
  logic rx_done_i,rx_crc_ok_i,dat_active_i,card_busy_i;logic[31:0]rd_data_o,wr_data_i;
  logic rd_en_o,rd_commit_o,rd_rewind_o,rd_room_ok_i,wr_last_i,wr_en_o,wr_commit_o;
  logic wr_rewind_o,wr_block_ready_i;
  logic xfer_start,xfer_abort,xfer_busy,m_valid,m_ready,m_last;
  logic[31:0]m_data;logic fifo_full;logic[8:0]fifo_level;
  int checks,failures,received;logic saw_last,precommit_leak,commit_seen;
  always #5 clk=~clk; always #3.5 axi_clk=~axi_clk;

  // card_blk_i artik L3'un portu degil: on-denetim L4'te, clk alaninda bir boru
  // hattinda yapiliyor (ultra_sd_top). Test o hesabi burada ayni anlamla
  // uretir, boylece senaryolar card_blk_i'yi eskisi gibi surmeye devam eder.
  logic start_range_bad_i, start_blocks_zero_i, start_multi_i;
  assign start_range_bad_i   = ({1'b0, lba_i} + {1'b0, 32'(blocks_i)}) >
                               {1'b0, card_blk_i};
  assign start_blocks_zero_i = (blocks_i == '0);
  assign start_multi_i       = (blocks_i > 24'd1);

  ultra_sd_block #(.NAC_TIMEOUT_CLK(200),.PROG_TIMEOUT_CLK(50)) u_block(.*);
  axis_rd_master #(.DATA_W(32),.FIFO_DEPTH(256)) u_axis(
    .axi_clk,.axi_rst_n(rst_n),.xfer_start,.xfer_beats(32'(WORDS)),.xfer_abort,
    .xfer_busy,.m_axis_rd_tdata(m_data),.m_axis_rd_tvalid(m_valid),
    .m_axis_rd_tready(m_ready),.m_axis_rd_tlast(m_last),.sd_clk(clk),.sd_rst_n(rst_n),
    .sd_wr_en(rd_en_o),.sd_wr_data(rd_data_o),.sd_wr_commit(rd_commit_o),
    .sd_wr_rewind(rd_rewind_o),.sd_wr_full(fifo_full),
    .sd_wr_block_room(rd_room_ok_i),.sd_wr_level(fifo_level)
  );
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n)commit_seen<=0;
    else if(rd_commit_o)commit_seen<=1;
  end
  always @(posedge axi_clk) begin
    if(!rst_n)begin received<=0;saw_last<=0;precommit_leak<=0;end
    else begin
      if(m_valid&&!commit_seen)precommit_leak<=1;
      if(m_valid&&m_ready)begin
        if(m_data!==32'h60000000+received)begin failures++;$display("FAIL: AXIS data %0d",received);end
        if(m_last)saw_last<=1;
        received<=received+1;
      end
    end
  end
  task automatic check(input logic c,input string m);checks++;if(!c)begin failures++;$display("FAIL: %s",m);end endtask
  task automatic answer_cmd;int t;t=0;while(!req_valid_o&&t<40)begin @(posedge clk);#1;t++;end
    check(req_index_o==CMD17_READ_SINGLE_BLOCK,"block issues CMD17");req_ready_i=1;
    while(req_valid_o)begin @(posedge clk);#1;end req_ready_i=0;
    @(negedge clk);rsp_valid_i=1;@(posedge clk);#1;@(negedge clk);rsp_valid_i=0;
  endtask
  initial begin
    checks=0;failures=0;rst_n=0;go_i=0;card_present_i=1;card_ready_i=1;dir_i=0;
    lba_i=32'h80;blocks_i=1;card_blk_i=32'h10000;block_addr_i=1;rca_i=16'h1234;
    req_ready_i=0;rsp_valid_i=0;rsp_err_i=0;cmd_err_i=ERR_OK;tx_take_i=0;tx_done_i=0;
    tx_status_ok_i=1;tx_status_tmo_i=0;rx_data_i=0;rx_valid_i=0;rx_busy_i=0;rx_done_i=0;
    rx_crc_ok_i=1;dat_active_i=0;card_busy_i=0;wr_data_i=0;wr_last_i=0;wr_block_ready_i=0;
    xfer_start=0;xfer_abort=0;m_ready=1;repeat(5)@(posedge clk);rst_n=1;repeat(8)@(posedge clk);
    @(negedge axi_clk);xfer_start=1;@(posedge axi_clk);#1;@(negedge axi_clk);xfer_start=0;
    @(negedge clk);go_i=1;answer_cmd();
    while(!dat_start_o)@(posedge clk);
    for(int i=0;i<WORDS;i++)begin
      @(negedge clk);rx_data_i=32'h60000000+i;rx_valid_i=1;dat_active_i=1;
      @(posedge clk);#1;check(rd_en_o,"block forwards read word into FIFO");
    end
    @(negedge clk);rx_valid_i=0;dat_active_i=0;rx_done_i=1;rx_crc_ok_i=1;
    @(posedge clk);#1;@(negedge clk);rx_done_i=0;
    begin int t;t=0;while(received<WORDS&&t<500)begin @(posedge axi_clk);#1;t++;end
      check(received==WORDS,"committed block reaches AXIS host");end
    check(!precommit_leak,"speculative block hidden until CRC commit");
    check(saw_last&&m_last==0,"tlast observed exactly at request end");
    check(!fail_o,"block-to-AXIS transfer has no block error");
    if(failures)begin $display("tb_block_axis_read: FAILED (%0d failures)",failures);$fatal(1);end
    $display("tb_block_axis_read: PASSED (%0d checks)",checks);$finish;
  end
  initial begin #3_000_000;$fatal(1,"tb_block_axis_read timeout");end
endmodule
