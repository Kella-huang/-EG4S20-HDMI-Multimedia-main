`default_nettype none
// Same TWO registered stages as video_crossfade_rgb. Cube's horizontally
// projected faces arrive in stream A; blinds use aligned original A/B pairs.
// The descriptor is stable throughout a frame, including exact 0/256 endpoints.
module video_image_transition(
    input wire clk,rst,hs,vs,de,
    input wire [23:0] rgb_old,rgb_new,
    input wire [8:0] alpha,
    input wire [1:0] effect_kind,
    output reg hs_out,vs_out,de_out,
    output reg [23:0] rgb_out
);
    wire [9:0] x,y;
    video_osd_coord_640x480 coords(.video_clk(clk),.rst(rst),.vs(vs),.de(de),.x(x),.y(y));
    wire [11:0] alpha5=({3'b0,alpha}<<2)+{3'b0,alpha};
    wire [9:0] new_width=alpha5[10:1];
    wire [9:0] old_width=10'd640-new_width;
    wire new_face=x>=old_width;
    wire [9:0] seam_distance=new_face ? x-old_width : old_width-x;
    // Two planar projected faces meet on a full-height seam. Outer edges
    // recede as the cube rotates; both masks collapse exactly at endpoints.
    wire [19:0] perspective=seam_distance*(new_face ? old_width : new_width);
    wire [9:0] inset=perspective[19:10];
    wire cube_clip=(y<inset || y>=10'd480-inset);
    wire [8:0] cube_gain=new_face ? 9'd192+{2'b0,alpha[8:2]} :
        9'd256-{2'b0,alpha[8:2]};
    // Fifteen horizontal 32-pixel leaves. No modulo/divider, no leftover
    // seam at alpha=256, and progress never changes halfway through a line.
    wire [5:0] opening=alpha[8:3];
    wire [8:0] mix_alpha=(effect_kind==3) ?
        ({1'b0,y[4:0]}<opening ? 9'd256 : 9'd0) :
        (effect_kind==0) ? alpha : 9'd0;
    wire [8:0] old_gain=(effect_kind==2) ? cube_gain : 9'd256-mix_alpha;
    reg hs1,vs1,de1,clip1;
    reg [16:0] old_r,old_g,old_b,new_r,new_g,new_b;
    wire [17:0] sum_r={1'b0,old_r}+{1'b0,new_r};
    wire [17:0] sum_g={1'b0,old_g}+{1'b0,new_g};
    wire [17:0] sum_b={1'b0,old_b}+{1'b0,new_b};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            hs1<=0;vs1<=0;de1<=0;clip1<=0;
            hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;
            old_r<=0;old_g<=0;old_b<=0;new_r<=0;new_g<=0;new_b<=0;
        end else begin
            hs1<=hs;vs1<=vs;de1<=de;clip1<=(effect_kind==2 && cube_clip);
            old_r<=rgb_old[23:16]*old_gain;new_r<=rgb_new[23:16]*mix_alpha;
            old_g<=rgb_old[15:8]*old_gain;new_g<=rgb_new[15:8]*mix_alpha;
            old_b<=rgb_old[7:0]*old_gain;new_b<=rgb_new[7:0]*mix_alpha;
            hs_out<=hs1;vs_out<=vs1;de_out<=de1;
            rgb_out<=(de1 && !clip1) ? {sum_r[15:8],sum_g[15:8],sum_b[15:8]} : 24'd0;
        end
    end
endmodule
`default_nettype wire
