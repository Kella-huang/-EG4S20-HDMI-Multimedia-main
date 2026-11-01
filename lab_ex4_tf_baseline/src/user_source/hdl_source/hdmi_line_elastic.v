`default_nettype none
// APUG092: ready may go low AFTER TLAST; each admitted line is continuous.
// Absorb the small line-start phase correction without discarding pixels or
// stopping the raster/SDRAM/UI clocks. Use LUT RAM; all 64 BRAMs are occupied.
module hdmi_line_elastic #(
    parameter integer ADDR_BITS=6,
    parameter integer RESET_CLOCKS=16
)(
    input wire clk,rst,
    input wire in_valid,in_user,in_last,
    input wire [23:0] in_data,
    input wire receiver_ready,
    output wire out_valid,out_user,out_last,
    output wire [23:0] out_data,
    output wire recover_reset,
    output reg fault_seen
);
    localparam DEPTH=1<<ADDR_BITS;
    (* ram_style="dram" *) reg [25:0] pixels[0:DEPTH-1];
    // Wrap bits distinguish full/empty without an up/down occupancy counter.
    reg [ADDR_BITS:0] wr_ptr,rd_ptr;
    wire [ADDR_BITS:0] count=wr_ptr-rd_ptr; // simulation diagnostic only
    wire empty=(wr_ptr==rd_ptr);
    wire full=(wr_ptr=={~rd_ptr[ADDR_BITS],rd_ptr[ADDR_BITS-1:0]});
    reg line_active,dropping;
    reg [4:0] reset_count;
    wire [25:0] head=pixels[rd_ptr[ADDR_BITS-1:0]];
    assign recover_reset=(reset_count!=0);
    // Fault/reset keeps both pointers equal until the next frame is admitted.
    assign out_valid=!empty && (line_active || receiver_ready);
    assign out_user=out_valid && head[25];
    assign out_last=out_valid && head[24];
    // Receiver samples RGB only on valid/ready. Avoid a redundant 24-bit mux.
    assign out_data=head[23:0];
    wire pop=out_valid && receiver_ready;
    wire input_overflow=in_valid && !dropping && full && !pop;
    wire broken_line=line_active && (!receiver_ready || empty);
    wire fault=!recover_reset && !dropping && (input_overflow || broken_line);
    wire restart=dropping && !recover_reset && in_valid && in_user;
    wire push=in_valid && !recover_reset && !fault && (!dropping || restart);
    // RAM contents need no reset; count and pointers define validity.
    // Fault already clears wr_ptr; it remains zero throughout frame dropping.
    always @(posedge clk) if(push) pixels[wr_ptr[ADDR_BITS-1:0]]<={in_user,in_last,in_data};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            wr_ptr<=0;rd_ptr<=0;line_active<=0;dropping<=0;reset_count<=0;fault_seen<=0;
        end else if(fault) begin
            wr_ptr<=0;rd_ptr<=0;line_active<=0;dropping<=1;
            reset_count<=RESET_CLOCKS;fault_seen<=1;
        end else if(recover_reset) begin
            reset_count<=reset_count-1'b1;
        end else begin
            if(restart) dropping<=0;
            if(push) wr_ptr<=wr_ptr+1'b1;
            if(pop) begin rd_ptr<=rd_ptr+1'b1;line_active<=!head[24];end
        end
    end
endmodule
`default_nettype wire
