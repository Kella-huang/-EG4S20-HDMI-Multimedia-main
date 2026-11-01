`default_nettype none
// One pipeline stage; all timing signals accompany the scaled RGB.
// OSD is applied AFTER this stage so text remains bright and keeps scrolling.
module video_fade_rgb(
    input wire clk, rst,
    input wire hs, vs, de,
    input wire [23:0] rgb,
    input wire [8:0] brightness,
    output reg hs_out, vs_out, de_out,
    output wire [23:0] rgb_out
);
    reg [16:0] product_r, product_g, product_b;
    assign rgb_out={product_r[15:8],product_g[15:8],product_b[15:8]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            hs_out<=0; vs_out<=0; de_out<=0;
            product_r<=0; product_g<=0; product_b<=0;
        end else begin
            hs_out<=hs; vs_out<=vs; de_out<=de;
            product_r<=de ? rgb[23:16]*brightness : 17'd0;
            product_g<=de ? rgb[15:8]*brightness : 17'd0;
            product_b<=de ? rgb[7:0]*brightness : 17'd0;
        end
    end
endmodule
`default_nettype wire
