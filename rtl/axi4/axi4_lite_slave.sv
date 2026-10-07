module axi4_lite_slave #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter BASE_ADDR  = 32'h0000_0000,
    parameter HIGH_ADDR  = 32'h0000_FFFF
) (
    input  logic                     clk,
    input  logic                     reset_n,

    input  logic [ADDR_WIDTH-1:0]    AWADDR,
    input  logic                     AWVALID,
    output logic                     AWREADY,

    input  logic [DATA_WIDTH-1:0]    WDATA,
    input  logic [DATA_WIDTH/8-1:0]  WSTRB,
    input  logic                     WVALID,
    output logic                     WREADY,

    output logic [1:0]               BRESP,
    output logic                     BVALID,
    input  logic                     BREADY,

    input  logic [ADDR_WIDTH-1:0]    ARADDR,
    input  logic                     ARVALID,
    output logic                     ARREADY,

    output logic [DATA_WIDTH-1:0]    RDATA,
    output logic [1:0]               RRESP,
    output logic                     RVALID,
    input  logic                     RREADY,

    output logic                     wr_en,
    output logic [ADDR_WIDTH-1:0]    wr_addr,
    output logic [DATA_WIDTH-1:0]    wr_data,
    output logic [DATA_WIDTH/8-1:0]  wr_strb,

    output logic                     rd_en,
    output logic [ADDR_WIDTH-1:0]    rd_addr,
    input  logic [DATA_WIDTH-1:0]    rd_data,

    input  logic [1:0]               bresp_r,
    input  logic [1:0]               rresp_r
);

    logic aw_valid_addr;
    logic ar_valid_addr;

    localparam logic [ADDR_WIDTH-1:0] WINDOW_TOP =
        ADDR_WIDTH'(HIGH_ADDR - BASE_ADDR);

    localparam bit WINDOW_PARTIAL = (ADDR_WIDTH >= 32) ? 1'b1
                 : (((HIGH_ADDR - BASE_ADDR) + 32'd1) < (32'd1 << ADDR_WIDTH));

    if (WINDOW_PARTIAL) begin : g_window_check
        assign aw_valid_addr = ((AWADDR - ADDR_WIDTH'(BASE_ADDR)) <= WINDOW_TOP);
        assign ar_valid_addr = ((ARADDR - ADDR_WIDTH'(BASE_ADDR)) <= WINDOW_TOP);
    end else begin : g_window_full
        assign aw_valid_addr = 1'b1;
        assign ar_valid_addr = 1'b1;
    end

    logic wr_handshake;

    assign AWREADY = reset_n && WVALID && (!BVALID || BREADY);
    assign WREADY  = reset_n && AWVALID && (!BVALID || BREADY);

    assign wr_handshake = AWVALID && AWREADY;

    assign wr_addr = AWADDR;
    assign wr_data = WDATA;
    assign wr_strb = WSTRB;
    assign wr_en   = wr_handshake && aw_valid_addr;

    logic wr_in_window_q;

    assign BRESP = wr_in_window_q ? bresp_r : 2'b10;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            BVALID         <= 1'b0;
            wr_in_window_q <= 1'b0;
        end else begin
            if (wr_handshake) begin
                BVALID         <= 1'b1;
                wr_in_window_q <= aw_valid_addr;
            end else if (BVALID && BREADY) begin
                BVALID <= 1'b0;
            end
        end
    end

    logic rd_handshake;

    assign rd_handshake = ARVALID && ARREADY;

    assign ARREADY = reset_n && (!RVALID || RREADY);

    assign rd_addr = ARADDR;
    assign rd_en   = rd_handshake && ar_valid_addr;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            RVALID <= 1'b0;
            RRESP  <= 2'b00;
            RDATA  <= '0;
        end else begin
            if (rd_handshake) begin
                RVALID <= 1'b1;

                RRESP  <= ar_valid_addr ? rresp_r : 2'b10;
                RDATA  <= ar_valid_addr ? rd_data : '0;
            end else if (RVALID && RREADY) begin
                RVALID <= 1'b0;
            end
        end
    end

endmodule