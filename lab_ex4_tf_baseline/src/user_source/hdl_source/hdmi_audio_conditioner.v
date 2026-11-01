`default_nettype none
// 48kHz stereo sample/hold with a power-of-two crossfade on mute/resume.
// No amplitude threshold: continuous active PCM, including quiet samples,
// is bit-exact at unity after the source transition has completed.
// PCM input is signed 16-bit left-aligned in the HDMI 24-bit word.
module hdmi_audio_conditioner #(parameter integer FADE_SAMPLES=128)(
    input wire clk,rst,sample_tick,source_active,
    input wire [23:0] source_left,source_right,
    output reg audio_valid,
    output reg [23:0] audio_left,audio_right
);
    reg gate_open;
    localparam integer FADE_SHIFT=$clog2(FADE_SAMPLES);
    localparam integer MIX_BITS=19+FADE_SHIFT;
    reg [FADE_SHIFT:0] blend;
    reg signed [15:0] anchor_left,anchor_right;
    wire signed [15:0] raw_left=source_left[23:8];
    wire signed [15:0] raw_right=source_right[23:8];
    reg wanted;
    reg [FADE_SHIFT:0] next_blend;
    reg signed [15:0] next_anchor_left,next_anchor_right,target_left,target_right;
    reg signed [FADE_SHIFT+1:0] weight_new,weight_old;
    reg signed [MIX_BITS-1:0] mixed_left,mixed_right;
    wire signed [MIX_BITS-1:0] scaled_left,scaled_right;
    generate if(FADE_SHIFT>=8) begin: reduce_fraction
        assign scaled_left=mixed_left >>> (FADE_SHIFT-8);
        assign scaled_right=mixed_right >>> (FADE_SHIFT-8);
    end else begin: add_fraction
        assign scaled_left=mixed_left <<< (8-FADE_SHIFT);
        assign scaled_right=mixed_right <<< (8-FADE_SHIFT);
    end endgenerate
    always @* begin
        wanted=source_active;
        next_anchor_left=anchor_left;next_anchor_right=anchor_right;
        next_blend=blend==FADE_SAMPLES ? FADE_SAMPLES : blend+1'b1;
        if(wanted!=gate_open) begin
            // Begin at the last delivered sample, including interrupted fades.
            next_anchor_left=$signed(audio_left[23:8]);
            next_anchor_right=$signed(audio_right[23:8]);
            next_blend=1;
        end
        target_left=source_active ? raw_left : 16'sd0;
        target_right=source_active ? raw_right : 16'sd0;
        weight_new=$signed({1'b0,next_blend});
        weight_old=FADE_SAMPLES-weight_new;
        mixed_left=target_left*weight_new+next_anchor_left*weight_old;
        mixed_right=target_right*weight_new+next_anchor_right*weight_old;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            audio_valid<=0;audio_left<=0;audio_right<=0;gate_open<=0;
            blend<=FADE_SAMPLES;anchor_left<=0;anchor_right<=0;
        end else begin
            // Continue sending digital silence at 48kHz. Never stop HDMI audio
            // packet cadence just because the source is paused or silent.
            audio_valid<=sample_tick;
            if(sample_tick) begin
                gate_open<=wanted;blend<=next_blend;
                anchor_left<=next_anchor_left;anchor_right<=next_anchor_right;
                // Sum /FADE_SAMPLES *256. A convex mix cannot overflow PCM24.
                audio_left<=scaled_left[23:0];
                audio_right<=scaled_right[23:0];
            end
        end
    end
endmodule
`default_nettype wire
