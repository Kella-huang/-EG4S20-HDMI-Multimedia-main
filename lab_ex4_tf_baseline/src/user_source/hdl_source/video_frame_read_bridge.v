`default_nettype none
// Delay each frame read until active_buf has crossed to mem_clk.
// Fresh-ready qualification rejects stale ready from the previous frame.
module video_frame_read_bridge(
    input wire clk, rst,
    input wire timing_req,
    input wire mem_ack_async, mem_ready_async,
    output wire timing_ack,
    output wire frame_tick,
    output reg mem_req,
    output reg frame_prefetched
);
    (* async_reg = "true" *) reg ack_meta, ack_sync, ready_meta, ready_sync;
    reg timing_req_d, saw_ready_low, saw_ack;
    reg [1:0] request_delay;
    assign timing_ack=ack_sync;
    assign frame_tick=timing_req && !timing_req_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            ack_meta<=0; ack_sync<=0; ready_meta<=0; ready_sync<=0;
            timing_req_d<=0; request_delay<=0; mem_req<=0;
            saw_ready_low<=0; saw_ack<=0; frame_prefetched<=0;
        end else begin
            ack_meta<=mem_ack_async; ack_sync<=ack_meta;
            ready_meta<=mem_ready_async; ready_sync<=ready_meta;
            timing_req_d<=timing_req;
            if(frame_tick) begin
                request_delay<=2;
                saw_ready_low<=0; saw_ack<=0; frame_prefetched<=0;
            end else begin
                if(request_delay!=0) begin
                    request_delay<=request_delay-1'b1;
                    if(request_delay==1) mem_req<=1;
                end
                if(mem_req && ack_sync) begin mem_req<=0; saw_ack<=1; end
                if(mem_req && !ready_sync) saw_ready_low<=1;
                if(saw_ack && saw_ready_low && ready_sync) frame_prefetched<=1;
            end
        end
    end
endmodule
`default_nettype wire
