`default_nettype none

// Coordinates for the delayed SDRAM/HDMI pixel stream.
//
// The image path already provides DE/VS aligned with vout_data after the
// video_delay pipeline.  Counting active pixels at that same point avoids
// touching the SDRAM read timing: x is zero during the horizontal blanking
// interval and y advances once when DE falls at the end of each line.
module video_osd_coord_640x480 (
    input  wire       video_clk,
    input  wire       rst,
    input  wire       vs,
    input  wire       de,
    output wire [9:0] x,
    output wire [9:0] y
);
    reg        de_d;
    reg        vs_d;
    reg [9:0]  x_r;
    reg [9:0]  y_r;

    assign x = x_r;
    assign y = y_r;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            de_d <= 1'b0;
            vs_d <= 1'b0;
            x_r  <= 10'd0;
            y_r  <= 10'd0;
        end else begin
            de_d <= de;
            vs_d <= vs;

            // VS changes in the vertical blanking interval.  Resetting here
            // makes the first active line of every frame y=0.
            if (vs != vs_d) begin
                x_r <= 10'd0;
                y_r <= 10'd0;
            end else if (!de) begin
                // Keep x at the first-pixel value throughout blanking.  At
                // the first blank cycle after a line, advance to the next
                // line before the following active pixel arrives.
                x_r <= 10'd0;
                if (de_d) begin
                    if (y_r == 10'd479)
                        y_r <= 10'd0;
                    else
                        y_r <= y_r + 10'd1;
                end
            end else begin
                if (x_r == 10'd639)
                    x_r <= 10'd0;
                else
                    x_r <= x_r + 10'd1;
            end
        end
    end
endmodule

`default_nettype wire
