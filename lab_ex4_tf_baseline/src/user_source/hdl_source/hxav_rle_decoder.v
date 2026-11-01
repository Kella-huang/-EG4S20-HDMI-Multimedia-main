`default_nettype none
// HXAV0002 row/run/literal decoder. Exact RGB565 pixels, no spatial scaling.
// The one-row history is overwritten only when the output FIFO accepts a pixel.
module hxav_rle_decoder(
    input wire clk,rst,input wire [7:0] byte_data,input wire byte_valid,
    output wire byte_ready,output wire pixel_valid,input wire pixel_ready,
    output wire [15:0] pixel_data,output wire done,output reg error
);
    localparam TOKEN_LO=0,TOKEN_HI=1,PIXEL_LO=2,PIXEL_HI=3,EMIT=4,DONE=5;
    reg [2:0] state;
    reg [7:0] low_byte;
    reg [1:0] mode;
    reg [14:0] remaining;
    reg [15:0] color;
    reg [9:0] column;
    reg [18:0] pixels;
    // 512 pixels fit exactly in one 9K block; the 128-pixel asynchronous
    // tail stays in logic. Read the next head column on an accepted pixel
    // so the registered RAM output has no external protocol latency.
    reg [15:0] previous_head[0:511];
    reg [15:0] previous_tail[0:127];
    reg [15:0] previous_head_q;
    wire [9:0] next_column=column==639 ? 10'd0 : column+10'd1;
    wire [9:0] history_read_column=(pixel_valid && pixel_ready)?next_column:column;
    wire [15:0] token={byte_data,low_byte};
    wire [14:0] token_count={1'b0,token[13:0]}+15'd1;
    assign byte_ready=state!=EMIT && !error;
    assign pixel_valid=state==EMIT && !error;
    assign pixel_data=mode==1 ? (column[9]?previous_tail[column[6:0]]:previous_head_q) : color;
    assign done=state==DONE && !error;
    always @(posedge clk) begin
        previous_head_q<=previous_head[history_read_column[8:0]];
        if(pixel_valid && pixel_ready) begin
            if(column[9]) previous_tail[column[6:0]]<=pixel_data;
            else previous_head[column[8:0]]<=pixel_data;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin state<=TOKEN_LO;low_byte<=0;mode<=0;remaining<=0;color<=0;column<=0;pixels<=0;error<=0;end
        else if(!error) begin
            if(byte_valid && byte_ready) case(state)
                TOKEN_LO:begin low_byte<=byte_data;state<=TOKEN_HI;end
                TOKEN_HI:begin
                    mode<=token[15:14];remaining<=token_count;
                    if(token[15:14]==3 || pixels+{4'd0,token_count}>19'd307200 ||
                       (token[15:14]==1 && pixels<640)) error<=1;
                    else state<=token[15:14]==1 ? EMIT : PIXEL_LO;
                end
                PIXEL_LO:begin low_byte<=byte_data;state<=PIXEL_HI;end
                PIXEL_HI:begin color<={byte_data,low_byte};state<=EMIT;end
                DONE:if(byte_data!=0) error<=1;
                default:error<=1;
            endcase
            if(pixel_valid && pixel_ready) begin
                pixels<=pixels+1'b1;column<=column==639 ? 0 : column+1'b1;
                remaining<=remaining-1'b1;
                if(pixels==307199) begin
                    if(remaining!=1) error<=1;
                    else state<=DONE;
                end else if(remaining==1) state<=TOKEN_LO;
                else if(mode==0) state<=PIXEL_LO;
            end
        end
    end
endmodule
`default_nettype wire
