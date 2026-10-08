`timescale 1ns/1ps
module tb_block_axis_write;
  import ultra_sd_pkg::*;
  localparam int WORDS=128;
  logic clk=0,axi_clk=0,rst_n,go_i,card_present_i,card_ready_i,dir_i;
  logic[31:0]lba_i,card_blk_i;logic[23:0]blocks_i;logic block_addr_i;logic[15:0]rca_i;
  logic accept_o,busy_o,fin_o,fail_o;err_e fail_code_o,cmd_err_i;
  logic stat_clear_tgl_i=1'b0;logic [31:0] stat_gap_o;logic [15:0] stat_retry_crc_o;
  logic req_valid_o,req_is_acmd_o,req_ready_i,rsp_valid_i,rsp_err_i;logic[5:0]req_index_o;
  logic[31:0]req_arg_o;resp_e req_resp_o;logic dat_start_o,dat_dir_o,tx_take_i,tx_done_i;
  logic tx_status_ok_i,tx_status_tmo_i;logic[31:0]tx_data_o,rx_data_i;logic rx_valid_i,rx_busy_i;
  logic rx_done_i,rx_crc_ok_i,dat_active_i,card_busy_i;logic[31:0]rd_data_o,wr_data_i;
  logic rd_en_o,rd_commit_o,rd_rewind_o,rd_room_ok_i,wr_last_i,wr_en_o,wr_commit_o;
  logic wr_rewind_o,wr_block_ready_i;
  logic[31:0]s_data;logic s_valid,s_ready,s_last,sd_valid;logic[8:0]sd_level;
  int checks,failures,popped;logic saw_last;
  always #5 clk=~clk;always #3.5 axi_clk=~axi_clk;

  // card_blk_i artik L3'un portu degil: on-denetim L4'te, clk alaninda bir boru
  // hattinda yapiliyor (ultra_sd_top). Test o hesabi burada ayni anlamla
  // uretir, boylece senaryolar card_blk_i'yi eskisi gibi surmeye devam eder.
  logic start_range_bad_i, start_blocks_zero_i, start_multi_i;
  assign start_range_bad_i   = ({1'b0, lba_i} + {1'b0, 32'(blocks_i)}) >
                               {1'b0, card_blk_i};
  assign start_blocks_zero_i = (blocks_i == '0);
  assign start_multi_i       = (blocks_i > 24'd1);
  ultra_sd_block #(.NAC_TIMEOUT_CLK(200),.PROG_TIMEOUT_CLK(50))u_block(.*);
  axis_wr_slave #(.DATA_W(32),.FIFO_DEPTH(256))u_axis(
    .axi_clk,.axi_rst_n(rst_n),.s_axis_wr_tdata(s_data),.s_axis_wr_tvalid(s_valid),
    .s_axis_wr_tready(s_ready),.s_axis_wr_tlast(s_last),.sd_clk(clk),.sd_rst_n(rst_n),
    .sd_rd_en(wr_en_o),.sd_rd_commit(wr_commit_o),.sd_rd_rewind(wr_rewind_o),
    .sd_rd_data(wr_data_i),.sd_rd_last(wr_last_i),.sd_rd_valid(sd_valid),
    .sd_rd_level(sd_level),.sd_block_ready(wr_block_ready_i)
  );
  task automatic check(input logic c,input string m);checks++;if(!c)begin failures++;$display("FAIL: %s",m);end endtask
  task automatic push(input int n);@(negedge axi_clk);s_data=32'h70000000+n;s_last=(n==WORDS-1);s_valid=1;
    while(!s_ready)@(posedge axi_clk);@(posedge axi_clk);#1;@(negedge axi_clk);s_valid=0;s_last=0;endtask
  task automatic answer_cmd;int t;t=0;while(!req_valid_o&&t<40)begin @(posedge clk);#1;t++;end
    check(req_index_o==CMD24_WRITE_BLOCK,"block issues CMD24");req_ready_i=1;
    while(req_valid_o)begin @(posedge clk);#1;end req_ready_i=0;
    @(negedge clk);rsp_valid_i=1;@(posedge clk);#1;@(negedge clk);rsp_valid_i=0;endtask
  initial begin
    checks=0;failures=0;popped=0;saw_last=0;rst_n=0;go_i=0;card_present_i=1;card_ready_i=1;dir_i=1;
    lba_i=32'h90;blocks_i=1;card_blk_i=32'h10000;block_addr_i=1;rca_i=16'h1234;
    req_ready_i=0;rsp_valid_i=0;rsp_err_i=0;cmd_err_i=ERR_OK;tx_take_i=0;tx_done_i=0;
    tx_status_ok_i=1;tx_status_tmo_i=0;rx_data_i=0;rx_valid_i=0;rx_busy_i=0;rx_done_i=0;
    rx_crc_ok_i=1;dat_active_i=0;card_busy_i=0;rd_room_ok_i=1;s_data=0;s_valid=0;s_last=0;
    repeat(5)@(posedge clk);rst_n=1;repeat(5)@(posedge clk);
    for(int i=0;i<WORDS;i++)push(i);
    begin int t;t=0;while(!wr_block_ready_i&&t<100)begin @(posedge clk);#1;t++;end
      check(wr_block_ready_i,"whole block buffered before command");end
    @(negedge clk);go_i=1;answer_cmd();while(!dat_start_o)@(posedge clk);@(posedge clk);
    for(int i=0;i<WORDS;i++)begin
      while(!sd_valid)@(posedge clk);check(wr_data_i==32'h70000000+i,"write FIFO ordering");
      if(wr_last_i)saw_last=1;@(negedge clk);tx_take_i=1;@(posedge clk);#1;
      check(wr_en_o,"block pops write FIFO on line take");popped++;@(negedge clk);tx_take_i=0;
    end
    check(wr_last_i||saw_last,"host tlast reaches block with final word");
    @(negedge clk);tx_done_i=1;tx_status_ok_i=1;@(posedge clk);#1;@(negedge clk);tx_done_i=0;
    begin int t;t=0;while(!fin_o&&t<50)begin @(posedge clk);#1;t++;end check(fin_o,"single write completes");end
    repeat(6)@(posedge clk);#1;
    check(popped==WORDS&&sd_level==0,"all 128 words committed and FIFO drained");
    check(!fail_o,"block-to-AXIS write has no error");
    if(failures)begin $display("tb_block_axis_write: FAILED (%0d)",failures);$fatal(1);end
    $display("tb_block_axis_write: PASSED (%0d checks)",checks);$finish;
  end
  initial begin #4_000_000;$fatal(1,"tb_block_axis_write timeout");end
endmodule
