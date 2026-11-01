`default_nettype none
// New controls only: C8 video select, C7 test tone, B1 pause.
// Existing B2/C1 image/menu buttons and A2 reset retain their functions.
module av_mode_control #(
    parameter integer DEBOUNCE_CYCLES=1_500_000,
    parameter integer RESET_CYCLES=100_000
)(input wire clk,power_reset,sw_video,sw_tone,manual_reset,
  output reg [1:0] mode,output reg media_reset);
    (* async_reg="true" *) reg [1:0] meta,sync;
    reg [1:0] candidate;
    reg [31:0] stable_count,reset_count;
    wire [1:0] wanted=sync[1] ? 2'd2 : (sync[0] ? 2'd1 : 2'd0);
    always @(posedge clk or posedge power_reset) begin
        if(power_reset) begin
            meta<=0;sync<=0;candidate<=0;mode<=0;stable_count<=0;reset_count<=RESET_CYCLES;media_reset<=1;
        end else begin
            meta<={sw_tone,sw_video};sync<=meta;
            if(reset_count!=0) begin
                reset_count<=reset_count-1'b1;
                if(reset_count==1) media_reset<=0;
            end
            if(wanted!=candidate) begin candidate<=wanted;stable_count<=0;end
            else if(stable_count<DEBOUNCE_CYCLES) stable_count<=stable_count+1'b1;
            else if(mode!=candidate) begin mode<=candidate;reset_count<=RESET_CYCLES;media_reset<=1;end
            // A touch RESET reuses the very same pulse width as a mode change,
            // so the shared media chain restarts without any extra counter.
            if(manual_reset) begin reset_count<=RESET_CYCLES;media_reset<=1;end
        end
    end
endmodule

// Configuration initializes reset high. Require 20 ms of stable PLL locks
// before releasing. Keep reset released afterwards, as in the board-tested
// baseline: a lock-pin disturbance must not repeatedly clear media caches.
module display_power_reset #(
    parameter integer STABLE_CYCLES=1_000_000,
    parameter integer LOSS_CYCLES=16,
    parameter integer RESET_ON_LOCK_LOSS=0
)(input wire clk,reset_n,sys_locked,video_locked,
  output reg reset_out=1'b1);
    (* async_reg="true" *) reg [1:0] lock_meta=0,lock_sync=0;
    reg [19:0] stable_count=0;
    reg [4:0] loss_count=0;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            lock_meta<=0;lock_sync<=0;stable_count<=0;loss_count<=0;reset_out<=1;
        end else begin
            lock_meta<={sys_locked,video_locked};lock_sync<=lock_meta;
            if(reset_out) begin
                loss_count<=0;
                if(&lock_sync) begin
                    if(stable_count==STABLE_CYCLES-1) begin reset_out<=0;stable_count<=0;end
                    else stable_count<=stable_count+1'b1;
                end else stable_count<=0;
            end else if(RESET_ON_LOCK_LOSS) begin
                stable_count<=0;
                if(&lock_sync) loss_count<=0;
                else if(loss_count==LOSS_CYCLES-1) begin reset_out<=1;loss_count<=0;end
                else loss_count<=loss_count+1'b1;
            end else begin stable_count<=0;loss_count<=0;reset_out<=0;end
        end
    end
endmodule

module av_reset_sync(input wire clk,async_reset,output wire reset_out);
    (* async_reg="true" *) reg [1:0] stages;
    always @(posedge clk or posedge async_reset)
        if(async_reset) stages<=2'b11;else stages<={stages[0],1'b0};
    assign reset_out=stages[1];
endmodule
`default_nettype wire
