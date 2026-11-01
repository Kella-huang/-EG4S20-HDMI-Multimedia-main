`default_nettype none

// PC-synchronized SimHei timestamp and mixed Times/STXingkai subtitle, 640x480.
// Keep this module name for compatibility with the existing TD project.
module osd_static_text_sdram #(
    parameter integer PIPELINED = 0, // 1 registers font addresses and matching base RGB
    parameter integer ENABLE_RESOLUTION = 0,
    parameter integer CLK_HZ = 25_000_000,
    parameter integer UART_BAUD = 115200
) (
    input wire video_clk,
    input wire rst,
    input wire vs,
    input wire uart_rx,
    input wire [9:0] x,
    input wire [9:0] y,
    input wire de,
    input wire [23:0] base_rgb,
    output reg [23:0] out_rgb,
    input wire resolution_enable,resolution_valid,
    input wire [31:0] resolution_bcd
);
    // Larger native 16x24 cells leave space between readable SimHei glyphs.
    localparam integer TIME_PANEL_X0 = 400, TIME_PANEL_X1 = 624;
    localparam integer TIME_PANEL_Y0 = 10,  TIME_PANEL_Y1 = 46;
    localparam integer TIME_TEXT_X = 408, LINE0_Y = 16;
    localparam integer RES_PANEL_Y0 = 50, RES_PANEL_Y1 = 86, RES_TEXT_Y = 56;
    localparam integer SUB_PANEL_X0 = 72, SUB_PANEL_X1 = 568;
    localparam integer SUB_PANEL_Y0 = 432, SUB_PANEL_Y1 = 468;
    localparam integer SUB_TEXT_X0 = 80, SUB_TEXT_X1 = 560, LINE1_Y = 438;
    localparam integer SUB_VIEW_WIDTH = SUB_TEXT_X1 - SUB_TEXT_X0;
    localparam integer SUB_TEXT_PIXELS = 880;
    localparam integer SUB_GAP_PIXELS = 24;
    localparam integer SUB_SCROLL_PERIOD = SUB_VIEW_WIDTH + SUB_TEXT_PIXELS + SUB_GAP_PIXELS;

    wire sync_valid, time_valid;
    wire [23:0] sync_bcd;
    wire [9:0] sync_ms;
    osd_pc_time_rx #(.CLK_HZ(CLK_HZ), .BAUD(UART_BAUD)) u_pc_time_rx (
        .clk(video_clk), .rst(rst), .uart_rx(uart_rx),
        .sync_valid(sync_valid), .sync_bcd(sync_bcd), .sync_ms(sync_ms)
    );

    wire [3:0] time_hour_tens, time_hour_ones, time_min_tens, time_min_ones;
    wire [3:0] time_sec_tens, time_sec_ones;
    osd_timekeeper_25m #(.CLK_HZ(CLK_HZ)) u_timekeeper (
        .clk(video_clk), .rst(rst),
        .sync_valid(sync_valid), .sync_bcd(sync_bcd), .sync_ms(sync_ms),
        .time_valid(time_valid),
        .hour_tens(time_hour_tens), .hour_ones(time_hour_ones),
        .min_tens(time_min_tens), .min_ones(time_min_ones),
        .sec_tens(time_sec_tens), .sec_ones(time_sec_ones)
    );

    reg vs_d;
    reg [3:0] frame_fraction;
    reg [10:0] scroll_phase;
    // Cache phase - 560 modulo 2048 at frame boundaries. Negative source
    // coordinates map above 1567, outside the 880-pixel text. This removes
    // two serial subtractors from the coordinate-to-font critical path.
    reg [10:0] sub_scroll_offset;
    reg frame_synced;
    reg [23:0] frame_time;
    reg [31:0] frame_resolution;
    reg frame_resolution_valid;

    // VS rising edge is in vertical blanking. Both text layers are stable
    // throughout active video, including the second/minute digit changes.
    // Each cycle starts completely outside the right edge. Wrap occurs
    // only after the last glyph has left the left edge and the short gap.
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_d <= 1'b0;
            frame_fraction <= 0;
            frame_synced <= 0;
            scroll_phase <= 0;
            sub_scroll_offset <= 11'd1488;
            frame_time <= 0;
            frame_resolution<=0;frame_resolution_valid<=0;
        end else begin
            vs_d <= vs;
            if (vs && !vs_d && !de) begin
                frame_synced <= time_valid;
                frame_resolution<=resolution_bcd;
                frame_resolution_valid<=ENABLE_RESOLUTION && resolution_enable && resolution_valid;
                frame_time <= {time_hour_tens, time_hour_ones, time_min_tens,
                               time_min_ones, time_sec_tens, time_sec_ones};
                // Fractional motion: 5 pixels / 8 frames = 1.25 * old 1/2.
                if (frame_fraction >= 3) begin
                    frame_fraction <= frame_fraction - 3;
                    if (scroll_phase == SUB_SCROLL_PERIOD - 1) begin
                        scroll_phase <= 0;
                        sub_scroll_offset <= 11'd1488;
                    end else begin
                        scroll_phase <= scroll_phase + 1'b1;
                        sub_scroll_offset <= sub_scroll_offset + 1'b1;
                    end
                end else
                    frame_fraction <= frame_fraction + 5;
            end
        end
    end

    function automatic [7:0] time_char;
        input [3:0] i;
        input [3:0] hour_tens;
        input [3:0] hour_ones;
        input [3:0] min_tens;
        input [3:0] min_ones;
        input [3:0] sec_tens;
        input [3:0] sec_ones;
        begin
            case (i)
                4'd0: time_char = "T"; 4'd1: time_char = "I";
                4'd2: time_char = "M"; 4'd3: time_char = "E";
                4'd4: time_char = " "; 4'd5: time_char = 8'h30 + hour_tens;
                4'd6: time_char = 8'h30 + hour_ones; 4'd7: time_char = ":";
                4'd8: time_char = 8'h30 + min_tens;
                4'd9: time_char = 8'h30 + min_ones;
                4'd10: time_char = ":";
                4'd11: time_char = 8'h30 + sec_tens;
                default: time_char = 8'h30 + sec_ones;
            endcase
        end
    endfunction

    function automatic [5:0] time_glyph_id;
        input [7:0] ch;
        begin
            case(ch)
                8'd48: time_glyph_id=6'd5;
                8'd49: time_glyph_id=6'd6;
                8'd50: time_glyph_id=6'd7;
                8'd51: time_glyph_id=6'd8;
                8'd52: time_glyph_id=6'd9;
                8'd53: time_glyph_id=6'd10;
                8'd54: time_glyph_id=6'd11;
                8'd55: time_glyph_id=6'd12;
                8'd56: time_glyph_id=6'd13;
                8'd57: time_glyph_id=6'd14;
                8'd84: time_glyph_id=6'd1;
                8'd73: time_glyph_id=6'd2;
                8'd77: time_glyph_id=6'd3;
                8'd69: time_glyph_id=6'd4;
                8'd32: time_glyph_id=6'd0;
                8'd58: time_glyph_id=6'd15;
                8'd45: time_glyph_id=6'd16;
                8'd82: time_glyph_id=6'd50;
                8'd83: time_glyph_id=6'd51;
                8'd120: time_glyph_id=6'd52;
                default: time_glyph_id=0;
            endcase
        end
    endfunction

    function [7:0] resolution_char;
        input [3:0] i;
        input [31:0] value;
        begin
            case(i)
                0:resolution_char="R";1:resolution_char="E";2:resolution_char="S";3:resolution_char=" ";
                4:resolution_char=value[31:28]==0 ? " " : 8'h30+value[31:28];
                5:resolution_char=value[31:24]==0 ? " " : 8'h30+value[27:24];
                6:resolution_char=value[31:20]==0 ? " " : 8'h30+value[23:20];
                7:resolution_char=8'h30+value[19:16];
                8:resolution_char="x";
                9:resolution_char=value[15:12]==0 ? " " : 8'h30+value[15:12];
                10:resolution_char=value[15:8]==0 ? " " : 8'h30+value[11:8];
                11:resolution_char=value[15:4]==0 ? " " : 8'h30+value[7:4];
                default:resolution_char=8'h30+value[3:0];
            endcase
        end
    endfunction

    // Decimal cache nibbles are already valid BCD. Select font IDs directly
    // instead of building ASCII then decoding it back into the font address.
    function [5:0] resolution_id;
        input [3:0] i;
        input [31:0] value;
        reg [3:0] digit;
        reg numeric;
        reg [5:0] symbol;
        begin
            digit=0;numeric=0;symbol=0;
            case(i)
                0:symbol=50;1:symbol=4;2:symbol=51;3:symbol=0;8:symbol=52;
                4:begin digit=value[31:28];numeric=(value[31:28]!=0);end
                5:begin digit=value[27:24];numeric=(value[31:24]!=0);end
                6:begin digit=value[23:20];numeric=(value[31:20]!=0);end
                7:begin digit=value[19:16];numeric=1;end
                9:begin digit=value[15:12];numeric=(value[15:12]!=0);end
                10:begin digit=value[11:8];numeric=(value[15:8]!=0);end
                11:begin digit=value[7:4];numeric=(value[15:4]!=0);end
                default:begin digit=value[3:0];numeric=1;end
            endcase
            // One shared BCD-to-font addition for all eight digit positions.
            resolution_id=numeric ? 6'd5+{2'b0,digit} : symbol;
        end
    endfunction

    wire [5:0] subtitle_id;
    wire [4:0] subtitle_col;
    reg panel_hit, glyph_hit;
    reg [7:0] glyph_char;
    wire [31:0] glyph_bits;
    reg [5:0] glyph_id;
    reg [4:0] char_index, glyph_row;
    reg [4:0] glyph_col;
    reg [10:0] sub_local_x;
    reg [8:0] panel_r, panel_g, panel_b;
    reg [5:0] res_id;
    osd_subtitle_lookup u_subtitle_lookup(.pixel_x(sub_local_x), .id(subtitle_id), .col(subtitle_col));
    reg [5:0] glyph_id_q;
    reg [4:0] glyph_row_q,glyph_col_q;
    reg panel_hit_q,de_q;
    reg [23:0] base_rgb_q;
    wire [4:0] font_col=PIPELINED ? glyph_col_q : glyph_col;
    wire [23:0] mix_base=PIPELINED ? base_rgb_q : base_rgb;
    wire mix_de=PIPELINED ? de_q : de;
    wire mix_panel=PIPELINED ? panel_hit_q : panel_hit;
    osd_mixed_font u_font(.id(PIPELINED ? glyph_id_q : glyph_id),
        .row(PIPELINED ? glyph_row_q : glyph_row),.pixels(glyph_bits));
    always @(posedge video_clk or posedge rst) begin
        if(rst) begin
            glyph_id_q<=0;glyph_row_q<=0;glyph_col_q<=0;
            panel_hit_q<=0;de_q<=0;base_rgb_q<=0;
        end else begin
            glyph_id_q<=glyph_id;glyph_row_q<=glyph_row;glyph_col_q<=glyph_col;
            panel_hit_q<=panel_hit;de_q<=de;base_rgb_q<=base_rgb;
        end
    end

    always @* begin
        panel_hit = de &&
            (((x >= TIME_PANEL_X0) && (x < TIME_PANEL_X1) &&
              (y >= TIME_PANEL_Y0) && (y < TIME_PANEL_Y1)) ||
             (frame_resolution_valid && x >= TIME_PANEL_X0 && x < TIME_PANEL_X1 &&
              y >= RES_PANEL_Y0 && y < RES_PANEL_Y1) ||
             ((x >= SUB_PANEL_X0) && (x < SUB_PANEL_X1) &&
              (y >= SUB_PANEL_Y0) && (y < SUB_PANEL_Y1)));
        glyph_hit = 1'b0;
        glyph_char = " ";
        glyph_id = 0;
        char_index = 0;
        glyph_row = 0;
        glyph_col = 0;
        res_id=0;
        sub_local_x = {1'b0, x} + sub_scroll_offset;

        // Decode coordinates independently of display_valid/DE; blank only
        // at the output mux so the valid signal never traverses the font ROM.
        if (x >= TIME_TEXT_X && x < TIME_TEXT_X + 208 &&
            y >= LINE0_Y && y < LINE0_Y + 24) begin
            char_index = (x - TIME_TEXT_X) >> 4;
            glyph_col = (x - TIME_TEXT_X) & 15;
            glyph_row = y - LINE0_Y;
            glyph_char = time_char(char_index[3:0], frame_time[23:20],
                frame_time[19:16], frame_time[15:12], frame_time[11:8],
                frame_time[7:4], frame_time[3:0]);
            if (!frame_synced && (char_index==5 || char_index==6 ||
                char_index==8 || char_index==9 || char_index==11 || char_index==12))
                glyph_char = "-";
            glyph_id = time_glyph_id(glyph_char);
        end else if (frame_resolution_valid && x >= TIME_TEXT_X && x < TIME_TEXT_X+208 &&
                     y >= RES_TEXT_Y && y < RES_TEXT_Y+24) begin
            char_index=(x-TIME_TEXT_X)>>4;
            glyph_char=resolution_char(char_index[3:0],frame_resolution);
            res_id=resolution_id(char_index[3:0],frame_resolution);
            glyph_id=res_id;glyph_col=(x-TIME_TEXT_X)&15;glyph_row=y-RES_TEXT_Y;
        end else if (x >= SUB_TEXT_X0 && x < SUB_TEXT_X1 &&
                     y >= LINE1_Y && y < LINE1_Y + 24) begin
            if (sub_local_x < SUB_TEXT_PIXELS) begin
                glyph_col = subtitle_col;
                glyph_row = y - LINE1_Y;
                glyph_id = subtitle_id;
            end
        end
        glyph_hit = glyph_bits[31-font_col];

        // Preserve 50% white + 50% image; all operands share the same pipeline stage.
        panel_r = ({1'b0, mix_base[23:16]} + 9'd255) >> 1;
        panel_g = ({1'b0, mix_base[15:8]}  + 9'd255) >> 1;
        panel_b = ({1'b0, mix_base[7:0]}   + 9'd255) >> 1;
        if (!mix_de)
            out_rgb = 24'h000000;
        else if (glyph_hit)
            out_rgb = 24'h000000;
        else if (mix_panel)
            out_rgb = {panel_r[7:0], panel_g[7:0], panel_b[7:0]};
        else
            out_rgb = mix_base;
    end
endmodule

`default_nettype wire
