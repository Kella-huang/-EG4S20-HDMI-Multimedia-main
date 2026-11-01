`default_nettype none
// 25 MHz system domain; 500 kHz mode-0 SPI. No internally generated clocks.
module touch_xpt2046 #(
    parameter integer HALF_CYCLES=25, POLL_CYCLES=250000
)(input wire clk,rst,pen_n,miso,
  output reg sclk,cs_n,mosi,
  output reg sample_valid,sample_down,
  output reg [11:0] raw_u,raw_v);
    (* async_reg="true" *) reg [1:0] pen_sync,miso_sync;
    reg [18:0] poll;
    reg [5:0] divider;
    reg [1:0] state;
    reg [4:0] bit_index;
    reg [2:0] conversion;
    reg [23:0] tx,rx;
    reg [11:0] a,b,u_hold;
    wire [11:0] value=rx[14:3];
    function [11:0] median;
        input [11:0] x,y,z;
        begin median=(x<y)?((y<z)?y:((x<z)?z:x)):
                                   ((x<z)?x:((y<z)?z:y)); end
    endfunction
    wire [11:0] filtered=median(a,b,value);
    always @(posedge clk or posedge rst) begin
        if(rst) begin pen_sync<=3;miso_sync<=0;end
        else begin pen_sync<={pen_sync[0],pen_n};miso_sync<={miso_sync[0],miso};end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            poll<=0;divider<=0;state<=0;bit_index<=0;conversion<=0;
            tx<=0;rx<=0;a<=0;b<=0;u_hold<=0;
            sclk<=0;cs_n<=1;mosi<=0;sample_valid<=0;sample_down<=0;raw_u<=0;raw_v<=0;
        end else begin
            sample_valid<=0;
            if(poll!=0) poll<=poll-1'b1;
            case(state)
              0: if(poll==0) begin
                  poll<=POLL_CYCLES-1;
                  if(pen_sync[1]) begin sample_down<=0;sample_valid<=1;end
                  else begin conversion<=0;state<=1;divider<=0;end
              end
              1: begin
                  // Discard one conversion after switching each ADC channel.
                  cs_n<=0;sclk<=0;mosi<=1;
                  tx<=conversion[2]?24'h900000:24'hd00000;
                  rx<=0;bit_index<=0;divider<=HALF_CYCLES-1;state<=2;
              end
              2: if(divider!=0) divider<=divider-1'b1;
                 else begin
                     divider<=HALF_CYCLES-1;
                     if(!sclk) begin sclk<=1;rx<={rx[22:0],miso_sync[1]};end
                     else begin
                         sclk<=0;
                         if(bit_index==23) begin cs_n<=1;mosi<=0;state<=3;end
                         else begin bit_index<=bit_index+1'b1;tx<={tx[22:0],1'b0};mosi<=tx[22];end
                     end
                 end
              3: if(divider!=0) divider<=divider-1'b1;
                 else begin
                     case(conversion[1:0])
                       1:a<=value;
                       2:b<=value;
                       3:if(!conversion[2]) u_hold<=filtered;
                     endcase
                     if(conversion==7) begin
                         // PENIRQ is only interpreted after all conversions,
                         // with PD[1:0]=00 and CS high. Bad ADC data is ignored.
                         if(!pen_sync[1] && u_hold>0 && u_hold<4095 && filtered>0 && filtered<4095) begin
                             raw_u<=u_hold;raw_v<=filtered;sample_down<=1;sample_valid<=1;
                         end
                         state<=0;
                     end else begin conversion<=conversion+1'b1;state<=1;end
                 end
            endcase
        end
    end
endmodule
`default_nettype wire
