`default_nettype none
// Shared by the real top and integration test: adjustment -> original OSD ->
// parameter menu. The first three stages adjust only the background picture.
module video_display_controls #(
    parameter integer FAST_NEXT=0,
    parameter integer ENABLE_TOUCH=0,
    parameter integer ENABLE_RESOLUTION=0,
    parameter integer SEPARATE_CONTROL_RESET=0,
    parameter integer ANIMATE_MENU=1,
    parameter integer CLK_HZ=25_000_000,DEBOUNCE_MS=30,LONG_MS=1000
)(
    input wire clk,rst,diagnostic_mode,key1,key2,uart_rx,
    input wire hs,vs,de,picture_valid,
    input wire [23:0] rgb_in,
    output wire next_toggle,auto_toggle,
    output wire hs_out,vs_out,de_out,
    output wire [23:0] rgb_out,
    input wire resolution_enable,resolution_valid,
    input wire [31:0] resolution_bcd,
    input wire control_reset,
    input wire touch_valid,
    input wire [3:0] touch_command,
    output wire touch_menu,
    output wire signed [8:0] touch_brightness,
    output wire [8:0] touch_contrast,
    output wire control_reset_request
);
    wire state_reset=rst || (SEPARATE_CONTROL_RESET ? control_reset : 1'b0);
    wire pending_menu,pending_selected,menu_open,selected_contrast;
    wire signed [8:0] pending_brightness,brightness;
    wire [8:0] pending_contrast,contrast_q8;
    assign touch_menu=menu_open;
    assign touch_brightness=brightness;
    assign touch_contrast=contrast_q8;
    display_param_control #(.FAST_NEXT(FAST_NEXT),.ENABLE_TOUCH(ENABLE_TOUCH),.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.LONG_MS(LONG_MS)) control(
        .clk(clk),.rst(state_reset || diagnostic_mode),.key1(key1),.key2(key2),
        .touch_valid(touch_valid),.touch_command(touch_command),
        .menu_open(pending_menu),.selected_contrast(pending_selected),
        .brightness(pending_brightness),.contrast_q8(pending_contrast),
        .next_toggle(next_toggle),.auto_toggle(auto_toggle),
        .reset_request(control_reset_request));
    display_param_commit commit(
        .clk(clk),.rst(state_reset || diagnostic_mode),.vs(vs),.de(de),
        .pending_menu(pending_menu),.pending_selected(pending_selected),
        .pending_brightness(pending_brightness),.pending_contrast(pending_contrast),
        .menu_open(menu_open),.selected_contrast(selected_contrast),
        .brightness(brightness),.contrast_q8(contrast_q8));
    wire hs_adjust,vs_adjust,de_adjust;
    wire [23:0] rgb_adjust,rgb_text;
    wire [9:0] x,y;
    reg [2:0] valid_pipe;
    reg hs_text,vs_text,de_text;
    reg [9:0] x_text,y_text;
    video_picture_adjust adjust(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.picture_valid(picture_valid),
        .enable(1'b1),.brightness(brightness),.contrast_q8(contrast_q8),.rgb_in(rgb_in),
        .hs_out(hs_adjust),.vs_out(vs_adjust),.de_out(de_adjust),.rgb_out(rgb_adjust));
    video_osd_coord_640x480 coords(.video_clk(clk),.rst(rst),.vs(vs_adjust),.de(de_adjust),.x(x),.y(y));
    always @(posedge clk or posedge rst) begin
        if(rst) begin valid_pipe<=0;hs_text<=0;vs_text<=0;de_text<=0;x_text<=0;y_text<=0;end
        else begin
            valid_pipe<={valid_pipe[1:0],picture_valid};
            hs_text<=hs_adjust;vs_text<=vs_adjust;de_text<=de_adjust;
            x_text<=x;y_text<=y;
        end
    end
    // Keep the original timekeeper at its physical 25 MHz rate even when
    // gesture timing is accelerated by CLK_HZ in a simulation.
    osd_static_text_sdram #(.PIPELINED(1),.ENABLE_RESOLUTION(ENABLE_RESOLUTION)) text_osd(
        .video_clk(clk),.rst(rst),.uart_rx(uart_rx),.vs(vs_adjust),
        .x(x),.y(y),.de(de_adjust && valid_pipe[2]),.base_rgb(rgb_adjust),.out_rgb(rgb_text),
        .resolution_enable(resolution_enable),.resolution_valid(resolution_valid),.resolution_bcd(resolution_bcd));
    osd_display_params #(.ANIMATE_MENU(ANIMATE_MENU)) menu(
        .clk(clk),.rst(rst),.hs(hs_text),.vs(vs_text),.de(de_text),
        .x(x_text),.y(y_text),.base_rgb(rgb_text),
        .menu_open(menu_open),.selected_contrast(selected_contrast),
        .brightness(brightness),.contrast_q8(contrast_q8),
        .hs_out(hs_out),.vs_out(vs_out),.de_out(de_out),.rgb_out(rgb_out));
endmodule
`default_nettype wire
