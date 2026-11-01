`default_nettype none
// Dedicated readable 5x7 bitmap font, doubled within 16x24 cells.
// Two register stages, unchanged by animation. The complete panel translates
// from above the screen, bounces twice, then rests at x=[16,304), y=[64,192).
module osd_display_params #(
    parameter integer ANIMATE_MENU=1
)(
    input wire clk,rst,hs,vs,de,
    input wire [9:0] x,y,
    input wire [23:0] base_rgb,
    input wire menu_open,selected_contrast,
    input wire signed [8:0] brightness,
    input wire [8:0] contrast_q8,
    output reg hs_out,vs_out,de_out,
    output reg [23:0] rgb_out
);
    // 36 frames (~0.60 s at 640x480/60). A small constant trajectory avoids
    // multipliers, division, frame buffers and variable-speed clock counters.
    // All movement is committed in vertical blanking, never during a line.
    function signed [10:0] drop_top;
        input [5:0] step;
        begin
            case(step)
                 0:drop_top=-128;  1:drop_top=-127;  2:drop_top=-124;
                 3:drop_top=-119;  4:drop_top=-112;  5:drop_top=-103;
                 6:drop_top=-92;   7:drop_top=-79;   8:drop_top=-64;
                 9:drop_top=-47;  10:drop_top=-28;  11:drop_top=-7;
                12:drop_top=16;   13:drop_top=40;   14:drop_top=64;
                15:drop_top=76;   16:drop_top=82;   17:drop_top=80;
                18:drop_top=74;   19:drop_top=66;   20:drop_top=58;
                21:drop_top=52;   22:drop_top=50;   23:drop_top=52;
                24:drop_top=56;   25:drop_top=61;   26:drop_top=66;
                27:drop_top=69;   28:drop_top=70;   29:drop_top=69;
                30:drop_top=67;   31:drop_top=65;   32:drop_top=63;
                33:drop_top=62;   34:drop_top=63;
                default:drop_top=64;
            endcase
        end
    endfunction
    reg vs_d,menu_seen;
    reg [5:0] drop_step;
    reg signed [10:0] animated_top;
    wire signed [10:0] panel_top=ANIMATE_MENU ? animated_top : 11'sd64;
    // 12 bits prevent signed overflow when clipping at the top of the screen.
    wire signed [11:0] panel_y=$signed({2'b00,y})-
        $signed({panel_top[10],panel_top});
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            vs_d<=0;menu_seen<=0;drop_step<=0;animated_top<=-11'sd128;
        end else begin
            vs_d<=vs;
            if(vs && !vs_d && !de) begin
                menu_seen<=menu_open;
                if(!menu_open || !menu_seen) begin
                    drop_step<=0;animated_top<=-11'sd128;
                end else if(drop_step<35) begin
                    drop_step<=drop_step+1'b1;
                    animated_top<=drop_top(drop_step+1'b1);
                end
            end
        end
    end
    function [34:0] font;
        input [7:0] ch;
        begin
            case(ch)
                8'd48: font=35'b01110_10001_10011_10101_11001_10001_01110; // 0
                8'd49: font=35'b00100_01100_00100_00100_00100_00100_01110; // 1
                8'd50: font=35'b01110_10001_00001_00010_00100_01000_11111; // 2
                8'd51: font=35'b11110_00001_00001_01110_00001_00001_11110; // 3
                8'd52: font=35'b00010_00110_01010_10010_11111_00010_00010; // 4
                8'd53: font=35'b11111_10000_10000_11110_00001_00001_11110; // 5
                8'd54: font=35'b01110_10000_10000_11110_10001_10001_01110; // 6
                8'd55: font=35'b11111_00001_00010_00100_01000_01000_01000; // 7
                8'd56: font=35'b01110_10001_10001_01110_10001_10001_01110; // 8
                8'd57: font=35'b01110_10001_10001_01111_00001_00001_01110; // 9
                8'd65: font=35'b01110_10001_10001_11111_10001_10001_10001; // A
                8'd66: font=35'b11110_10001_10001_11110_10001_10001_11110; // B
                8'd67: font=35'b01111_10000_10000_10000_10000_10000_01111; // C
                8'd68: font=35'b11110_10001_10001_10001_10001_10001_11110; // D
                8'd69: font=35'b11111_10000_10000_11110_10000_10000_11111; // E
                8'd71: font=35'b01111_10000_10000_10111_10001_10001_01111; // G
                8'd72: font=35'b10001_10001_10001_11111_10001_10001_10001; // H
                8'd73: font=35'b01110_00100_00100_00100_00100_00100_01110; // I
                8'd75: font=35'b10001_10010_10100_11000_10100_10010_10001; // K
                8'd76: font=35'b10000_10000_10000_10000_10000_10000_11111; // L
                8'd78: font=35'b10001_11001_11001_10101_10011_10011_10001; // N
                8'd79: font=35'b01110_10001_10001_10001_10001_10001_01110; // O
                8'd80: font=35'b11110_10001_10001_11110_10000_10000_10000; // P
                8'd82: font=35'b11110_10001_10001_11110_10100_10010_10001; // R
                8'd83: font=35'b01111_10000_10000_01110_00001_00001_11110; // S
                8'd84: font=35'b11111_00100_00100_00100_00100_00100_00100; // T
                8'd85: font=35'b10001_10001_10001_10001_10001_10001_01110; // U
                8'd88: font=35'b10001_10001_01010_00100_01010_10001_10001; // X
                8'd89: font=35'b10001_10001_01010_00100_00100_00100_00100; // Y
                8'd43: font=35'b00000_00100_00100_11111_00100_00100_00000; // +
                8'd45: font=35'b00000_00000_00000_11111_00000_00000_00000; // -
                8'd62: font=35'b10000_01000_00100_00010_00100_01000_10000; // >
                8'd46: font=35'b00000_00000_00000_00000_00000_00110_00110; // .
                8'd58: font=35'b00000_00110_00110_00000_00110_00110_00000; // :
                default: font=0;
            endcase
        end
    endfunction
    function [7:0] fixed_char;
        input [127:0] text;
        input [4:0] index;
        begin
            if(index<16) fixed_char=text[127-index*8 -: 8];
            else fixed_char=" ";
        end
    endfunction
    reg [7:0] ch;
    reg [4:0] col;
    reg [9:0] local_x,local_y,row_y;
    reg [7:0] magnitude;
    // Exact unsigned 8-bit /10 and %10, with explicitly bounded arithmetic.
    // Unsized /10 in the character expression promoted the old divider to
    // 32 bits in TD, costing a large amount of logic for two decimal digits.
    wire [15:0] mag16={8'd0,magnitude};
    wire [15:0] mag205=(mag16<<7)+(mag16<<6)+(mag16<<3)+(mag16<<2)+mag16;
    wire [4:0] tens=mag205[15:11];
    wire [7:0] tens8={3'd0,tens};
    wire [7:0] ones=magnitude-((tens8<<3)+(tens8<<1));
    reg [7:0] decimal_high,decimal_low;
    reg panel,border,text_hit,bar_hit,bar_fill;
    reg [7:0] fill_width;
    reg [23:0] color;
    reg [1:0] line_index;
    always @* begin
        panel=menu_open && x>=16 && x<304 && panel_y>=0 && panel_y<128;
        border=panel && (x==16 || x==303 || panel_y==0 || panel_y==127);
        ch=" ";col=0;row_y=0;local_x=0;local_y=0;line_index=0;
        text_hit=0;bar_hit=0;bar_fill=0;fill_width=0;color=24'hffffff;
        magnitude=brightness[8] ? -brightness : brightness;
        decimal_high="0";decimal_low="0";
        case(contrast_q8)
            128: begin decimal_high="5";decimal_low="0";end
            192: begin decimal_high="7";decimal_low="5";end
            320: begin decimal_high="2";decimal_low="5";end
            384: begin decimal_high="5";decimal_low="0";end
            default: begin decimal_high="0";decimal_low="0";end
        endcase
        if(panel_y>=8 && panel_y<32) begin row_y=8;line_index=0;end
        else if(panel_y>=36 && panel_y<60) begin row_y=36;line_index=1;end
        else if(panel_y>=64 && panel_y<88) begin row_y=64;line_index=2;end
        else if(panel_y>=96 && panel_y<120) begin row_y=96;line_index=3;end
        if(panel && x>=24 && x<280 && row_y!=0) begin
            local_x=x-24;local_y=panel_y-row_y;col=local_x[8:4];
            case(line_index)
                0: begin ch=fixed_char("DISPLAY SETTINGS",col);color=24'h80dfff;end
                1: begin
                    ch=fixed_char("  BRIGHTNESS +00",col);
                    if(col==0) ch=selected_contrast ? " " : ">";
                    if(col==13) ch=brightness[8] ? "-" : "+";
                    if(col==14) ch=8'd48+{3'd0,tens};
                    if(col==15) ch=8'd48+ones;
                    color=selected_contrast ? 24'hffffff : 24'hffe060;
                end
                2: begin
                    ch=fixed_char("  CONTRAST 1.00X",col);
                    if(col==0) ch=selected_contrast ? ">" : " ";
                    if(col==11) ch=(contrast_q8<256) ? "0" : "1";
                    if(col==12) ch=".";
                    if(col==13) ch=decimal_high;
                    if(col==14) ch=decimal_low;
                    if(col==15) ch="X";
                    color=selected_contrast ? 24'hffe060 : 24'hffffff;
                end
                3: begin ch=fixed_char("K1- K2+ K2:HOLD ",col);color=24'hb0b0b0;end
            endcase
            text_hit=local_x[3:0]>=3 && local_x[3:0]<13 && local_y>=4 && local_y<18;
        end
        if(panel && x>=152 && x<280 && ((panel_y>=60 && panel_y<63)||(panel_y>=88 && panel_y<91))) begin
            bar_hit=1;
            fill_width=(panel_y<64) ? $signed(brightness)+9'sd64 : (contrast_q8-9'd128)>>1;
            bar_fill=(x-152)<fill_width;
        end
    end
    reg hs1,vs1,de1,panel1,border1,text1,bar1,fill1;
    reg glyph1;
    reg [2:0] gx1,gy1;
    reg [23:0] base1,color1;
    wire [2:0] gx_now=(local_x[3:0]-4'd3)>>1;
    wire [2:0] gy_now=(local_y-10'd4)>>1;
    wire [5:0] glyph_index=6'd34-({3'd0,gy_now}*6'd5+{3'd0,gx_now});
    wire [34:0] font_now=font(ch);
    wire glyph=text1 && glyph1;
    wire [23:0] dark={2'b00,base1[23:18],2'b00,base1[15:10],2'b00,base1[7:2]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            hs1<=0;vs1<=0;de1<=0;panel1<=0;border1<=0;text1<=0;bar1<=0;fill1<=0;
            glyph1<=0;gx1<=0;gy1<=0;base1<=0;color1<=0;
            hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;
        end else begin
            hs1<=hs;vs1<=vs;de1<=de;panel1<=panel;border1<=border;
            text1<=text_hit;bar1<=bar_hit;fill1<=bar_fill;glyph1<=font_now[glyph_index];
            gx1<=(local_x[3:0]-4'd3)>>1;gy1<=(local_y-10'd4)>>1;
            base1<=base_rgb;color1<=color;
            hs_out<=hs1;vs_out<=vs1;de_out<=de1;
            if(!de1) rgb_out<=0;
            else if(!panel1) rgb_out<=base1;
            else if(glyph) rgb_out<=color1;
            else if(border1) rgb_out<=24'h608090;
            else if(bar1) rgb_out<=fill1 ? 24'h80dfff : 24'h303840;
            else rgb_out<=dark;
        end
    end
endmodule
`default_nettype wire
