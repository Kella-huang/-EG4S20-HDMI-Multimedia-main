`default_nettype none
// 115200 8N1: AA 55 HH_BCD MM_BCD SS_BCD ms_lo ms_hi XOR(payload).
// All logic is in the video clock domain; only the physical RX pin is async.
module osd_pc_time_rx #(
    parameter integer CLK_HZ=25_000_000,
    parameter integer BAUD=115200
) (
    input wire clk, rst, uart_rx,
    output reg sync_valid,
    output reg [23:0] sync_bcd,
    output reg [9:0] sync_ms
);
    localparam integer BIT_TICKS=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(BIT_TICKS<2)?1:$clog2(BIT_TICKS);
    localparam integer TIMEOUT_TICKS=CLK_HZ/100; // 10 ms inter-byte timeout
    localparam integer TW=(TIMEOUT_TICKS<2)?1:$clog2(TIMEOUT_TICKS);
    (* async_reg = "true" *) reg rx_meta, rx_sync;
    always @(posedge clk or posedge rst) begin
        if(rst) begin rx_meta<=1; rx_sync<=1; end
        else begin rx_meta<=uart_rx; rx_sync<=rx_meta; end
    end
    reg [1:0] state;
    reg [CW-1:0] baud_count;
    reg [2:0] bit_index;
    reg [7:0] shift_byte, byte_data;
    reg byte_valid, frame_error;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=0; baud_count<=0; bit_index<=0; shift_byte<=0;
            byte_data<=0; byte_valid<=0; frame_error<=0;
        end else begin
            byte_valid<=0; frame_error<=0;
            case(state)
                0: if(!rx_sync) begin state<=1; baud_count<=BIT_TICKS/2-1; end
                1: if(baud_count!=0) baud_count<=baud_count-1'b1;
                   else if(!rx_sync) begin state<=2; bit_index<=0; baud_count<=BIT_TICKS-1; end
                   else state<=0;
                2: if(baud_count!=0) baud_count<=baud_count-1'b1;
                   else begin
                       shift_byte[bit_index]<=rx_sync; baud_count<=BIT_TICKS-1;
                       if(bit_index==7) state<=3;
                       else bit_index<=bit_index+1'b1;
                   end
                3: if(baud_count!=0) baud_count<=baud_count-1'b1;
                   else begin
                       state<=0;
                       if(rx_sync) begin byte_data<=shift_byte; byte_valid<=1; end
                       else frame_error<=1;
                   end
            endcase
        end
    end
    reg [2:0] index;
    reg [7:0] hh, mm, ss, ms_low, ms_high, checksum;
    reg [TW-1:0] timeout_count;
    wire fields_valid = hh[3:0]<=9 && hh[7:4]<=2 && hh<=8'h23 &&
                        mm[3:0]<=9 && mm[7:4]<=5 &&
                        ss[3:0]<=9 && ss[7:4]<=5 && {ms_high,ms_low}<16'd1000;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            index<=0; hh<=0; mm<=0; ss<=0; ms_low<=0; ms_high<=0;
            checksum<=0; timeout_count<=0; sync_valid<=0; sync_bcd<=0; sync_ms<=0;
        end else begin
            sync_valid<=0;
            if(frame_error) begin index<=0; timeout_count<=0; end
            else if(byte_valid) begin
                timeout_count<=0;
                case(index)
                    0: if(byte_data==8'haa) index<=1;
                    1: if(byte_data==8'h55) begin index<=2; checksum<=0; end
                       else if(byte_data!=8'haa) index<=0;
                    2: begin hh<=byte_data; checksum<=byte_data; index<=3; end
                    3: begin mm<=byte_data; checksum<=checksum^byte_data; index<=4; end
                    4: begin ss<=byte_data; checksum<=checksum^byte_data; index<=5; end
                    5: begin ms_low<=byte_data; checksum<=checksum^byte_data; index<=6; end
                    6: begin ms_high<=byte_data; checksum<=checksum^byte_data; index<=7; end
                    7: begin
                        index<=0;
                        if(byte_data==checksum && fields_valid) begin
                            sync_bcd<={hh,mm,ss}; sync_ms<={ms_high[1:0],ms_low};
                            sync_valid<=1;
                        end
                    end
                endcase
            end else if(index!=0) begin
                if(timeout_count==TIMEOUT_TICKS-1) begin index<=0; timeout_count<=0; end
                else timeout_count<=timeout_count+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
