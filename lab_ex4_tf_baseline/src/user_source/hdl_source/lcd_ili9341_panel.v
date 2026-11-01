`default_nettype none
// Write-only ILI9341 16-bit 8080 panel; RD is permanently inactive.
// 25 MHz domain. CS/data setup, WR low, data hold, CS recovery: >=200ns each.
module lcd_ili9341_panel #(
    parameter integer CLK_HZ=25000000, PHASE_CYCLES=5
)(input wire clk,rst,
  input wire [1:0] calibration,mode,image_index,
  input wire calibration_error,auto_enabled,paused,media_ready,menu_open,
  input wire signed [8:0] brightness,
  input wire [8:0] contrast,
  output wire [15:0] lcd_d,
  output wire lcd_cs_n,lcd_wr_n,lcd_rd_n,lcd_dc,
  output reg lcd_rst_n,lcd_bl,
  output reg initialized,
  output reg [1:0] rendered_calibration,
  output wire [8:0] debug_x,
  output wire [7:0] debug_y,
  output wire [15:0] debug_pixel,
  output wire debug_accept
);
    reg [2:0] state;
    reg [21:0] delay_count;
    reg [7:0] init_index;
    wire [17:0] init_word;
    reg [3:0] window_index;
    reg [8:0] x;
    reg [7:0] y;
    // Capture the entire UI state once per repaint to avoid split text/status.
    reg [28:0] status_latched;
    wire [1:0] cal=status_latched[28:27];
    wire cal_error=status_latched[26];
    wire [1:0] m=status_latched[25:24],im=status_latched[23:22];
    wire au=status_latched[21],pa=status_latched[20],rd=status_latched[19],me=status_latched[18];
    wire signed [8:0] br=status_latched[17:9];
    wire [8:0] ct=status_latched[8:0];
    wire [28:0] status_live={calibration,calibration_error,mode,image_index,
        auto_enabled,paused,media_ready,menu_open,brightness,contrast};
    reg [1:0] bus_phase;
    reg bus_busy;
    reg [3:0] bus_count;
    reg [15:0] bus_data;
    reg bus_cs,bus_wr,bus_dc;
    wire bus_ready=!bus_busy;
    reg [15:0] word;
    reg word_dc;
    wire word_valid=(state==2 && init_word[17:16]<2) || state==5 || state==6;
    wire accept=word_valid && bus_ready;
    assign lcd_d=bus_data;assign lcd_cs_n=bus_cs;assign lcd_wr_n=bus_wr;
    assign lcd_dc=bus_dc;assign lcd_rd_n=1'b1;
    assign debug_x=x;assign debug_y=y;assign debug_pixel=word;assign debug_accept=accept && state==6;
    always @(posedge clk or posedge rst) begin
        if(rst) begin bus_phase<=0;bus_busy<=0;bus_count<=0;bus_data<=0;bus_cs<=1;bus_wr<=1;bus_dc<=1;end
        else if(!bus_busy) begin
            if(word_valid) begin
                bus_busy<=1;bus_phase<=0;bus_count<=PHASE_CYCLES-1;
                bus_data<=word;bus_dc<=word_dc;bus_cs<=0;bus_wr<=1;
            end
        end else if(bus_count!=0) bus_count<=bus_count-1'b1;
        else begin
            bus_count<=PHASE_CYCLES-1;
            case(bus_phase)
              0:bus_wr<=0;
              1:bus_wr<=1;
              2:bus_cs<=1;
              3:bus_busy<=0;
            endcase
            bus_phase<=bus_phase+1'b1;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=0;delay_count<=(CLK_HZ/1000)*20-1;init_index<=0;
            lcd_rst_n<=0;lcd_bl<=0;initialized<=0;
            x<=0;y<=0;window_index<=0;status_latched<=0;rendered_calibration<=0;
        end else begin
            case(state)
              0:if(delay_count!=0) delay_count<=delay_count-1'b1;
                else begin lcd_rst_n<=1;delay_count<=(CLK_HZ/1000)*120-1;state<=1;end
              1:if(delay_count!=0) delay_count<=delay_count-1'b1;else state<=2;
              2:if(bus_ready) begin
                  if(init_word[17:16]==2) begin
                      delay_count<=(CLK_HZ/1000)*init_word[7:0]-1;state<=3;init_index<=init_index+1'b1;
                  end else if(init_word[17:16]==3) begin initialized<=1;state<=4;end
                  else if(accept) init_index<=init_index+1'b1;
              end
              3:if(delay_count!=0) delay_count<=delay_count-1'b1;else state<=2;
              4:begin
                  status_latched<=status_live;window_index<=0;x<=0;y<=0;state<=5;
              end
              5:if(accept) begin
                  if(window_index==10) state<=6;else window_index<=window_index+1'b1;
              end
              6:if(accept) begin
                  if(x==319) begin
                      x<=0;
                      if(y==239) begin state<=7;lcd_bl<=1;rendered_calibration<=cal;end
                      else y<=y+1'b1;
                  end else x<=x+1'b1;
              end
              7:if(bus_ready && status_live!=status_latched) state<=4;
            endcase
        end
    end
    wire [1:0] col=x<80?0:x<160?1:x<240?2:3;
    wire [8:0] local_x=x-({7'd0,col}*9'd80);
    wire [7:0] shifted_y=y-8'd48;
    wire [1:0] row=shifted_y[7:6];
    wire [5:0] local_y=shifted_y[5:0];
    wire [3:0] button_id={row,col}+4'd1;
    reg [47:0] label;
    reg [7:0] character;
    wire [2:0] font_row=y<48?y[3:1]:(local_y-6'd24)>>1;
    wire [4:0] glyph;
    wire [5:0] char_index=x[8:3];
    wire [6:0] magnitude=br<0?-br:br;
    // Bounded exact division for 0..255, avoiding a promoted 32-bit /10.
    wire [15:0] magnitude16={9'd0,magnitude};
    wire [15:0] times205=(magnitude16<<7)+(magnitude16<<6)+(magnitude16<<3)+(magnitude16<<2)+magnitude16;
    wire [4:0] decimal_tens=times205[15:11];
    wire [7:0] decimal_tens8={3'd0,decimal_tens};
    wire [7:0] decimal_ones={1'b0,magnitude}-((decimal_tens8<<3)+(decimal_tens8<<1));
    reg [23:0] contrast_digits;
    reg [15:0] background,pixel;
    wire [8:0] target_x=(cal==1)?9'd288:9'd32;
    wire [7:0] target_y=(cal==2)?8'd176:8'd48;
    wire cross_pixel=((x==target_x && y+10>=target_y && y<=target_y+10) ||
                (y==target_y && x+10>=target_x && x<=target_x+10));
    wire text_pixel=x[2:0]<5 && font_row<7 && glyph[4-x[2:0]];
    touch_lcd_rom rom(.init_index(init_index),.init_word(init_word),
        .character(character[5:0]),.font_row(font_row),.glyph(glyph));
    always @* begin
        case(ct)
          128:contrast_digits="128";192:contrast_digits="192";
          320:contrast_digits="320";384:contrast_digits="384";
          default:contrast_digits="256";
        endcase
        case(button_id)
          1:label="PHOTO ";2:label="VIDEO ";3:label="NEXT  ";4:label="AUTO  ";
          5:label=pa?"PLAY  ":"PAUSE ";6:label="MENU  ";
          7:label="BRT - ";8:label="BRT + ";9:label="CNT - ";10:label="CNT + ";
          11:label="RESET ";default:label="CAL   ";
        endcase
        character=8'h20;
        if(y<48) begin
            case(y[5:4])
              0:if(cal!=3) begin
                  if(char_index<17) character=(136'h544f55434820454143482043524f535320 >> ((16-char_index)*8));
                end else if(char_index<20) character=(160'h48583453323020544f55434820434f4e54524f4c >> ((19-char_index)*8));
              1:if(cal!=3) begin
                  case(char_index)
                    0:character="S";1:character="T";2:character="E";3:character="P";4:character=":";
                    5:character="1"+cal;7:character="O";8:character="F";10:character="3";
                    12:if(cal_error)character="R";13:if(cal_error)character="E";
                    14:if(cal_error)character="T";15:if(cal_error)character="R";16:if(cal_error)character="Y";
                  endcase
                end else begin
                  case(char_index)
                    0:character="M";1:character="O";2:character="D";3:character="E";4:character=":";
                    5:character=m==1?"V":m==2?"T":"P";
                    7:character="I";8:character="M";9:character="G";10:character=":";11:character="1"+im;
                    13:character="A";14:character="U";15:character="T";16:character="O";17:character=":";18:character="0"+au;
                    20:character="P";21:character="A";22:character="U";23:character="S";24:character="E";25:character=":";26:character="0"+pa;
                    28:character="R";29:character="E";30:character="A";31:character="D";32:character="Y";33:character=":";34:character="0"+rd;
                  endcase
                end
              2:if(cal==3) begin
                  case(char_index)
                    0:character="B";1:character="R";2:character="T";3:character=":";
                    4:character=br<0?"-":"+";5:character=8'd48+{3'd0,decimal_tens};6:character=8'd48+decimal_ones;
                    8:character="C";9:character="N";10:character="T";11:character=":";
                    12:character=contrast_digits[23:16];13:character=contrast_digits[15:8];14:character=contrast_digits[7:0];
                    16:character="M";17:character="E";18:character="N";19:character="U";20:character=":";21:character="0"+me;
                  endcase
                end
            endcase
        end else if(cal==3 && local_x>=16 && local_x<64 && local_y>=24 && local_y<38)
            character=label >> ((7-(local_x>>3))*8);
        background=16'h1084;
        if(button_id==1 && m!=1 || button_id==2 && m==1 || button_id==4 && au || button_id==6 && me) background=16'h03a0;
        if((button_id==3 || button_id==4) && (m==1 || !rd)) background=16'h4208;
        if(button_id==5 && pa) background=16'hc400;
        if(button_id==12) background=16'h4008;
        if(cal!=3) pixel=cross_pixel?16'hffe0:16'h0000;
        else if(y<48) pixel=16'h0000;
        else if(local_x<2 || local_x>=78 || local_y<2 || local_y>=62) pixel=16'h7bef;
        else pixel=background;
        if((y<48 || cal==3 && local_y>=24 && local_y<38) && text_pixel) pixel=16'hffff;
        word=pixel;word_dc=1;
        if(state==2) begin word=init_word[15:0];word_dc=init_word[16];end
        else if(state==5) begin
            case(window_index)
              0:begin word=16'h002a;word_dc=0;end
              1,2,6,7,8:word=0;
              3:word=1;4:word=16'h003f;
              5:begin word=16'h002b;word_dc=0;end
              9:word=16'h00ef;
              default:begin word=16'h002c;word_dc=0;end
            endcase
        end
    end
endmodule
`default_nettype wire
