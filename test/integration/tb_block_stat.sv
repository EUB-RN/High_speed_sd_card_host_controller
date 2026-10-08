`timescale 1ns/1ps

module tb_block_stat;
  import ultra_sd_pkg::*;
  logic clk=0,rst_n,go_i,card_present_i,card_ready_i,dir_i;
  logic [31:0] lba_i,card_blk_i; logic [23:0] blocks_i; logic block_addr_i;
  logic [15:0] rca_i; logic accept_o,busy_o,fin_o,fail_o;
  // Gap ve CRC-retry sayaclari ultra_sd_block'un ICINDE (olaylari onun FSM
  // kollari); bu test onlari dogrudan okuyor. STAT_DATA / STAT_BUSY burada yok
  // -- onlar ultra_sd_line'in icinde ve tb_ultra_sd_line'in konusu.
  logic [31:0] stat_gap_o; logic [15:0] stat_retry_crc_o;
  logic stat_clear_tgl_i;
  err_e fail_code_o,cmd_err_i; logic req_valid_o,req_is_acmd_o,req_ready_i,rsp_valid_i,rsp_err_i;
  logic [5:0] req_index_o; logic [31:0] req_arg_o; resp_e req_resp_o;
  logic dat_start_o,dat_dir_o,tx_take_i,tx_done_i,tx_status_ok_i,tx_status_tmo_i;
  logic [31:0] tx_data_o,rx_data_i; logic rx_valid_i,rx_busy_i,rx_done_i,rx_crc_ok_i,dat_active_i,card_busy_i;
  logic [31:0] rd_data_o,wr_data_i; logic rd_en_o,rd_commit_o,rd_rewind_o,rd_room_ok_i;
  logic wr_last_i,wr_en_o,wr_commit_o,wr_rewind_o,wr_block_ready_i;
  logic stat_clear_i; logic [7:0] status; err_e stat_err;
  speed_e speed_const; err_e init_err_const;
  logic [1:0] irq_set;
  logic saw_done_irq,saw_err_irq; int checks,failures,gap_cycles;
  always #5 clk=~clk;

  // card_blk_i artik L3'un portu degil: on-denetim L4'te, clk alaninda bir boru
  // hattinda yapiliyor (ultra_sd_top). Test o hesabi burada ayni anlamla
  // uretir, boylece senaryolar card_blk_i'yi eskisi gibi surmeye devam eder.
  logic start_range_bad_i, start_blocks_zero_i, start_multi_i;
  assign start_range_bad_i   = ({1'b0, lba_i} + {1'b0, 32'(blocks_i)}) >
                               {1'b0, card_blk_i};
  assign start_blocks_zero_i = (blocks_i == '0);
  assign start_multi_i       = (blocks_i > 24'd1);

  ultra_sd_block #(.NAC_TIMEOUT_CLK(12),.PROG_TIMEOUT_CLK(12)) u_block(.*);
  // Table 5-1 / Table 5-2 artik system_controller'in FSM'inin icinde. Bu test
  // faz FSM'ini sinamiyor (onu tb_system_controller yapiyor): kart takili ve
  // debounce penceresi kisa, boylece core_rst_n birakilir ve durum/sayac
  // bolumu kosar. fin / fail ayri port degil -- xfer_done_i / xfer_err_i.
  system_controller #(.CD_DEBOUNCE_CYC(3), .RAMP_CLOCKS(4), .INIT_CLK_DIV(10)) u_stat (
    .clk              (clk),
    .rst_n_i          (rst_n),
    .soft_reset_i     (1'b0),
    .sd_cd_i          (1'b0),            // ACTIVE LOW: kart takili

    .clk_div_i        (CFG_CLK_W'(4)),
    .init_done_i      (card_ready_i),
    .start_i          (1'b0),
    .dir_i            (dir_i),
    .abort_i          (1'b0),
    .xfer_done_i      (fin_o),           // Table 5-1 "fin"
    .xfer_err_i       (fail_o),          // Table 5-1 "fail"

    .bus_4bit_i       (1'b1),
    .force_1bit_i     (1'b0),

    .rst_n_o          (),
    .core_rst_n_o     (),
    .card_present_o   (),
    .card_change_o    (),
    .sd_clk_ratio_o   (),
    .sd_clk_en_o      (),
    .cmd_clk_i        (1'b0),
    .bus_wide_o       (),
    .xfer_go_o        (),
    .sys_phase_o      (),
    .ramp_done_o      (),
    .cfg_start_o      (),

    .stat_clear_i     (stat_clear_i),

    .accept_i         (accept_o),
    .busy_i           (busy_o),
    .fail_code_i      (fail_code_o),
    .card_ready_i     (card_ready_i),
    .speed_i          (speed_const),
    .init_err_i       (1'b0),
    .init_err_code_i  (init_err_const),

    .status_o         (status),
    .err_o            (stat_err),
    .irq_set_o        (irq_set),

    // Silme komutu buradan cikip sayac sahiplerine gider (cdc.md 9).
    .stat_clear_tgl_o (stat_clear_tgl_i)
  );

  always @(posedge clk) begin
    if(!rst_n)begin saw_done_irq<=0;saw_err_irq<=0;gap_cycles<=0;end
    else begin
      if(irq_set[IRQ_DONE_BIT])saw_done_irq<=1;
      if(irq_set[IRQ_ERR_BIT])saw_err_irq<=1;
      gap_cycles<=int'(stat_gap_o);
    end
  end
  task automatic check(input logic c,input string m);checks++;if(!c)begin failures++;$display("FAIL: %s",m);end endtask
  task automatic reset_dut;rst_n=0;go_i=0;req_ready_i=0;rsp_valid_i=0;rx_valid_i=0;rx_done_i=0;
    repeat(3)@(posedge clk);rst_n=1;repeat(5)@(posedge clk);endtask
  task automatic launch;@(negedge clk);go_i=1;endtask
  task automatic answer_cmd(input logic[5:0] exp);int t;t=0;
    while(!req_valid_o&&t<30)begin @(posedge clk);#1;t++;end check(req_index_o==exp,"block command index");
    req_ready_i=1;while(req_valid_o)begin @(posedge clk);#1;end req_ready_i=0;
    @(negedge clk);rsp_valid_i=1;@(posedge clk);#1;@(negedge clk);rsp_valid_i=0;
  endtask
  task automatic wait_fin;int t;t=0;while(!fin_o&&t<40)begin @(posedge clk);#1;t++;end check(fin_o,"block completion bounded");endtask

  initial begin
    checks=0;failures=0;card_present_i=1;card_ready_i=1;lba_i=32'h20;blocks_i=1;dir_i=0;
    speed_const=SPEED_HS;init_err_const=ERR_OK;
    card_blk_i=32'h10000;block_addr_i=1;rca_i=16'h1234;rsp_err_i=0;cmd_err_i=ERR_OK;
    tx_take_i=0;tx_done_i=0;tx_status_ok_i=1;tx_status_tmo_i=0;rx_data_i=0;rx_busy_i=0;
    rx_crc_ok_i=1;dat_active_i=0;card_busy_i=0;rd_room_ok_i=1;wr_data_i=0;wr_last_i=0;
    wr_block_ready_i=1;stat_clear_i=0;

    reset_dut();launch();answer_cmd(CMD17_READ_SINGLE_BLOCK);
    repeat(3)begin @(negedge clk);rx_valid_i=1;dat_active_i=1;@(posedge clk);#1;@(negedge clk);rx_valid_i=0;end
    @(negedge clk);dat_active_i=0;rx_done_i=1;rx_crc_ok_i=1;@(posedge clk);#1;@(negedge clk);rx_done_i=0;
    wait_fin();repeat(3)@(posedge clk);#1;
    check(status[STATUS_DONE_BIT]&&!status[STATUS_BUSY_BIT],"STATUS DONE/BUSY from block events");
    check(stat_err==ERR_OK&&saw_done_irq&&!saw_err_irq,"successful block IRQ and ERR");
    // Tek blok, gap yok: sayac bosta kalmali. Gap'in saymasini cok bloklu
    // akista tb_block_flow goruyor.
    check(stat_gap_o==32'd0,$sformatf("STAT_GAP idle on a single block (%0d)",stat_gap_o));
    check(stat_retry_crc_o==16'd0,"STAT_RETRY idle with no CRC failure");

    // A new accepted request clears DONE; an invalid range becomes ERR_RANGE.
    @(negedge clk);go_i=0;repeat(5)@(posedge clk);lba_i=32'hffff;blocks_i=2;
    launch();wait_fin();repeat(3)@(posedge clk);#1;
    check(stat_err==ERR_RANGE&&saw_err_irq,"block error propagates to ERR/IRQ");
    check(status[STATUS_DONE_BIT],"failed request still completes exactly once");

    @(negedge clk);stat_clear_i=1;@(posedge clk);#1;@(negedge clk);stat_clear_i=0;
    repeat(5)@(posedge clk);#1;
    check(stat_gap_o==32'd0&&stat_retry_crc_o==16'd0,"STAT_CLEAR clears the block-layer counters");
    if(failures)begin $display("tb_block_stat: FAILED (%0d/%0d)",failures,checks);$fatal(1);end
    $display("tb_block_stat: PASSED (%0d checks)",checks);$finish;
  end
  initial begin #1_000_000;$fatal(1,"tb_block_stat timeout");end
endmodule
