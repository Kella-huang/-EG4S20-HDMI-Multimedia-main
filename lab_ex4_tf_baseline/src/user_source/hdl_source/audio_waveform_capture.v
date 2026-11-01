`default_nettype none

// Observe delivered PCM without ready/backpressure. Four 48 kHz samples per
// min/max column, 256 columns = 21.33 ms. Publish snapshots in vertical blank.
// A pending snapshot pauses VISUAL capture only. Distributed snapshot RAM
// leaves the final block RAM available for the lossless video row history.
module audio_waveform_capture (
    input wire clk, rst, enable, sample_valid, frame_swap,
    input wire [23:0] pcm_left, pcm_right,
    input wire [7:0] read_index,
    output reg [15:0] read_point,
    output reg snapshot_valid,
    output reg [7:0] level
);
    (* ram_style="dram" *) reg [15:0] points [0:511];
    reg write_bank, read_bank, pending;
    reg [7:0] point_index;
    reg [1:0] group_index;
    reg [5:0] group_min, group_max;
    reg [15:0] peak, pending_peak;
    // Signed, left-aligned PCM16. Widen subtraction to handle -32768.
    wire [6:0] y_full = 7'd32 - {pcm_left[23], pcm_left[23:18]};
    wire [5:0] sample_y = y_full[6] ? 6'd63 : y_full[5:0];
    wire [15:0] magnitude_l = pcm_left[23] ? -pcm_left[23:8] : pcm_left[23:8];
    wire [15:0] magnitude_r = pcm_right[23] ? -pcm_right[23:8] : pcm_right[23:8];
    wire [15:0] sample_peak = magnitude_l > magnitude_r ? magnitude_l : magnitude_r;
    wire [15:0] next_peak = sample_peak > peak ? sample_peak : peak;
    wire [5:0] next_min = (group_index == 0 || sample_y < group_min) ? sample_y : group_min;
    wire [5:0] next_max = (group_index == 0 || sample_y > group_max) ? sample_y : group_max;
    wire write_point = !rst && enable && sample_valid && !pending && group_index == 3;
    // Memory/read register have no reset; the same synchronous read latency
    // is retained when mapping the snapshot to distributed RAM.
    // snapshot_valid hides uninitialized data until all columns are written.
    always @(posedge clk) begin
        if (write_point)
            points[{write_bank, point_index}] <= {2'b00, next_max, 2'b00, next_min};
        read_point <= points[{read_bank, read_index}];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            write_bank<=1; read_bank<=0; pending<=0;
            point_index<=0; group_index<=0; group_min<=32; group_max<=32;
            peak<=0; pending_peak<=0; snapshot_valid<=0; level<=0;
        end else if (!enable) begin
            write_bank<=1; read_bank<=0; pending<=0;
            point_index<=0; group_index<=0; group_min<=32; group_max<=32;
            peak<=0; pending_peak<=0; snapshot_valid<=0; level<=0;
        end else if (pending) begin
            if (frame_swap) begin
                read_bank<=write_bank; write_bank<=read_bank;
                snapshot_valid<=1;
                level<=pending_peak[15] ? 8'd255 : pending_peak[14:7];
                pending<=0;
            end
        end else if (sample_valid) begin
            peak<=next_peak;
            group_min<=next_min; group_max<=next_max;
            group_index<=group_index+1'b1;
            if (group_index == 3) begin
                point_index<=point_index+1'b1;
                if (point_index == 255) begin
                    pending<=1; pending_peak<=next_peak; peak<=0;
                end
            end
        end
    end
endmodule
`default_nettype wire
