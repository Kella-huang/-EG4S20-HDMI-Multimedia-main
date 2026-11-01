`default_nettype none

// 16 selected DFT bins, N=256, 48 kHz. One shared 28x18 signed multiplier.
// Streaming Goertzel + Hann window; no sample/work BRAM and no audio feedback.
// First difference removes DC; per-bin inverse gain compensates its response.
// Samples must be consecutive within each block: an unexpected overrun aborts
// VISUAL analysis only. Delivered PCM, readers and pause logic are untouched.
module audio_spectrum_goertzel(
    input wire clk,rst,enable,sample_valid,frame_swap,
    input wire [23:0] pcm_left,
    output reg [95:0] display_bars,
    output reg spectrum_valid
);
    localparam CLEAR=0,CAP=1,WINDOW=2,WINDOW_WAIT=3,MUL=4,UPDATE=5,
        OUT_REAL=6,OUT_IMAG=7,OUT_GAIN=8,OUT_STORE=9,PUBLISH=10;
    reg [3:0] state,band;
    reg [7:0] index;
    reg signed [15:0] previous,input_delta,windowed;
    reg have_previous;
    (* ram_style="dram" *) reg [55:0] history[0:15];
    wire signed [27:0] s1=history[band][55:28];
    wire signed [27:0] s2=history[band][27:0];
    reg signed [27:0] real_result;
    reg [95:0] pending_bars;
    wire signed [15:0] input_half=$signed(pcm_left[23:8])>>>1;
    wire signed [17:0] recurrence,cosine,sine,compensation;
    wire [15:0] hann;
    audio_spectrum_coeffs coeffs(.band(band),.window_index(index),
        .recurrence(recurrence),.cosine(cosine),.sine(sine),
        .compensation(compensation),.hann(hann));
    reg signed [27:0] mul_a;
    reg signed [17:0] mul_b;
    (* dsp_style="yes" *) reg signed [45:0] product;
    wire signed [27:0] product_q16=product>>>16;
    wire signed [27:0] imaginary=product_q16;
    wire [27:0] abs_real=real_result[27] ? -real_result : real_result;
    wire [27:0] abs_imag=imaginary[27] ? -imaginary : imaginary;
    wire [28:0] output_magnitude={1'b0,abs_real}+{1'b0,abs_imag};
    always @* begin
        mul_a=s1;mul_b=recurrence;
        case(state)
            WINDOW:begin mul_a={{12{input_delta[15]}},input_delta};mul_b={2'b00,hann};end
            OUT_REAL:begin mul_a=s2;mul_b=cosine;end
            OUT_IMAG:begin mul_a=s2;mul_b=sine;end
            OUT_GAIN:begin mul_a=output_magnitude>>8;mul_b=compensation;end
            default:begin end
        endcase
    end
    always @(posedge clk) product<=mul_a*mul_b;
    wire signed [27:0] next_history={{12{windowed[15]}},windowed}+product_q16-s2;
    // Small 16x56 distributed RAM. Explicit sequential clearing, no reset loop.
    always @(posedge clk) begin
        if(!rst && enable) begin
            if(state==CLEAR) history[band]<=0;
            else if(state==UPDATE) history[band]<={next_history,s1};
        end
    end
    function [5:0] to_height;
        input [27:0] v;
        integer k;
        reg [7:0] h;
        begin
            h=0;
            for(k=0;k<28;k=k+1) if(v[k]) h=(k+1)*4;
            to_height=h>=64 ? 6'd63 : h[5:0];
        end
    endfunction
    wire [27:0] corrected_magnitude=product>>>10;
    wire [5:0] raw_height=to_height(corrected_magnitude);
    reg [5:0] old_height;
    always @* begin
        case(band)
            0:old_height=display_bars[5:0];1:old_height=display_bars[11:6];
            2:old_height=display_bars[17:12];3:old_height=display_bars[23:18];
            4:old_height=display_bars[29:24];5:old_height=display_bars[35:30];
            6:old_height=display_bars[41:36];7:old_height=display_bars[47:42];
            8:old_height=display_bars[53:48];9:old_height=display_bars[59:54];
            10:old_height=display_bars[65:60];11:old_height=display_bars[71:66];
            12:old_height=display_bars[77:72];13:old_height=display_bars[83:78];
            14:old_height=display_bars[89:84];15:old_height=display_bars[95:90];
        endcase
    end
    wire [5:0] new_height=raw_height>=old_height ? raw_height :
        ({1'b0,old_height}>{1'b0,raw_height}+7'd4 ? old_height-6'd4 : raw_height);
    genvar b;
    generate for(b=0;b<16;b=b+1) begin: height_registers
        always @(posedge clk or posedge rst) begin
            if(rst) pending_bars[b*6 +:6]<=0;
            else if(!enable) pending_bars[b*6 +:6]<=0;
            else if(state==OUT_STORE && band==b && !sample_valid)
                pending_bars[b*6 +:6]<=new_height;
        end
    end endgenerate
    // Difference follows EVERY valid sample, even when visualization is idle.
    // This is an analysis-only filter; no transformed sample leaves this block.
    always @(posedge clk or posedge rst) begin
        if(rst) begin previous<=0;have_previous<=0;end
        else if(!enable) begin previous<=0;have_previous<=0;end
        else if(sample_valid) begin previous<=input_half;have_previous<=1;end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=CLEAR;band<=0;index<=0;input_delta<=0;windowed<=0;
            real_result<=0;display_bars<=0;spectrum_valid<=0;
        end else if(!enable) begin
            state<=CLEAR;band<=0;index<=0;input_delta<=0;windowed<=0;
            real_result<=0;display_bars<=0;spectrum_valid<=0;
        end else if(sample_valid && state!=CAP && state!=PUBLISH && state!=CLEAR) begin
            // Drop an incomplete VISUAL block if input rate exceeds processing.
            // Retain the previously published spectrum until a complete block.
            state<=CLEAR;band<=0;index<=0;
        end else case(state)
            CLEAR:begin
                band<=band+1'b1;
                if(band==15) begin state<=CAP;index<=0;end
            end
            CAP:if(sample_valid) begin
                input_delta<=have_previous ? input_half-previous : 16'd0;
                band<=0;state<=WINDOW;
            end
            WINDOW:state<=WINDOW_WAIT;
            WINDOW_WAIT:begin windowed<=product>>>15;state<=MUL;end
            MUL:state<=UPDATE;
            UPDATE:begin
                band<=band+1'b1;state<=MUL;
                if(band==15) begin
                    index<=index+1'b1;state<=CAP;
                    if(index==255) begin band<=0;state<=OUT_REAL;end
                end
            end
            OUT_REAL:state<=OUT_IMAG;
            OUT_IMAG:begin real_result<=s1-product_q16;state<=OUT_GAIN;end
            OUT_GAIN:state<=OUT_STORE;
            OUT_STORE:begin
                band<=band+1'b1;state<=OUT_REAL;
                if(band==15) state<=PUBLISH;
            end
            PUBLISH:if(frame_swap) begin
                display_bars<=pending_bars;spectrum_valid<=1;
                band<=0;state<=CLEAR;
            end
            default:begin state<=CLEAR;band<=0;index<=0;end
        endcase
    end
endmodule
`default_nettype wire
