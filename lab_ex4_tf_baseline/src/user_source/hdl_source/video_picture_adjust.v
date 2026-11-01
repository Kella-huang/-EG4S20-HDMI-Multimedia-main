`default_nettype none
// Streaming RGB888 picture adjustment, used by video_display_controls.
// Defaults supplied by the caller: enable=1, brightness=0, contrast_q8=256.
// Three register stages: inputs sampled at edge N appear after edge N+2.
// All inputs must be synchronous to clk. The caller must hold one parameter
// set for a whole frame (display_param_commit supplies that contract).
module video_picture_adjust(
    input wire clk,rst,
    input wire hs,vs,de,
    input wire picture_valid,
    input wire enable,
    input wire [23:0] rgb_in,
    input wire signed [8:0] brightness,
    input wire [8:0] contrast_q8,
    output reg hs_out,vs_out,de_out,
    output reg [23:0] rgb_out
);
    function signed [8:0] clamp_brightness;
        input signed [8:0] value;
        begin
            if(value < -9'sd64) clamp_brightness=-9'sd64;
            else if(value > 9'sd64) clamp_brightness=9'sd64;
            else clamp_brightness=value;
        end
    endfunction
    function [8:0] clamp_contrast;
        input [8:0] value;
        begin
            if(value < 9'd128) clamp_contrast=9'd128;
            else if(value > 9'd384) clamp_contrast=9'd384;
            else clamp_contrast=value;
        end
    endfunction
    // value includes +128 for nearest-integer rounding, half toward +infinity.
    // Saturate BEFORE selecting bits; negative/bright values must never wrap.
    function [7:0] saturate_rounded;
        input signed [19:0] value;
        begin
            if(value < 20'sd0) saturate_rounded=8'd0;
            else if(value >= 20'sd65536) saturate_rounded=8'd255;
            else saturate_rounded=value[15:8];
        end
    endfunction

    reg signed [8:0] r1,g1,b1,bias1;
    reg signed [9:0] contrast1;
    reg signed [18:0] r2,g2,b2,bias2;
    reg [23:0] bypass1,bypass2;
    reg hs1,vs1,de1,valid1,en1,hs2,vs2,de2,valid2,en2;
    wire signed [19:0] sum_r=$signed({r2[18],r2})+$signed({bias2[18],bias2})+20'sd128;
    wire signed [19:0] sum_g=$signed({g2[18],g2})+$signed({bias2[18],bias2})+20'sd128;
    wire signed [19:0] sum_b=$signed({b2[18],b2})+$signed({bias2[18],bias2})+20'sd128;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            r1<=0;g1<=0;b1<=0;bias1<=0;contrast1<=0;
            r2<=0;g2<=0;b2<=0;bias2<=0;
            bypass1<=0;bypass2<=0;
            hs1<=0;vs1<=0;de1<=0;valid1<=0;en1<=0;
            hs2<=0;vs2<=0;de2<=0;valid2<=0;en2<=0;
            hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;
        end else begin
            // Stage 1: signed centering and bounded parameters, captured
            // together with this pixel (never use live parameters downstream).
            r1<=$signed({1'b0,rgb_in[23:16]})-9'sd128;
            g1<=$signed({1'b0,rgb_in[15:8]})-9'sd128;
            b1<=$signed({1'b0,rgb_in[7:0]})-9'sd128;
            contrast1<=$signed({1'b0,clamp_contrast(contrast_q8)});
            bias1<=9'sd128+clamp_brightness(brightness);
            bypass1<=rgb_in;
            hs1<=hs;vs1<=vs;de1<=de;valid1<=picture_valid;en1<=enable;
            // Stage 2: three signed multiplies. Bias is nonnegative (64..192).
            r2<=r1*contrast1;g2<=g1*contrast1;b2<=b1*contrast1;
            bias2<=$signed({2'b00,bias1,8'b0});
            bypass2<=bypass1;
            hs2<=hs1;vs2<=vs1;de2<=de1;valid2<=valid1;en2<=en1;
            // Stage 3: add, round once, saturate. Blanking/no-picture black
            // has priority over bypass; timing remains intact in both cases.
            hs_out<=hs2;vs_out<=vs2;de_out<=de2;
            if(!de2 || !valid2) rgb_out<=24'd0;
            else if(!en2) rgb_out<=bypass2;
            else rgb_out<={saturate_rounded(sum_r),saturate_rounded(sum_g),saturate_rounded(sum_b)};
        end
    end
endmodule
`default_nettype wire
