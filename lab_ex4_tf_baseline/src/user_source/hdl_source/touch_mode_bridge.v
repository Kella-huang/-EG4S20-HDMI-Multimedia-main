`default_nettype none
// Persistent last-action-wins selection. Media resets must NOT clear this state.
module touch_mode_bridge #(
    parameter integer DEBOUNCE_CYCLES=1500000
)(input wire src_clk,src_rst,command_valid,
  input wire [3:0] command,
  input wire dst_clk,dst_rst,physical_video,
  output reg selected_video);
    reg request,payload;
    reg acknowledge;
    (* async_reg="true" *) reg [2:0] req_sync,ack_sync;
    (* async_reg="true" *) reg [1:0] sw_sync;
    reg candidate,physical_stable,physical_initialized;
    reg [20:0] debounce;
    always @(posedge src_clk or posedge src_rst) begin
        if(src_rst) begin request<=0;payload<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[1:0],acknowledge};
            if(command_valid && (command==1 || command==2) && request==ack_sync[2]) begin
                payload<=command==2;request<=!request;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_rst) begin
        if(dst_rst) begin
            req_sync<=0;acknowledge<=0;sw_sync<=0;candidate<=0;
            physical_stable<=0;physical_initialized<=0;debounce<=0;selected_video<=0;
        end else begin
            req_sync<={req_sync[1:0],request};sw_sync<={sw_sync[0],physical_video};
            // Payload remains stable from before the synchronized request
            // until the returned acknowledge crosses back to src_clk.
            if(req_sync[2]!=acknowledge) begin selected_video<=payload;acknowledge<=req_sync[2];end
            if(sw_sync[1]!=candidate) begin candidate<=sw_sync[1];debounce<=0;end
            else if(debounce<DEBOUNCE_CYCLES) debounce<=debounce+1'b1;
            else if(!physical_initialized || physical_stable!=candidate) begin
                physical_initialized<=1;physical_stable<=candidate;selected_video<=candidate;
            end
        end
    end
endmodule
`default_nettype wire
