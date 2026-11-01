`default_nettype none

// Final overlay after the existing menu/time/UART subtitle OSD.
// Wave x=[336,624), spectrum x=[16,304), y=[288,376): above subtitles.
// Existing waveform pixels, sampling and latency remain unchanged.
// Two stages align synchronous waveform RAM with RGB, HS, VS and DE.
module video_audio_waveform (
    input wire clk, rst, enable,
    input wire hs, vs, de,
    input wire [23:0] rgb_in,
    input wire audio_valid,
    input wire [23:0] audio_left, audio_right,
    output reg hs_out, vs_out, de_out,
    output reg [23:0] rgb_out
);
    wire [9:0] x, y;
    video_osd_coord_640x480 coords(
        .video_clk(clk),.rst(rst),.vs(vs),.de(de),.x(x),.y(y));
    reg vs_d;
    always @(posedge clk or posedge rst)
        if (rst) vs_d<=0; else vs_d<=vs;
    wire [7:0] read_index = x - 10'd352;
    wire [15:0] point;
    wire snapshot_valid;
    wire [7:0] level;
    audio_waveform_capture capture(
        .clk(clk),.rst(rst),.enable(enable),.sample_valid(audio_valid),
        .frame_swap(vs && !vs_d && !de),.pcm_left(audio_left),.pcm_right(audio_right),
        .read_index(read_index),.read_point(point),.snapshot_valid(snapshot_valid),.level(level));
    wire [95:0] spectrum_bars;
    wire spectrum_valid;
    audio_spectrum_goertzel spectrum(
        .clk(clk),.rst(rst),.enable(enable),.sample_valid(audio_valid),
        .frame_swap(vs && !vs_d && !de),.pcm_left(audio_left),
        .display_bars(spectrum_bars),.spectrum_valid(spectrum_valid));
    reg hs_s, vs_s, de_s, enable_s, valid_s;
    reg [23:0] rgb_s;
    reg [9:0] x_s, y_s;
    reg [7:0] level_s;
    // Seven glyphs only: no duplicate large font ROM.
    function [34:0] label_font;
        input [2:0] index;
        begin
            case (index)
                0: label_font=35'b01110_10001_10001_11111_10001_10001_10001; // A
                1: label_font=35'b10001_10001_10001_10001_10001_10001_01110; // U
                2: label_font=35'b11110_10001_10001_10001_10001_10001_11110; // D
                3: label_font=35'b01110_00100_00100_00100_00100_00100_01110; // I
                4: label_font=35'b01110_10001_10001_10001_10001_10001_01110; // O
                5: label_font=35'b01111_10000_10000_01110_00001_00001_11110; // S
                6: label_font=35'b11110_10001_10001_11110_10000_10000_10000; // P
                default: label_font=0;
            endcase
        end
    endfunction
    wire panel = enable_s && de_s && x_s>=336 && x_s<624 && y_s>=288 && y_s<376;
    wire border = x_s==336 || x_s==623 || y_s==288 || y_s==375;
    wire plot = x_s>=352 && x_s<608 && y_s>=304 && y_s<368;
    wire [5:0] plot_y = y_s - 10'd304;
    wire wave = plot && valid_s && plot_y>=point[5:0] && plot_y<=point[13:8];
    wire grid = plot && (y_s==336 || x_s==416 || x_s==480 || x_s==544);
    wire meter = x_s>=352 && x_s<608 && y_s>=370 && y_s<374;
    wire [8:0] meter_x = x_s - 10'd352;
    wire meter_fill = valid_s && (level_s==255 || meter_x<level_s);
    wire [5:0] label_x = x_s - 10'd352;
    wire [3:0] label_y = y_s - 10'd294;
    wire [34:0] glyph = label_font(label_x[5:3]);
    wire label_hit = x_s>=352 && x_s<392 && y_s>=294 && y_s<301 &&
        label_x[2:0]<5 && glyph[34-label_y*5-label_x[2:0]];
    wire spectrum_panel=enable_s && de_s && x_s>=16 && x_s<304 && y_s>=288 && y_s<376;
    wire spectrum_border=x_s==16 || x_s==303 || y_s==288 || y_s==375;
    wire spectrum_plot=x_s>=32 && x_s<288 && y_s>=304 && y_s<368;
    wire [7:0] spectrum_x=x_s-10'd32;
    reg [5:0] column_height;
    always @* begin
        case(spectrum_x[7:4])
            0:column_height=spectrum_bars[5:0];1:column_height=spectrum_bars[11:6];
            2:column_height=spectrum_bars[17:12];3:column_height=spectrum_bars[23:18];
            4:column_height=spectrum_bars[29:24];5:column_height=spectrum_bars[35:30];
            6:column_height=spectrum_bars[41:36];7:column_height=spectrum_bars[47:42];
            8:column_height=spectrum_bars[53:48];9:column_height=spectrum_bars[59:54];
            10:column_height=spectrum_bars[65:60];11:column_height=spectrum_bars[71:66];
            12:column_height=spectrum_bars[77:72];13:column_height=spectrum_bars[83:78];
            14:column_height=spectrum_bars[89:84];15:column_height=spectrum_bars[95:90];
        endcase
    end
    wire spectrum_fill=spectrum_valid && spectrum_plot && spectrum_x[3:0]<13 &&
        {1'b0,plot_y}>=7'd64-{1'b0,column_height};
    wire spectrum_grid=spectrum_plot && (y_s==320 || y_s==336 || y_s==352 || y_s==367);
    wire [4:0] spectrum_label_x=x_s-10'd32;
    wire [34:0] spectrum_glyph=label_font(spectrum_label_x[4:3]==0 ? 3'd5 : 3'd6);
    wire spectrum_label_hit=x_s>=32 && x_s<48 && y_s>=294 && y_s<301 &&
        spectrum_label_x[2:0]<5 && spectrum_glyph[34-label_y*5-spectrum_label_x[2:0]];
    reg [23:0] painted;
    always @* begin
        painted=rgb_s;
        if (panel) begin
            painted={2'b00,rgb_s[23:18],2'b00,rgb_s[15:10],2'b00,rgb_s[7:2]};
            if (grid) painted=24'h304452;
            if (wave) painted=24'h44ffbb;
            if (meter) painted=meter_fill ? (level_s>=224 ? 24'hffba55 : 24'h44ffbb) : 24'h243440;
            if (border) painted=24'h6090a0;
            if (label_hit) painted=24'hb8e8f0;
        end
        if(spectrum_panel) begin
            painted={2'b00,rgb_s[23:18],2'b00,rgb_s[15:10],2'b00,rgb_s[7:2]};
            if(spectrum_grid) painted=24'h304452;
            if(spectrum_fill) painted=y_s<320 ? 24'hffba55 : (y_s<344 ? 24'h55dfff : 24'h4488ff);
            if(spectrum_border) painted=24'h6090a0;
            if(spectrum_label_hit) painted=24'hb8e8f0;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hs_s<=0; vs_s<=0; de_s<=0; rgb_s<=0; x_s<=0; y_s<=0;
            enable_s<=0; valid_s<=0; level_s<=0;
            hs_out<=0; vs_out<=0; de_out<=0; rgb_out<=0;
        end else begin
            hs_s<=hs; vs_s<=vs; de_s<=de; rgb_s<=rgb_in; x_s<=x; y_s<=y;
            enable_s<=enable; valid_s<=snapshot_valid; level_s<=level;
            hs_out<=hs_s; vs_out<=vs_s; de_out<=de_s; rgb_out<=painted;
        end
    end
endmodule
`default_nettype wire
