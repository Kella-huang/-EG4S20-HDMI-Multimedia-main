`default_nettype none
// Board exerciser: scan four BMPs, pull every logical row, and expose an
// order-sensitive 24-bit pixel signature. No scaled frame is published yet.
module bmp_row_diagnostic #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter [31:0] SCAN_MAX_SECTOR=131071
)(
    input wire clk,rst,key_next,key_page,
    output wire SD_nCS,SD_DCLK,SD_MOSI,input wire SD_MISO,
    output reg [23:0] digits
);
    wire init_done,read_req,read_valid,read_end;
    wire [31:0] read_addr;
    wire [7:0] read_byte;
    wire next_press,page_press;
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(50)) kn(
        .clk(clk),.rst(rst),.button_in(key_next),.press_pulse(next_press));
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(50)) kp(
        .clk(clk),.rst(rst),.button_in(key_page),.press_pulse(page_press));
    reg open_req,row_req;
    reg [31:0] open_sector,cursor,sectors[0:3];
    reg [15:0] row_y;
    wire open_ready,opened,meta_valid,row_ready,row_done,pixel_valid,pixel_last;
    wire [3:0] error_code,reader_state;
    wire [15:0] width,height,stride,px,py;
    wire [31:0] offset,file_bytes,file_sectors;
    wire top_down;
    wire [23:0] rgb;
    reg [7:0] throttle;
    // Deliberate backpressure exercises hold/restart even without a scaler.
    wire pixel_ready=(throttle[3:0]!=0 && throttle[3:0]!=1);
    reg [23:0] signature;
    reg [2:0] found_count;
    reg [1:0] image_index,page;
    reg [3:0] fault;
    reg completed,next_pending,buttons_armed;
    wire [3:0] image_digit={2'b00,image_index}+4'd1;
    localparam INIT=0,SCAN_REQ=1,SCAN_WAIT=2,LOAD_REQ=3,LOAD_WAIT=4,
               ROW_REQ=5,ROW_WAIT=6,DONE=7,FAILED=8;
    reg [3:0] state;
    reg [3:0] phase_digit;
    always @* begin
        if(state==INIT) phase_digit=0;
        else if(state==SCAN_REQ || state==SCAN_WAIT) phase_digit=1;
        else if(state==DONE) phase_digit=3;
        else if(state==FAILED) phase_digit=4;
        else phase_digit=2;
        case(page)
            0:digits={4'hd,image_digit,1'b0,found_count,fault,phase_digit,3'b000,completed};
            1:digits={4'ha,image_digit,width};
            2:digits={4'hb,image_digit,height};
            default:digits=signature;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=INIT;open_req<=0;row_req<=0;open_sector<=0;cursor<=0;row_y<=0;
            found_count<=0;image_index<=0;page<=0;signature<=24'h5a17c3;throttle<=0;
            fault<=0;completed<=0;next_pending<=0;
            buttons_armed<=0;
            sectors[0]<=0;sectors[1]<=0;sectors[2]<=0;sectors[3]<=0;
        end else begin
            open_req<=0;row_req<=0;throttle<=throttle+1'b1;
            if(key_next && key_page) buttons_armed<=1;
            if(buttons_armed && page_press) page<=page+1'b1;
            if(buttons_armed && next_press) next_pending<=1;
            if(pixel_valid && pixel_ready)
                signature<={signature[22:0],signature[23]}+rgb;
            case(state)
                INIT: if(init_done) state<=SCAN_REQ;
                SCAN_REQ: if(open_ready) begin open_sector<=cursor;open_req<=1;state<=SCAN_WAIT;end
                SCAN_WAIT: if(opened) begin
                    if(error_code==4 || error_code==3) begin fault<=error_code;state<=FAILED;end
                    else begin
                        if(meta_valid) begin sectors[found_count[1:0]]<=cursor;found_count<=found_count+1'b1;end
                        if((meta_valid && found_count==3) ||
                           cursor+(meta_valid?file_sectors:32'd1)>SCAN_MAX_SECTOR) begin
                            if(found_count!=0 || meta_valid) state<=LOAD_REQ;
                            else begin fault<=8;state<=FAILED;end
                        end else begin
                            cursor<=cursor+(meta_valid?file_sectors:32'd1);state<=SCAN_REQ;
                        end
                    end
                end
                LOAD_REQ: if(open_ready) begin
                    open_sector<=sectors[image_index];open_req<=1;state<=LOAD_WAIT;
                    signature<=24'h5a17c3;completed<=0;fault<=0;row_y<=0;next_pending<=0;
                end
                LOAD_WAIT: if(opened) begin
                    if(!meta_valid) begin fault<=error_code;state<=FAILED;end
                    else state<=ROW_REQ;
                end
                ROW_REQ: if(row_ready) begin row_req<=1;state<=ROW_WAIT;end
                ROW_WAIT: if(row_done) begin
                    if(error_code!=0) begin fault<=error_code;state<=FAILED;end
                    else if(row_y==height-1'b1) begin completed<=1;state<=DONE;end
                    else begin row_y<=row_y+1'b1;state<=ROW_REQ;end
                end
                DONE,FAILED: if(next_pending && found_count!=0 && open_ready) begin
                    image_index<=({1'b0,image_index}+3'd1>=found_count)?2'd0:image_index+1'b1;
                    page<=0;state<=LOAD_REQ;
                end
                default:state<=INIT;
            endcase
        end
    end
    bmp_row_reader #(.MAX_SECTOR(SCAN_MAX_SECTOR),.TIMEOUT_CYCLES(CLK_FREQ_HZ)) reader(
        .clk(clk),.rst(rst),.cancel(1'b0),.sd_init_done(init_done),
        .open_req(open_req),.open_ready(open_ready),.open_sector(open_sector),
        .open_done(opened),.meta_valid(meta_valid),.error_code(error_code),
        .src_width(width),.src_height(height),.row_stride(stride),.top_down(top_down),
        .pixel_offset(offset),.file_bytes(file_bytes),.file_sectors(file_sectors),
        .row_req(row_req),.row_ready(row_ready),.row_y(row_y),.row_done(row_done),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_rgb(rgb),
        .pixel_x(px),.pixel_y(py),.pixel_last(pixel_last),
        .sd_sec_read(read_req),.sd_sec_read_addr(read_addr),.sd_sec_read_data(read_byte),
        .sd_sec_read_data_valid(read_valid),.sd_sec_read_end(read_end),.debug_state(reader_state));
    sd_card_top #(.SPI_LOW_SPEED_DIV((CLK_FREQ_HZ>=800000)?CLK_FREQ_HZ/400000-2:0)) transport(
        .clk(clk),.rst(rst),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
        .sd_init_done(init_done),.sd_sec_read(read_req),.sd_sec_read_addr(read_addr),
        .sd_sec_read_data(read_byte),.sd_sec_read_data_valid(read_valid),.sd_sec_read_end(read_end),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end());
endmodule
`default_nettype wire
