`default_nettype none
// Load-time nearest/bilinear scaler. Always emits a complete top-down frame.
// Pixel-centre mapping: floor((2*x+1)*source_size/(2*draw_size)).
// Division is iterative at frame setup; pixel mapping uses add/subtract only.
module bmp_scaled_read #(
    parameter integer OUT_W=640, OUT_H=480,
    parameter integer BILINEAR=0,
    parameter integer TIMEOUT_CYCLES=50_000_000
)(
    input wire clk,rst,sd_init_done,
    output wire ready,
    input wire scan_start,
    input wire [31:0] scan_start_sector,scan_max_sector,
    input wire [2:0] scan_target_count,
    output reg scan_done,scan_found_valid,
    output reg [31:0] scan_found_sector,
    output reg [2:0] scan_found_total,
    input wire load_start,load_abort,
    input wire [31:0] load_sector,
    output wire [3:0] state_code,
    output reg load_failed,
    output reg write_req,
    input wire write_req_ack,write_ready,
    output wire bmp_data_wr_en,
    output wire [23:0] bmp_data,
    output wire sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid,sd_sec_read_end,
    output wire source_meta_valid,
    output wire [15:0] source_width,source_height
);
    localparam IDLE=0,SCAN_OPEN=1,SCAN_WAIT=2,LOAD_OPEN=3,LOAD_WAIT=4,
      FIT=5,DIVIDE=6,FIT_DONE=7,WR_ACK=8,WR_RELEASE=9,
      LINE=10,YNORM=11,ROW_REQ=12,ROW_WAIT=13,XNORM=14,
      FETCH=15,EMIT=16,NEXT_PIXEL=17,ABORT=18,
      YCOORD=19,YFRAC=20,CACHE=21,XCOORD=22,XFRAC=23,
      BFETCH0=24,BFETCH1=25,BHORIZ=26,BVERT=27;
    reg [4:0] state;
    reg open_req,row_req;
    reg [31:0] cursor,open_sector;
    wire opened,meta_valid,open_ready,row_ready,row_done,pv;
    wire [3:0] error_code;
    wire [15:0] sw,sh,px,py;
    assign source_width=sw;
    assign source_height=sh;
    assign source_meta_valid=(state==LOAD_WAIT && opened && meta_valid);
    wire [31:0] file_sectors;
    wire [23:0] rgb;
    // Output coordinates are bounded by OUT_W/H; source pixel indices
    // are <1024/<768. Narrow only unreachable bits, keeping every state.
    localparam X_BITS=(OUT_W<2)?1:$clog2(OUT_W+1);
    localparam Y_BITS=(OUT_H<2)?1:$clog2(OUT_H+1);
    localparam X_ACC_MAX=2*OUT_W+2048;
    localparam Y_ACC_MAX=2*OUT_H+1536;
    localparam ACC_BITS=$clog2(((X_ACC_MAX>Y_ACC_MAX)?X_ACC_MAX:Y_ACC_MAX)+1);
    localparam FRAC_BITS=$clog2(2*((OUT_W>OUT_H)?OUT_W:OUT_H)+1);
    reg [X_BITS-1:0] draw_w,left_pad,ox;
    reg [Y_BITS-1:0] draw_h,top_pad,oy;
    reg [9:0] sx,sy;
    reg [ACC_BITS-1:0] x_acc,y_acc;
    wire [17:0] x_den={1'b0,draw_w,1'b0},y_den={1'b0,draw_h,1'b0};
    reg [9:0] cached_y;
    reg cache_valid,fit_width;
    // Adjacent logical rows have opposite parity. Tags protect reuse on jumps.
    reg [9:0] cached_y_b,fetch_y,bx0,bx1,by0,by1;
    reg cache_valid_b;
    reg [7:0] wx,wy;
    reg [FRAC_BITS-1:0] frac_rem;
    reg [3:0] frac_count;
    wire [FRAC_BITS:0] frac_trial={frac_rem,1'b0};
    reg [23:0] line_ram_b[0:1023]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] line_q_b,left_a,left_b,bilinear_rgb;
    reg [47:0] horiz_top,horiz_bottom;
    reg [23:0] line_ram[0:1023]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] line_q;
    // Validated headers are bounded to 1024x768. Preserve all 32 setup
    // clocks, but omit known-zero numerator rounds and unused high bits.
    localparam DIV_NUM_MAX=(1024*OUT_H>768*OUT_W)?1024*OUT_H:768*OUT_W;
    localparam DIV_NUM_BITS=$clog2(DIV_NUM_MAX+1);
    localparam DIV_WIDTH=(DIV_NUM_BITS<16)?16:DIV_NUM_BITS;
    reg [DIV_WIDTH-1:0] quotient;
    reg [9:0] remainder; // remainder < divisor <= 1024
    reg [10:0] divisor;
    reg [5:0] div_count;
    wire [10:0] trial={remainder,quotient[DIV_WIDTH-1]};
    wire image_line=(oy>=top_pad && oy<top_pad+draw_h);
    wire image_pixel=image_line && ox>=left_pad && ox<left_pad+draw_w;
    assign ready=state==IDLE && open_ready && !load_abort;
    assign state_code=!sd_init_done ? 0 : load_failed ? 5 :
        (state==SCAN_OPEN || state==SCAN_WAIT) ? 2 :
        (state==WR_ACK || state==WR_RELEASE) ? 3 : state==IDLE ? 1 : 4;
    assign bmp_data_wr_en=state==EMIT && write_ready && !load_abort;
    assign bmp_data=image_pixel ? (BILINEAR?bilinear_rgb:line_q) : 24'd0;
    // Exact 8-bit fractional lerp, retaining all horizontal fractional bits.
    function [15:0] hmix;
        input [7:0] a,b,f;
        reg signed [8:0] difference;
        reg signed [17:0] product;
        reg signed [18:0] result;
        begin
            difference=$signed({1'b0,b})-$signed({1'b0,a});
            product=difference*$signed({1'b0,f});
            result=$signed({1'b0,a,8'd0})+product;
            hmix=result[15:0];
        end
    endfunction
    function [7:0] vmix;
        input [15:0] a,b;
        input [7:0] f;
        reg signed [16:0] difference;
        reg signed [25:0] product;
        reg signed [26:0] result;
        begin
            difference=$signed({1'b0,b})-$signed({1'b0,a});
            product=difference*$signed({1'b0,f});
            result=$signed({1'b0,a,8'd0})+product+27'sd32768;
            vmix=result[23:16]; // round once after both axes, never overflow white
        end
    endfunction
    wire [23:0] top_left=by0[0]?left_b:left_a;
    wire [23:0] top_right=by0[0]?line_q_b:line_q;
    wire [23:0] bottom_left=by1[0]?left_b:left_a;
    wire [23:0] bottom_right=by1[0]?line_q_b:line_q;
    wire [9:0] ram_read_x=BILINEAR ? ((state==BFETCH1)?bx1[9:0]:bx0[9:0]) : sx[9:0];
    wire ram_read_enable=(state==FETCH || state==BFETCH0 || state==BFETCH1);
    always @(posedge clk) begin
        if(state==ROW_WAIT && pv) begin
            if(BILINEAR && fetch_y[0]) line_ram_b[px[9:0]]<=rgb;
            else line_ram[px[9:0]]<=rgb;
        end
        if(ram_read_enable) line_q<=line_ram[ram_read_x];
        if(ram_read_enable && BILINEAR) line_q_b<=line_ram_b[ram_read_x];
    end
    bmp_row_reader #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) row_source(
        .clk(clk),.rst(rst),.cancel(load_abort),.sd_init_done(sd_init_done),
        .open_req(open_req),.open_ready(open_ready),.open_sector(open_sector),
        .open_done(opened),.meta_valid(meta_valid),.error_code(error_code),
        .src_width(sw),.src_height(sh),.row_stride(),.top_down(),
        .pixel_offset(),.file_bytes(),.file_sectors(file_sectors),
        .row_req(row_req),.row_ready(row_ready),.row_y({6'd0,(BILINEAR?fetch_y:sy)}),.row_done(row_done),
        .pixel_valid(pv),.pixel_ready(state==ROW_WAIT),.pixel_rgb(rgb),
        .pixel_x(px),.pixel_y(py),.pixel_last(),
        .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),.debug_state());
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;open_req<=0;row_req<=0;cursor<=0;open_sector<=0;
            scan_done<=0;scan_found_valid<=0;scan_found_sector<=0;scan_found_total<=0;
            load_failed<=0;write_req<=0;draw_w<=0;draw_h<=0;left_pad<=0;top_pad<=0;
            ox<=0;oy<=0;sx<=0;sy<=0;x_acc<=0;y_acc<=0;
            cache_valid<=0;cached_y<=0;fit_width<=0;
            cache_valid_b<=0;cached_y_b<=0;fetch_y<=0;bx0<=0;bx1<=0;by0<=0;by1<=0;
            wx<=0;wy<=0;frac_rem<=0;frac_count<=0;left_a<=0;left_b<=0;
            bilinear_rgb<=0;horiz_top<=0;horiz_bottom<=0;
            quotient<=0;remainder<=0;divisor<=0;div_count<=0;
        end else begin
            open_req<=0;row_req<=0;scan_found_valid<=0;
            if(!sd_init_done) begin state<=IDLE;write_req<=0;scan_done<=0;cache_valid<=0;cache_valid_b<=0;end
            else if(load_abort) begin
                state<=ABORT;write_req<=0;load_failed<=1;cache_valid<=0;cache_valid_b<=0;
            end else case(state)
                IDLE: begin
                    if(scan_start) begin
                        cursor<=scan_start_sector;scan_done<=0;scan_found_total<=0;
                        load_failed<=0;state<=SCAN_OPEN;
                    end else if(load_start) begin
                        open_sector<=load_sector;load_failed<=0;cache_valid<=0;cache_valid_b<=0;state<=LOAD_OPEN;
                    end
                end
                SCAN_OPEN: if(open_ready) begin
                    if(cursor>scan_max_sector) begin scan_done<=1;state<=IDLE;end
                    else begin open_sector<=cursor;open_req<=1;state<=SCAN_WAIT;end
                end
                SCAN_WAIT: if(opened) begin
                    if(error_code==3 || error_code==4) begin load_failed<=1;scan_done<=1;state<=ABORT;end
                    else begin
                        if(meta_valid && cursor+file_sectors<=scan_max_sector+1) begin
                            scan_found_valid<=1;scan_found_sector<=cursor;
                            scan_found_total<=scan_found_total+1'b1;
                        end
                        if((meta_valid && scan_found_total+1>=scan_target_count) ||
                           cursor+(meta_valid?file_sectors:32'd1)>scan_max_sector) begin
                            scan_done<=1;state<=IDLE;
                        end else begin cursor<=cursor+(meta_valid?file_sectors:32'd1);state<=SCAN_OPEN;end
                    end
                end
                LOAD_OPEN: if(open_ready) begin open_req<=1;state<=LOAD_WAIT;end
                LOAD_WAIT: if(opened) begin
                    if(!meta_valid) begin load_failed<=1;state<=ABORT;end else state<=FIT;
                end
                FIT: begin
                    fit_width<=(sw*OUT_H>=sh*OUT_W);
                    if(sw*OUT_H>=sh*OUT_W) begin quotient<=sh*OUT_W;divisor<=sw[10:0];end
                    else begin quotient<=sw*OUT_H;divisor<=sh[10:0];end
                    remainder<=0;div_count<=32;state<=DIVIDE;
                end
                DIVIDE: if(div_count!=0) begin
                    if(div_count<=DIV_WIDTH) begin
                        if(trial>=divisor) begin remainder<=trial-divisor;quotient<={quotient[DIV_WIDTH-2:0],1'b1};end
                        else begin remainder<=trial[9:0];quotient<={quotient[DIV_WIDTH-2:0],1'b0};end
                    end
                    div_count<=div_count-1'b1;
                end else begin
                    draw_w<=fit_width?OUT_W:(quotient==0?1:quotient[15:0]);
                    draw_h<=fit_width?(quotient==0?1:quotient[15:0]):OUT_H;
                    state<=FIT_DONE;
                end
                FIT_DONE: begin
                    left_pad<=(OUT_W-draw_w)>>1;top_pad<=(OUT_H-draw_h)>>1;
                    ox<=0;oy<=0;sx<=0;sy<=0;y_acc<=sh;
                    write_req<=1;state<=WR_ACK;
                end
                WR_ACK: if(write_req_ack) begin write_req<=0;state<=WR_RELEASE;end
                // Do not write while FIFO clear from the four-phase ACK is active.
                WR_RELEASE: if(!write_req_ack && write_ready) state<=LINE;
                LINE: begin
                    sx<=0;x_acc<=sw;
                    if(image_line) state<=YNORM;else state<=EMIT;
                end
                YNORM: if(y_acc>=y_den) begin y_acc<=y_acc-y_den;sy<=sy+1'b1;end
                else if(BILINEAR) state<=YCOORD;
                else if(cache_valid && cached_y==sy) state<=XNORM;
                else state<=ROW_REQ;
                ROW_REQ: if(row_ready) begin row_req<=1;state<=ROW_WAIT;end
                ROW_WAIT: if(row_done) begin
                    if(error_code!=0) begin load_failed<=1;state<=ABORT;end
                    else if(BILINEAR) begin
                        if(fetch_y[0]) begin cached_y_b<=fetch_y;cache_valid_b<=1;end
                        else begin cached_y<=fetch_y;cache_valid<=1;end
                        state<=CACHE;
                    end else begin cached_y<=sy;cache_valid<=1;state<=XNORM;end
                end
                XNORM: if(x_acc>=x_den) begin x_acc<=x_acc-x_den;sx<=sx+1'b1;end
                else state<=BILINEAR?XCOORD:FETCH;
                FETCH: state<=EMIT;
                // Convert centre position into floor(position-0.5) + fraction.
                YCOORD: begin
                    wy<=0;frac_count<=8;state<=YFRAC;
                    if(y_acc<draw_h) begin
                        if(sy==0) begin by0<=0;by1<=0;frac_rem<=0;end
                        else begin by0<=sy-1'b1;by1<=sy;frac_rem<=y_acc+draw_h;end
                    end else begin
                        by0<=sy;by1<=(sy+1'b1<sh)?sy+1'b1:sy;
                        frac_rem<=y_acc-draw_h;
                    end
                end
                YFRAC: if(frac_count!=0) begin
                    if(frac_trial>={1'b0,y_den}) begin frac_rem<=frac_trial-y_den;wy<={wy[6:0],1'b1};end
                    else begin frac_rem<=frac_trial[FRAC_BITS-1:0];wy<={wy[6:0],1'b0};end
                    frac_count<=frac_count-1'b1;
                end else state<=CACHE;
                CACHE: begin
                    if(by0[0] ? (!cache_valid_b || cached_y_b!=by0) : (!cache_valid || cached_y!=by0)) begin
                        fetch_y<=by0;state<=ROW_REQ;
                    end else if(by1[0] ? (!cache_valid_b || cached_y_b!=by1) : (!cache_valid || cached_y!=by1)) begin
                        fetch_y<=by1;state<=ROW_REQ;
                    end else state<=XNORM;
                end
                XCOORD: begin
                    wx<=0;frac_count<=8;state<=XFRAC;
                    if(x_acc<draw_w) begin
                        if(sx==0) begin bx0<=0;bx1<=0;frac_rem<=0;end
                        else begin bx0<=sx-1'b1;bx1<=sx;frac_rem<=x_acc+draw_w;end
                    end else begin
                        bx0<=sx;bx1<=(sx+1'b1<sw)?sx+1'b1:sx;
                        frac_rem<=x_acc-draw_w;
                    end
                end
                XFRAC: if(frac_count!=0) begin
                    if(frac_trial>={1'b0,x_den}) begin frac_rem<=frac_trial-x_den;wx<={wx[6:0],1'b1};end
                    else begin frac_rem<=frac_trial[FRAC_BITS-1:0];wx<={wx[6:0],1'b0};end
                    frac_count<=frac_count-1'b1;
                end else state<=BFETCH0;
                BFETCH0: state<=BFETCH1;
                BFETCH1: begin left_a<=line_q;left_b<=line_q_b;state<=BHORIZ;end
                BHORIZ: begin
                    horiz_top<={hmix(top_left[23:16],top_right[23:16],wx),hmix(top_left[15:8],top_right[15:8],wx),hmix(top_left[7:0],top_right[7:0],wx)};
                    horiz_bottom<={hmix(bottom_left[23:16],bottom_right[23:16],wx),hmix(bottom_left[15:8],bottom_right[15:8],wx),hmix(bottom_left[7:0],bottom_right[7:0],wx)};
                    state<=BVERT;
                end
                BVERT: begin
                    bilinear_rgb<={vmix(horiz_top[47:32],horiz_bottom[47:32],wy),vmix(horiz_top[31:16],horiz_bottom[31:16],wy),vmix(horiz_top[15:0],horiz_bottom[15:0],wy)};
                    state<=EMIT;
                end
                EMIT: if(write_ready) state<=NEXT_PIXEL;
                NEXT_PIXEL: begin
                    if(ox==OUT_W-1) begin
                        ox<=0;
                        if(oy==OUT_H-1) state<=IDLE;
                        else begin
                            oy<=oy+1'b1;if(image_line) y_acc<=y_acc+{1'b0,sh,1'b0};
                            state<=LINE;
                        end
                    end else begin
                        ox<=ox+1'b1;
                        if(image_pixel && ox+1'b1<left_pad+draw_w) begin x_acc<=x_acc+{1'b0,sw,1'b0};state<=XNORM;end
                        else if(image_line && ox+1'b1==left_pad) state<=XNORM;
                        else state<=EMIT;
                    end
                end
                ABORT: if(open_ready) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
