`default_nettype none
// Audio and ACR are synchronous to APUG092's 25 MHz pixel input.
// 48000 ticks/25000000 clocks exactly; no extra audio PLL or I2S round trip.
module hdmi_pcm_clock #(
    parameter integer PIXEL_HZ=25_000_000,
    parameter integer SAMPLE_HZ=48_000
)(input wire clk,rst,output reg sample_tick,acr_valid,
  output wire [19:0] acr_n,acr_cts,output wire [23:0] test_pcm);
    reg [31:0] phase;
    reg [5:0] acr_count,tone_phase;
    reg [15:0] tone_time;
    reg signed [15:0] tone;
    assign acr_n=20'd6144;
    assign acr_cts=PIXEL_HZ/1000;
    assign test_pcm=tone_time<9600 ? {tone,8'd0} : 24'd0;
    always @* begin
        case(tone_phase)
            0:tone=0;1:tone=535;2:tone=1060;3:tone=1567;
            4:tone=2048;5:tone=2493;6:tone=2896;7:tone=3250;
            8:tone=3547;9:tone=3784;10:tone=3956;11:tone=4061;
            12:tone=4096;13:tone=4061;14:tone=3956;15:tone=3784;
            16:tone=3547;17:tone=3250;18:tone=2896;19:tone=2493;
            20:tone=2048;21:tone=1567;22:tone=1060;23:tone=535;
            24:tone=0;25:tone=-535;26:tone=-1060;27:tone=-1567;
            28:tone=-2048;29:tone=-2493;30:tone=-2896;31:tone=-3250;
            32:tone=-3547;33:tone=-3784;34:tone=-3956;35:tone=-4061;
            36:tone=-4096;37:tone=-4061;38:tone=-3956;39:tone=-3784;
            40:tone=-3547;41:tone=-3250;42:tone=-2896;43:tone=-2493;
            44:tone=-2048;45:tone=-1567;46:tone=-1060;47:tone=-535;
            default:tone=0;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin phase<=0;sample_tick<=0;acr_valid<=0;acr_count<=0;tone_phase<=0;tone_time<=0;end
        else begin
            sample_tick<=0;acr_valid<=0;
            if(phase>=PIXEL_HZ-SAMPLE_HZ) begin phase<=phase-(PIXEL_HZ-SAMPLE_HZ);sample_tick<=1;end
            else phase<=phase+SAMPLE_HZ;
            if(sample_tick) begin
                if(acr_count==47) begin acr_count<=0;acr_valid<=1;end else acr_count<=acr_count+1'b1;
                tone_phase<=tone_phase==47 ? 0 : tone_phase+1'b1;
                tone_time<=tone_time==47999 ? 0 : tone_time+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
