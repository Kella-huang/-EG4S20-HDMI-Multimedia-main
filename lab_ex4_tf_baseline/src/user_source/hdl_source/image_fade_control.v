`default_nettype none
// Video-domain controller. Buffer ownership is held until fade-in completes.
// ready_buf remains stable for the entire four-phase ready/done handshake.
module image_fade_control #(
    parameter integer FADE_STEP = 11 // ceil(256/11)=24 frames per direction
)(
    input wire clk, rst,
    input wire image_ready_async,
    input wire [1:0] ready_buf_async,
    input wire frame_tick,
    input wire frame_prefetched,
    output reg transition_done,
    output reg [1:0] active_buf,
    output reg display_valid,
    output reg [8:0] brightness,
    output wire transition_busy
);
    (* async_reg = "true" *) reg ready_meta, ready_sync;
    reg [1:0] buf_meta, buf_sync, target_buf;
    localparam IDLE=2'd0, FADE_OUT=2'd1, BLACK_WAIT=2'd2, FADE_IN=2'd3;
    reg [1:0] state;
    assign transition_busy = (state != IDLE) || (ready_sync && !transition_done);
    always @(posedge clk or posedge rst) begin
        if(rst) begin ready_meta<=0; ready_sync<=0; buf_meta<=0; buf_sync<=0; end
        else begin
            ready_meta<=image_ready_async; ready_sync<=ready_meta;
            buf_meta<=ready_buf_async; buf_sync<=buf_meta;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE; target_buf<=0; active_buf<=0;
            transition_done<=0; display_valid<=0; brightness<=0;
        end else begin
            if(!ready_sync) transition_done<=0;
            // frame_tick precedes the SDRAM request; index is held for that frame.
            if(frame_tick) begin
                case(state)
                    IDLE: if(ready_sync && !transition_done) begin
                        target_buf<=buf_sync;
                        if(!display_valid) begin
                            active_buf<=buf_sync; brightness<=0; state<=BLACK_WAIT;
                        end else begin
                            brightness<=256-FADE_STEP; state<=FADE_OUT;
                        end
                    end
                    FADE_OUT: begin
                        if(brightness<=FADE_STEP) begin
                            brightness<=0; active_buf<=target_buf; state<=BLACK_WAIT;
                        end else brightness<=brightness-FADE_STEP;
                    end
                    BLACK_WAIT: begin
                        // This refers to the previous frame's fresh FIFO prefetch.
                        // It cannot be an ACK for the old buffer or an old ready level.
                        if(frame_prefetched) begin
                            display_valid<=1; brightness<=FADE_STEP; state<=FADE_IN;
                        end
                    end
                    FADE_IN: begin
                        if(brightness>=256-FADE_STEP) begin
                            brightness<=256; state<=IDLE; transition_done<=1;
                        end else brightness<=brightness+FADE_STEP;
                    end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
