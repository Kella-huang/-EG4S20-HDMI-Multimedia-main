`default_nettype none
// Pending and applied settings are in the SAME video-clock domain.
// Commit the whole bundle once at VS rising in vertical blanking.
module display_param_commit(
    input wire clk,rst,vs,de,
    input wire pending_menu,pending_selected,
    input wire signed [8:0] pending_brightness,
    input wire [8:0] pending_contrast,
    output reg menu_open,selected_contrast,
    output reg signed [8:0] brightness,
    output reg [8:0] contrast_q8
);
    reg vs_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            vs_d<=0;menu_open<=0;selected_contrast<=0;brightness<=0;contrast_q8<=256;
        end else begin
            vs_d<=vs;
            if(vs && !vs_d && !de) begin
                menu_open<=pending_menu;selected_contrast<=pending_selected;
                brightness<=pending_brightness;contrast_q8<=pending_contrast;
            end
        end
    end
endmodule
`default_nettype wire
