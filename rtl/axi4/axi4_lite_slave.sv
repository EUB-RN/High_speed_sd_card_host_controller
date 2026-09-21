module axi_slave #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter BASE_ADDR  = 32'h0000_0000,
    parameter HIGH_ADDR  = 32'h0000_FFFF
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // Write Address Channel
    input  logic [ADDR_WIDTH-1:0]    AWADDR,
    input  logic                     AWVALID,
    output logic                     AWREADY,

    // Write Data Channel
    input  logic [DATA_WIDTH-1:0]    WDATA,
    input  logic [DATA_WIDTH/8-1:0]  WSTRB,
    input  logic                     WVALID,
    output logic                     WREADY,

    // Write Response Channel
    output logic [1:0]               BRESP,
    output logic                     BVALID,
    input  logic                     BREADY,

    // Read Address Channel
    input  logic [ADDR_WIDTH-1:0]    ARADDR,
    input  logic                     ARVALID,
    output logic                     ARREADY,

    // Read Data Channel
    output logic [DATA_WIDTH-1:0]    RDATA,
    output logic [1:0]               RRESP,
    output logic                     RVALID,
    input  logic                     RREADY,

    // RAM / Register Interface
    output logic                     wr_en,
    output logic [ADDR_WIDTH-1:0]    wr_addr,
    output logic [DATA_WIDTH-1:0]    wr_data,
    output logic [DATA_WIDTH/8-1:0]  wr_strb,

    output logic                     rd_en,
    output logic [ADDR_WIDTH-1:0]    rd_addr,
    input  logic [DATA_WIDTH-1:0]    rd_data
);

    
    logic aw_valid_addr;
    logic ar_valid_addr;
    
    assign aw_valid_addr = (AWADDR >= BASE_ADDR) && (AWADDR <= HIGH_ADDR);
    assign ar_valid_addr = (ARADDR >= BASE_ADDR) && (ARADDR <= HIGH_ADDR);

    //--------------------------------------------------------------------------
    // YAZMA KANALI (Write Channel)
    //--------------------------------------------------------------------------
    logic wr_handshake;
   
    assign AWREADY = WVALID && (!BVALID || BREADY);
    assign WREADY  = AWVALID && (!BVALID || BREADY);

    
    assign wr_handshake = AWVALID && WVALID && (!BVALID || BREADY);

    assign wr_addr = AWADDR;
    assign wr_data = WDATA;
    assign wr_strb = WSTRB;
    assign wr_en   = wr_handshake && aw_valid_addr;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            BVALID <= 1'b0;
            BRESP  <= 2'b00; 
        end else begin
            if (wr_handshake) begin
                BVALID <= 1'b1;
               
                BRESP  <= aw_valid_addr ? 2'b00 : 2'b10; 
            end else if (BVALID && BREADY) begin 
                BVALID <= 1'b0;
            end
        end
    end


    logic rd_handshake;


    assign rd_handshake = ARVALID && ARREADY;

    
    assign ARREADY = !RVALID || RREADY;

    // Bellek/Arayüz Sürme Sinyalleri
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
                RRESP  <= ar_valid_addr ? 2'b00 : 2'b10; 
                RDATA  <= ar_valid_addr ? rd_data : '0;
            end else if (RVALID && RREADY) begin 
                RVALID <= 1'b0;
            end
        end
    end

endmodule