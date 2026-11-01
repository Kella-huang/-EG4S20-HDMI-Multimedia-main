`default_nettype none
// Three cross targets: (32,48), (288,48), (32,176).
// Raw-domain button thresholds avoid framebuffer RAM, multipliers and dividers.
module touch_panel_control(
    input wire clk,rst,sample_valid,sample_down,
    input wire [11:0] raw_u,raw_v,
    output reg [1:0] calibration,
    output reg calibration_error,
    output reg command_valid,
    output reg [3:0] command
);
    reg stable_down;
    reg [1:0] debounce;
    reg [11:0] last_u,last_v,u0,v0,u1,v1;
    reg swap_axes,flip_x,flip_y;
    reg [11:0] x80,x160,x240,y48,y112,y176;
    reg [3:0] armed;
    wire [11:0] px0=swap_axes?v0:u0;
    wire [11:0] px1=swap_axes?v1:u1;
    wire [11:0] py0=swap_axes?u0:v0;
    wire [11:0] py2=swap_axes?last_u:last_v;
    wire [11:0] dx=(px1>px0)?px1-px0:px0-px1;
    wire [11:0] dy=(py2>py0)?py2-py0:py0-py2;
    wire [11:0] base_x=flip_x?12'd4095-px0:px0;
    wire [11:0] base_y=flip_y?12'd4095-py0:py0;
    wire [11:0] ru=swap_axes?last_v:last_u;
    wire [11:0] rv=swap_axes?last_u:last_v;
    wire [11:0] x=flip_x?12'd4095-ru:ru;
    wire [11:0] y=flip_y?12'd4095-rv:rv;
    wire [1:0] col=x<x80?0:x<x160?1:x<x240?2:3;
    wire [1:0] row=y<y112?0:y<y176?1:2;
    wire [3:0] hit=(y<y48)?4'd0:({row,col}+4'd1);
    wire [11:0] du=(u1>u0)?u1-u0:u0-u1;
    wire [11:0] dv=(v1>v0)?v1-v0:v0-v1;
    reg [1:0] finish;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            calibration<=0;calibration_error<=0;command_valid<=0;command<=0;
            stable_down<=0;debounce<=0;last_u<=0;last_v<=0;
            u0<=0;v0<=0;u1<=0;v1<=0;swap_axes<=0;flip_x<=0;flip_y<=0;
            x80<=0;x160<=0;x240<=0;y48<=0;y112<=0;y176<=0;
            armed<=0;finish<=0;
        end else begin
            command_valid<=0;
            // Spread calibration arithmetic over cycles for area and timing.
            if(finish==1) begin
                swap_axes<=dv>du;finish<=2;
            end else if(finish==2) begin
                flip_x<=px1<px0;flip_y<=py2<py0;finish<=3;
            end else if(finish==3) begin
                finish<=0;
                if(dx<600 || dy<600) begin calibration<=0;calibration_error<=1;end
                else begin
                    // x: base+3/16, 1/2, 13/16 horizontal calibration span.
                    x80<=base_x+(dx>>3)+(dx>>4);
                    x160<=base_x+(dx>>1);
                    x240<=base_x+(dx>>1)+(dx>>2)+(dx>>4);
                    y48<=base_y;y112<=base_y+(dy>>1);y176<=base_y+dy;
                    calibration<=3;calibration_error<=0;
                end
            end
            if(sample_valid && finish==0) begin
                if(sample_down) begin last_u<=raw_u;last_v<=raw_v;end
                if(sample_down==stable_down) begin
                    debounce<=0;
                    // Moving out of a pressed button cancels that click.
                    if(stable_down && calibration==3 && armed!=0 && hit!=armed) armed<=0;
                end else if(debounce==1) begin
                    stable_down<=sample_down;debounce<=0;
                    if(sample_down) begin
                        if(calibration==3) armed<=hit;
                    end else begin
                        if(calibration==0) begin u0<=last_u;v0<=last_v;calibration<=1;end
                        else if(calibration==1) begin u1<=last_u;v1<=last_v;calibration<=2;end
                        else if(calibration==2) finish<=1;
                        else if(armed!=0 && hit==armed) begin
                            if(armed==12) begin calibration<=0;calibration_error<=0;end
                            else begin command<=armed;command_valid<=1;end
                        end
                        armed<=0;
                    end
                end else debounce<=debounce+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
