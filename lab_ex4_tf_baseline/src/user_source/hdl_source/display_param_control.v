`default_nettype none
// All UI state lives in the video domain; only playback event toggles cross
// to the 50 MHz SD controller. A short gesture is emitted ON RELEASE.
module display_param_control #(
    parameter integer FAST_NEXT=0,
    parameter integer ENABLE_TOUCH=0,
    parameter integer CLK_HZ=25_000_000,
    parameter integer DEBOUNCE_MS=30,
    parameter integer LONG_MS=1000
)(
    input wire clk,rst,key1,key2,
    output reg menu_open,selected_contrast,
    output reg signed [8:0] brightness,
    output reg [8:0] contrast_q8,
    output reg next_toggle,auto_toggle,
    // Held request: set on touch command 11, cleared only when the caller
    // actually resets this block. A held level cannot produce a second edge
    // when the reset clears it, which a toggle would.
    output reg reset_request,
    input wire touch_valid,
    input wire [3:0] touch_command
);
    wire down1,down2,short1,short2,long1,long2;
    display_key_gesture #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.LONG_MS(LONG_MS)) k1(
        .clk(clk),.rst(rst),.button_n(key1),.down(down1),.short_press(short1),.long_press(long1));
    display_key_gesture #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.LONG_MS(LONG_MS)) k2(
        .clk(clk),.rst(rst),.button_n(key2),.down(down2),.short_press(short2),.long_press(long2));
    reg chord_lock,down1_d;
    wire press1=down1 && !down1_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            menu_open<=0;selected_contrast<=0;brightness<=0;contrast_q8<=256;
            next_toggle<=0;auto_toggle<=0;chord_lock<=0;down1_d<=0;reset_request<=0;
        end else begin
            down1_d<=down1;
            if(down1 && down2) chord_lock<=1;
            else if(!down1 && !down2) chord_lock<=0;
            if(!chord_lock && !(down1 && down2)) begin
              if(ENABLE_TOUCH && touch_valid) begin
                case(touch_command)
                  3:next_toggle<=!next_toggle;
                  4:auto_toggle<=!auto_toggle;
                  6:menu_open<=!menu_open;
                  7:if(brightness > -9'sd64) brightness<=brightness-9'sd4;
                  8:if(brightness < 9'sd64) brightness<=brightness+9'sd4;
                  9:if(contrast_q8>128) contrast_q8<=contrast_q8-9'd64;
                 10:if(contrast_q8<384) contrast_q8<=contrast_q8+9'd64;
                 11:begin brightness<=0;contrast_q8<=256;reset_request<=1;end
                endcase
              end else begin
                if(FAST_NEXT && press1 && !menu_open) next_toggle<=!next_toggle;
                if(long1) begin
                    if(!FAST_NEXT || menu_open) menu_open<=!menu_open;
                end
                else if(long2) begin
                    if(menu_open) selected_contrast<=!selected_contrast;
                    else if(FAST_NEXT) menu_open<=1;
                end else if(short1) begin
                    if(!menu_open) begin
                        if(!FAST_NEXT) next_toggle<=!next_toggle;
                    end
                    else if(selected_contrast) begin
                        if(contrast_q8>128) contrast_q8<=contrast_q8-9'd64;
                    end else if(brightness > -9'sd64) brightness<=brightness-9'sd4;
                end else if(short2) begin
                    if(!menu_open) auto_toggle<=!auto_toggle;
                    else if(selected_contrast) begin
                        if(contrast_q8<384) contrast_q8<=contrast_q8+9'd64;
                    end else if(brightness < 9'sd64) brightness<=brightness+9'sd4;
                end
              end
            end
        end
    end
endmodule

module display_key_gesture #(
    parameter integer CLK_HZ=25_000_000,DEBOUNCE_MS=30,LONG_MS=1000
)(input wire clk,rst,button_n,output wire down,output reg short_press,long_press);
    localparam integer DB_RAW=(CLK_HZ/1000)*DEBOUNCE_MS;
    localparam integer LONG_RAW=(CLK_HZ/1000)*LONG_MS;
    localparam integer DB_COUNT=(DB_RAW<1)?1:DB_RAW;
    localparam integer LONG_COUNT=(LONG_RAW<1)?1:LONG_RAW;
    localparam integer DW=(DB_COUNT<2)?1:$clog2(DB_COUNT);
    localparam integer LW=(LONG_COUNT<2)?1:$clog2(LONG_COUNT);
    (* async_reg="true" *) reg meta,sync;
    reg [1:0] input_settled;
    reg stable,stable_d,armed,sent_long,released;
    reg [DW-1:0] db_count;
    reg [LW-1:0] hold_count;
    assign down=!stable;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            meta<=1;sync<=1;stable<=1;stable_d<=1;db_count<=0;
            input_settled<=0;
            hold_count<=0;armed<=0;sent_long<=0;released<=0;short_press<=0;long_press<=0;
        end else begin
            meta<=button_n;sync<=meta;stable_d<=stable;
            input_settled<={input_settled[0],1'b1};
            short_press<=0;long_press<=0;
            // A key held through reset is not a new gesture. Require a full
            // released debounce interval before accepting its first press.
            if(!released) begin
                stable<=1;stable_d<=1;armed<=0;sent_long<=0;hold_count<=0;
                if(!input_settled[1] || !sync) db_count<=0;
                else if(db_count==DB_COUNT-1) begin released<=1;db_count<=0;end
                else db_count<=db_count+1'b1;
            end else begin
            if(sync==stable) db_count<=0;
            else if(db_count==DB_COUNT-1) begin stable<=sync;db_count<=0;end
            else db_count<=db_count+1'b1;
            if(stable_d && !stable) begin armed<=1;hold_count<=0;sent_long<=0;end
            else if(!stable_d && stable) begin
                if(armed && !sent_long) short_press<=1;
                armed<=0;hold_count<=0;
            end else if(!stable && armed && !sent_long) begin
                if(hold_count==LONG_COUNT-1) begin long_press<=1;sent_long<=1;end
                else hold_count<=hold_count+1'b1;
            end
            end
        end
    end
endmodule

// An event is a held toggle, not a narrow asynchronous pulse. One video-clock
// pulse is reconstructed exactly once in the destination domain.
module display_event_sync(input wire clk,rst,toggle_async,output wire pulse);
    (* async_reg="true" *) reg [2:0] sync;
    always @(posedge clk or posedge rst)
        if(rst) sync<=0;else sync<={sync[1:0],toggle_async};
    assign pulse=sync[2]^sync[1];
endmodule
`default_nettype wire
