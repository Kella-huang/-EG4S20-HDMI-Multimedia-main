`default_nettype none
// Pull-based BMP source for a future load-time scaler. One complete logical
// top-down RGB888 row is buffered BEFORE output. No source-sector backpressure
// is needed: a requested sector is always fully consumed, including its tail.
module bmp_row_reader #(
    parameter integer MAX_WIDTH=1024, MAX_HEIGHT=768,
    parameter [31:0] MAX_SECTOR=131071,
    parameter integer TIMEOUT_CYCLES=100_000_000
)(
    input wire clk,rst,cancel,sd_init_done,
    input wire open_req,
    output wire open_ready,
    input wire [31:0] open_sector,
    output reg open_done,meta_valid,
    output reg [3:0] error_code, // 1 header, 2 row range, 3 short sector, 4 timeout/cancel
    output reg [15:0] src_width,src_height,row_stride,
    output reg top_down,
    output reg [31:0] pixel_offset,file_bytes,file_sectors,
    input wire row_req,
    output wire row_ready,
    input wire [15:0] row_y,
    output reg row_done,
    output wire pixel_valid,
    input wire pixel_ready,
    output wire [23:0] pixel_rgb,
    output reg [15:0] pixel_x,pixel_y,
    output wire pixel_last,
    output reg sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid,sd_sec_read_end,
    output wire [3:0] debug_state
);
    localparam IDLE=0,HREAD=1,HCHECK=2,HSIZE=3,HEND=4,
               RCALC=5,RADDR=6,RREAD=7,RGAP=8,PRIME=9,EMIT=10,DRAIN=11,ABORT_GAP=12;
    reg [3:0] state;
    assign debug_state=state;
    assign open_ready=(state==IDLE && sd_init_done && !cancel);
    assign row_ready=open_ready && meta_valid && !open_req;
    assign pixel_valid=(state==EMIT);
    assign pixel_last=(pixel_x==src_width-1'b1);
    localparam ROW_ADDR_BITS=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH);
    reg [23:0] row_ram[0:MAX_WIDTH-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] row_q;
    assign pixel_rgb=row_q;
    // Synchronous, enabled RAM output; remains stable throughout backpressure.
    always @(posedge clk) if(state==PRIME) row_q<=row_ram[pixel_x[ROW_ADDR_BITS-1:0]];

    reg [31:0] base_sector;
    reg [9:0] byte_count;
    reg [7:0] sig0,sig1;
    reg [31:0] hsize,hlen,hoff,hw,hh,hcomp;
    reg [15:0] hplanes,hbits;
    wire [31:0] abs_height=hh[31] ? (~hh+32'd1) : hh;
    wire [31:0] stride_calc=((hw<<1)+hw+32'd3)&32'hfffffffc;
    reg [31:0] accum,multiplicand;
    reg [15:0] multiplier;
    reg [4:0] calc_left;
    wire [32:0] data_end={1'b0,hoff}+{1'b0,accum};
    wire [32:0] sector_span=({1'b0,hlen}+33'd511)>>9;
    wire header_bad=(sig0!="B" || sig1!="M" || hw==0 || hw>MAX_WIDTH ||
        abs_height==0 || abs_height>MAX_HEIGHT ||
        !(hsize==40 || hsize==108 || hsize==124) ||
        hplanes!=1 || hbits!=24 || hcomp!=0 ||
        hoff<14+hsize || hlen<hoff || hlen>32'd67108864 ||
        {1'b0,base_sector}+sector_span>{1'b0,MAX_SECTOR}+33'd1);
    reg header_bad_q;
    // The last metadata byte is offset 33; HCHECK is entered only after
    // a complete 512-byte header sector. This register is therefore settled
    // hundreds of cycles before use and preserves the original handshake.
    // Separate wide arithmetic/validation from the FSM and RAM enables.
    always @(posedge clk or posedge rst) begin
        if(rst) header_bad_q<=1'b1;
        else header_bad_q<=header_bad;
    end
    reg [8:0] skip_bytes;
    reg [12:0] bytes_left;
    reg [1:0] channel;
    reg [7:0] blue,green;
    reg [15:0] fill_x;
    reg [1:0] gap;
    reg [31:0] idle_count;
    reg operation_open;
    wire reading=(state==HREAD || state==RREAD);
    wire row_byte=(state==RREAD && sd_sec_read_data_valid &&
                   byte_count>=skip_bytes && bytes_left!=0);
    always @(posedge clk) begin
        if(row_byte && channel==2) row_ram[fill_x[ROW_ADDR_BITS-1:0]]<={sd_sec_read_data,green,blue};
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;open_done<=0;row_done<=0;meta_valid<=0;error_code<=0;
            src_width<=0;src_height<=0;row_stride<=0;top_down<=0;
            pixel_offset<=0;file_bytes<=0;file_sectors<=0;
            pixel_x<=0;pixel_y<=0;sd_sec_read<=0;sd_sec_read_addr<=0;
            base_sector<=0;byte_count<=0;sig0<=0;sig1<=0;hsize<=0;
            hlen<=0;hoff<=0;hw<=0;hh<=0;hcomp<=0;hplanes<=0;hbits<=0;
            accum<=0;multiplicand<=0;multiplier<=0;calc_left<=0;
            skip_bytes<=0;bytes_left<=0;channel<=0;blue<=0;green<=0;fill_x<=0;
            gap<=0;idle_count<=0;operation_open<=0;
        end else begin
            open_done<=0;row_done<=0;
            if(!reading || sd_sec_read_data_valid || sd_sec_read_end) idle_count<=0;
            else idle_count<=idle_count+1'b1;
            if(reading && sd_sec_read_data_valid) byte_count<=byte_count+1'b1;
            if(state==HREAD && sd_sec_read_data_valid) begin
                case(byte_count)
                    0:sig0<=sd_sec_read_data;1:sig1<=sd_sec_read_data;
                    2:hlen[7:0]<=sd_sec_read_data;3:hlen[15:8]<=sd_sec_read_data;
                    4:hlen[23:16]<=sd_sec_read_data;5:hlen[31:24]<=sd_sec_read_data;
                    10:hoff[7:0]<=sd_sec_read_data;11:hoff[15:8]<=sd_sec_read_data;
                    12:hoff[23:16]<=sd_sec_read_data;13:hoff[31:24]<=sd_sec_read_data;
                    14:hsize[7:0]<=sd_sec_read_data;15:hsize[15:8]<=sd_sec_read_data;
                    16:hsize[23:16]<=sd_sec_read_data;17:hsize[31:24]<=sd_sec_read_data;
                    18:hw[7:0]<=sd_sec_read_data;19:hw[15:8]<=sd_sec_read_data;
                    20:hw[23:16]<=sd_sec_read_data;21:hw[31:24]<=sd_sec_read_data;
                    22:hh[7:0]<=sd_sec_read_data;23:hh[15:8]<=sd_sec_read_data;
                    24:hh[23:16]<=sd_sec_read_data;25:hh[31:24]<=sd_sec_read_data;
                    26:hplanes[7:0]<=sd_sec_read_data;27:hplanes[15:8]<=sd_sec_read_data;
                    28:hbits[7:0]<=sd_sec_read_data;29:hbits[15:8]<=sd_sec_read_data;
                    30:hcomp[7:0]<=sd_sec_read_data;31:hcomp[15:8]<=sd_sec_read_data;
                    32:hcomp[23:16]<=sd_sec_read_data;33:hcomp[31:24]<=sd_sec_read_data;
                    default:;
                endcase
            end
            if(row_byte) begin
                bytes_left<=bytes_left-1'b1;
                if(channel==0) begin blue<=sd_sec_read_data;channel<=1;end
                else if(channel==1) begin green<=sd_sec_read_data;channel<=2;end
                else begin channel<=0;fill_x<=fill_x+1'b1;end
            end
            if(!sd_init_done) begin
                state<=IDLE;sd_sec_read<=0;meta_valid<=0;
            end else if((cancel && state!=DRAIN && state!=ABORT_GAP) || (reading && !sd_sec_read_data_valid && !sd_sec_read_end &&
                                   idle_count>=TIMEOUT_CYCLES-1)) begin
                error_code<=4;meta_valid<=0;sd_sec_read<=0;
                if(operation_open) open_done<=1;else row_done<=1;
                // No new request until the uncancellable physical sector ends.
                if(reading && !sd_sec_read_end) state<=DRAIN;else state<=IDLE;
            end else case(state)
                IDLE: begin
                    sd_sec_read<=0;
                    if(open_req) begin
                        meta_valid<=0;error_code<=0;operation_open<=1;
                        base_sector<=open_sector;sd_sec_read_addr<=open_sector;
                        byte_count<=0;
                        if(open_sector>MAX_SECTOR) begin error_code<=1;open_done<=1;end
                        else begin state<=HREAD;sd_sec_read<=1;end
                    end else if(row_req && meta_valid) begin
                        operation_open<=0;error_code<=0;
                        if(row_y>=src_height) begin error_code<=2;row_done<=1;end
                        else begin
                            pixel_y<=row_y;pixel_x<=0;
                            accum<=pixel_offset;multiplicand<=row_stride;
                            multiplier<=top_down ? row_y : src_height-1'b1-row_y;
                            calc_left<=16;state<=RCALC;
                        end
                    end
                end
                HREAD: if(sd_sec_read_end) begin
                    sd_sec_read<=0;
                    if(byte_count+(sd_sec_read_data_valid?1:0)!=512) begin
                        error_code<=3;open_done<=1;state<=IDLE;
                    end else state<=HCHECK;
                end
                HCHECK: begin
                    // Full-width signed dimension validation, not low-16-bit matches.
                    if(header_bad_q) begin
                        error_code<=1;open_done<=1;state<=IDLE;
                    end else begin
                        accum<=0;multiplicand<=stride_calc;multiplier<=abs_height[15:0];
                        calc_left<=16;state<=HSIZE;
                    end
                end
                HSIZE,RCALC: begin
                    if(calc_left!=0) begin
                        if(multiplier[0]) accum<=accum+multiplicand;
                        multiplier<=multiplier>>1;multiplicand<=multiplicand<<1;
                        calc_left<=calc_left-1'b1;
                    end else if(state==HSIZE) state<=HEND;else state<=RADDR;
                end
                HEND: begin
                    open_done<=1;state<=IDLE;
                    if(data_end>{1'b0,hlen}) error_code<=1;
                    else begin
                        src_width<=hw[15:0];src_height<=abs_height[15:0];
                        row_stride<=stride_calc[15:0];top_down<=hh[31];
                        pixel_offset<=hoff;file_bytes<=hlen;file_sectors<=sector_span[31:0];
                        meta_valid<=1;
                    end
                end
                RADDR: begin
                    sd_sec_read_addr<=base_sector+(accum>>9);skip_bytes<=accum[8:0];
                    bytes_left<=({1'b0,src_width[11:0]}<<1)+src_width[11:0];
                    byte_count<=0;fill_x<=0;channel<=0;state<=RREAD;sd_sec_read<=1;
                end
                RREAD: if(sd_sec_read_end) begin
                    sd_sec_read<=0;
                    if(byte_count+(sd_sec_read_data_valid?1:0)!=512) begin
                        error_code<=3;row_done<=1;state<=IDLE;
                    end else begin state<=RGAP;gap<=2;end
                end
                RGAP: if(gap!=0) gap<=gap-1'b1;
                else if(bytes_left==0) begin
                    if(fill_x!=src_width || channel!=0) begin error_code<=3;row_done<=1;state<=IDLE;end
                    else state<=PRIME;
                end else begin
                    sd_sec_read_addr<=sd_sec_read_addr+1'b1;skip_bytes<=0;byte_count<=0;
                    state<=RREAD;sd_sec_read<=1;
                end
                PRIME: state<=EMIT;
                EMIT: if(pixel_ready) begin
                    if(pixel_last) begin row_done<=1;state<=IDLE;end
                    else begin pixel_x<=pixel_x+1'b1;state<=PRIME;end
                end
                DRAIN: if(sd_sec_read_end) begin state<=ABORT_GAP;gap<=2;end
                ABORT_GAP: if(gap!=0) gap<=gap-1'b1;else state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
