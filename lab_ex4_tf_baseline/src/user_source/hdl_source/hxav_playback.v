`default_nettype none
// Dual-clock PCM RAM. No reset loop: maps to FPGA block memory.
// The external address keeps the bank bit at bit 12. Packing the valid
// samples contiguously avoids paying for unused padding between banks.
// Default 4096 preserves the complete original address space for other users.
module hxav_pcm_banks #(parameter integer SAMPLES_PER_BANK=4096)(
    input wire wr_clk,wr_en,input wire [12:0] wr_addr,input wire [31:0] wr_data,
    input wire rd_clk,input wire [12:0] rd_addr,output reg [31:0] rd_data
);
    localparam [12:0] BANK_STRIDE=SAMPLES_PER_BANK;
    wire [12:0] packed_wr={1'b0,wr_addr[11:0]}+(wr_addr[12]?BANK_STRIDE:13'd0);
    wire [12:0] packed_rd={1'b0,rd_addr[11:0]}+(rd_addr[12]?BANK_STRIDE:13'd0);
    reg [31:0] memory[0:SAMPLES_PER_BANK*2-1];
    always @(posedge wr_clk) if(wr_en) memory[packed_wr]<=wr_data;
    always @(posedge rd_clk) rd_data<=memory[packed_rd];
endmodule

module hxav_playback #(parameter integer SAMPLES_PER_FRAME=3200, FRAME_COUNT=90,
                      PREBUFFER_FRAMES=1)(
    input wire clk,rst,sample_tick,frame_tick,frame_prefetched,frame_underflow,
    input wire pause_event,
    input wire [1:0] filled_toggle_async,
    input wire source_error_async,
    output reg [1:0] released_toggle,
    output reg [1:0] audio_released_toggle,
    output reg read_bank,display_valid,
    output wire [12:0] audio_addr,
    input wire [31:0] audio_data,
    output wire [23:0] pcm_left,pcm_right,
    output wire pcm_active,
    output reg paused,
    output reg [6:0] playing_frame,
    output reg [15:0] stall_count,
    output reg display_fault
);
    (* async_reg="true" *) reg [1:0] fill_meta,fill_sync;
    (* async_reg="true" *) reg error_meta,error_sync;
    reg started,audio_bank,waiting,prefetch_wait,saw_low,safe_frame;
    reg [11:0] sample_index;
    reg [1:0] audio_done;
    reg [1:0] audio_prime;
    wire [1:0] available=fill_sync^released_toggle;
    wire run_audio=started && !paused && !waiting && !error_sync && !display_fault && audio_prime==0;
    assign pcm_active=run_audio;
    assign audio_addr={audio_bank,sample_index};
    assign pcm_left=run_audio ? {audio_data[15:0],8'd0} : 24'd0;
    assign pcm_right=run_audio ? {audio_data[31:16],8'd0} : 24'd0;
    always @(posedge clk or posedge rst) begin
        if(rst) begin fill_meta<=0;fill_sync<=0;error_meta<=0;error_sync<=0;end
        else begin fill_meta<=filled_toggle_async;fill_sync<=fill_meta;
            error_meta<=source_error_async;error_sync<=error_meta;end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            released_toggle<=0;audio_released_toggle<=0;read_bank<=0;display_valid<=0;paused<=0;
            playing_frame<=0;stall_count<=0;display_fault<=0;
            started<=0;audio_bank<=0;waiting<=0;prefetch_wait<=0;saw_low<=0;
            safe_frame<=0;sample_index<=0;audio_done<=0;audio_prime<=0;
        end else begin
            // A bank switch may coincide with a sample tick after a card stall.
            // Allow the synchronous PCM RAM to present the new bank's sample 0.
            if(audio_prime!=0) audio_prime<=audio_prime-1'b1;
            if(pause_event) paused<=~paused;
            if(display_valid && started && frame_underflow) display_fault<=1;
            if(frame_tick) begin
                // Only the video frame boundary may change the SDRAM descriptor.
                if(!display_valid && available[0] && !error_sync) begin
                    display_valid<=1;read_bank<=0;prefetch_wait<=1;saw_low<=0;safe_frame<=0;
                end else if(started && read_bank!=audio_bank) begin
                    read_bank<=audio_bank;prefetch_wait<=1;saw_low<=0;safe_frame<=0;
                end
            end
            if(prefetch_wait && !frame_tick) begin
                if(!frame_prefetched) saw_low<=1;
                if(saw_low && frame_prefetched && !frame_underflow) begin
                    prefetch_wait<=0;safe_frame<=1;
                end
            end
            // Reserve one complete look-ahead bank before starting the HD
            // soundtrack. Ownership and video frame switching are unchanged.
            if(!started && safe_frame && available[0] &&
               (PREBUFFER_FRAMES<2 || available[1]) && !error_sync && !display_fault)
                started<=1;
            // Return ownership only after both the last audio sample and the
            // old SDRAM read have finished; fresh prefetch proves the latter.
            if(safe_frame && !frame_tick && !prefetch_wait) begin
                if(audio_done[0] && read_bank!=0) begin released_toggle[0]<=fill_sync[0];audio_done[0]<=0;end
                if(audio_done[1] && read_bank!=1) begin released_toggle[1]<=fill_sync[1];audio_done[1]<=0;end
            end
            if(waiting && available[!audio_bank] && !audio_done[!audio_bank] && !paused && !error_sync && !display_fault) begin
                audio_bank<=!audio_bank;waiting<=0;audio_prime<=2;
                playing_frame<=playing_frame==FRAME_COUNT-1 ? 0 : playing_frame+1'b1;
            end
            if(sample_tick && run_audio) begin
                if(sample_index==SAMPLES_PER_FRAME-1) begin
                    // PCM ownership can return immediately; video ownership
                    // still waits for the next frame's completed prefetch.
                    audio_released_toggle[audio_bank]<=fill_sync[audio_bank];
                    sample_index<=0;audio_done[audio_bank]<=1;
                    if(available[!audio_bank] && !audio_done[!audio_bank]) begin
                        audio_bank<=!audio_bank;audio_prime<=2;
                        playing_frame<=playing_frame==FRAME_COUNT-1 ? 0 : playing_frame+1'b1;
                    end else begin
                        waiting<=1;
                        if(stall_count!=16'hffff) stall_count<=stall_count+1'b1;
                    end
                end else sample_index<=sample_index+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
