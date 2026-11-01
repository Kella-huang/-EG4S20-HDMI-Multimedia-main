`default_nettype none
// Two-stage RGB crossfade. 9-bit alpha represents BOTH exact endpoints 0/256.
// Weighted sum is widened before shifting; same-color white remains white.
module video_crossfade_rgb(
    input wire clk,rst,hs,vs,de,
    input wire [23:0] rgb_old,rgb_new,
    input wire [8:0] alpha,
    output reg hs_out,vs_out,de_out,
    output reg [23:0] rgb_out
);
    wire [8:0] inverse_alpha=9'd256-alpha;
    reg hs1,vs1,de1;
    reg [16:0] old_r,old_g,old_b,new_r,new_g,new_b;
    wire [17:0] sum_r={1'b0,old_r}+{1'b0,new_r};
    wire [17:0] sum_g={1'b0,old_g}+{1'b0,new_g};
    wire [17:0] sum_b={1'b0,old_b}+{1'b0,new_b};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            hs1<=0;vs1<=0;de1<=0;hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;
            old_r<=0;old_g<=0;old_b<=0;new_r<=0;new_g<=0;new_b<=0;
        end else begin
            hs1<=hs;vs1<=vs;de1<=de;
            old_r<=rgb_old[23:16]*inverse_alpha;new_r<=rgb_new[23:16]*alpha;
            old_g<=rgb_old[15:8]*inverse_alpha;new_g<=rgb_new[15:8]*alpha;
            old_b<=rgb_old[7:0]*inverse_alpha;new_b<=rgb_new[7:0]*alpha;
            hs_out<=hs1;vs_out<=vs1;de_out<=de1;
            rgb_out<=de1 ? {sum_r[15:8],sum_g[15:8],sum_b[15:8]} : 24'd0;
        end
    end
endmodule
`default_nettype wire
