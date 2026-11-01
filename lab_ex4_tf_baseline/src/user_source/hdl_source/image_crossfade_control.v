`default_nettype none
// Bundled-data ready/done handshake is compatible with sd_card_bmp.
// Keep both buffers reserved until a complete healthy SINGLE-new-image frame
// has run after the alpha=256 frame: no old read can overlap buffer recycling.
module image_crossfade_control #(
    parameter integer ALPHA_STEP=5,
    // 0: crossfade, 1: push left, 2: alternate, 3: fade/slide/cube/blinds cycle.
    parameter integer TRANSITION_MODE=0,
    parameter integer MAX_BAD_FRAMES=8,
    // Independent from crossfade: 2 alpha units = exactly 5 pixels/frame.
    parameter integer SLIDE_ALPHA_STEP=2,
    parameter integer BLINDS_ALPHA_STEP=4
)(
    input wire clk,rst,image_ready_async,
    input wire [1:0] ready_buf_async,
    input wire frame_tick,frame_prefetched,frame_underflow,
    output reg transition_done,
    output reg [1:0] active_buf,next_buf,
    output reg dual_enable,display_valid,fade_from_black,
    output reg [8:0] alpha,
    output wire transition_busy,
    output reg slide_enable,
    output wire [9:0] slide_offset,
    output reg [1:0] effect_kind,
    output wire cube_enable
);
    reg next_slide;
    reg [1:0] next_effect;
    wire [1:0] selected_effect=(TRANSITION_MODE==1) ? 2'd1 :
        (TRANSITION_MODE==2) ? {1'b0,next_slide} :
        (TRANSITION_MODE==3) ? next_effect : 2'd0;
    assign cube_enable=(effect_kind==2);
    wire [11:0] alpha_times_five=({3'b0,alpha}<<2)+{3'b0,alpha};
    // 640 * alpha / 256, exact 0 and 640 endpoints. Frame-stable descriptor.
    assign slide_offset=(slide_enable || cube_enable) ? alpha_times_five[10:1] : 10'd0;
    (* async_reg="true" *) reg ready_meta,ready_sync;
    reg [1:0] buf_meta,buf_sync;
    localparam IDLE=0,ARM=1,BLEND=2,ENDPOINT=3,COMMIT=4;
    reg [2:0] state;
    assign transition_busy=(state!=IDLE) || (ready_sync && !transition_done);
    wire healthy=frame_prefetched && !frame_underflow;
    wire [8:0] effect_step=(slide_enable || cube_enable) ? SLIDE_ALPHA_STEP :
        (effect_kind==3) ? BLINDS_ALPHA_STEP : ALPHA_STEP;
    localparam BAD_BITS=(MAX_BAD_FRAMES<2)?1:$clog2(MAX_BAD_FRAMES+1);
    reg [BAD_BITS-1:0] bad_frames;
    always @(posedge clk or posedge rst) begin
        if(rst) begin ready_meta<=0;ready_sync<=0;buf_meta<=0;buf_sync<=0;end
        else begin ready_meta<=image_ready_async;ready_sync<=ready_meta;
            buf_meta<=ready_buf_async;buf_sync<=buf_meta;end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;transition_done<=0;active_buf<=0;next_buf<=0;
            dual_enable<=0;display_valid<=0;fade_from_black<=0;alpha<=0;
            slide_enable<=0;next_slide<=0;
            effect_kind<=0;next_effect<=0;
            bad_frames<=0;
        end else begin
            if(!ready_sync) transition_done<=0;
            if(frame_tick) begin
                if(state==IDLE || state==COMMIT || healthy) bad_frames<=0;
                else if(bad_frames<MAX_BAD_FRAMES) bad_frames<=bad_frames+1'b1;
                // Persistent starvation must not keep both buffers owned
                // forever. Drop the effect at VS, then wait for a healthy
                // SINGLE-new frame before allowing the writer to recycle old.
                if(state!=IDLE && state!=COMMIT && !healthy &&
                   bad_frames>=MAX_BAD_FRAMES-1) begin
                    active_buf<=next_buf;dual_enable<=0;slide_enable<=0;
                    effect_kind<=0;
                    fade_from_black<=0;alpha<=0;display_valid<=1;
                    state<=COMMIT;bad_frames<=0;
                end else case(state)
                IDLE: if(ready_sync && !transition_done) begin
                    next_buf<=buf_sync;alpha<=0;state<=ARM;
                    if(!display_valid) begin
                        active_buf<=buf_sync;dual_enable<=0;fade_from_black<=1;slide_enable<=0;
                        effect_kind<=0;
                    end else begin
                        effect_kind<=selected_effect;
                        slide_enable<=(selected_effect==1);
                        dual_enable<=(selected_effect==0 || selected_effect==3);
                        fade_from_black<=0;
                        if(TRANSITION_MODE==2) next_slide<=!next_slide;
                        if(TRANSITION_MODE==3) next_effect<=next_effect+1'b1;
                    end
                end
                ARM: if(healthy) begin display_valid<=1;alpha<=effect_step;state<=BLEND;end
                BLEND: if(healthy) begin
                    if(alpha>=256-effect_step) begin alpha<=256;state<=ENDPOINT;end
                    else alpha<=alpha+effect_step;
                end
                ENDPOINT: if(healthy) begin
                    active_buf<=next_buf;dual_enable<=0;fade_from_black<=0;alpha<=0;slide_enable<=0;
                    effect_kind<=0;
                    state<=COMMIT;
                end
                COMMIT: if(healthy) begin transition_done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
            end
        end
    end
endmodule
`default_nettype wire
