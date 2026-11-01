`default_nettype none

// Video-clock timekeeper with atomic PC synchronization (BCD + milliseconds).
// time_valid stays low until the first validated packet arrives.
module osd_timekeeper_25m #(
    parameter integer CLK_HZ = 25_000_000,
    parameter [3:0] START_HOUR_TENS = 4'd1,
    parameter [3:0] START_HOUR_ONES = 4'd2,
    parameter [3:0] START_MIN_TENS  = 4'd3,
    parameter [3:0] START_MIN_ONES  = 4'd4,
    parameter [3:0] START_SEC_TENS  = 4'd5,
    parameter [3:0] START_SEC_ONES  = 4'd6
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       sync_valid,
    input  wire [23:0] sync_bcd,
    input  wire [9:0] sync_ms,
    output reg        time_valid,
    output reg  [3:0] hour_tens,
    output reg  [3:0] hour_ones,
    output reg  [3:0] min_tens,
    output reg  [3:0] min_ones,
    output reg  [3:0] sec_tens,
    output reg  [3:0] sec_ones
);
    localparam integer TICK_WIDTH = (CLK_HZ <= 2) ? 1 : $clog2(CLK_HZ);
    reg [TICK_WIDTH-1:0] tick_count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            time_valid <= 1'b0;
            tick_count <= {TICK_WIDTH{1'b0}};
            hour_tens  <= START_HOUR_TENS;
            hour_ones  <= START_HOUR_ONES;
            min_tens   <= START_MIN_TENS;
            min_ones   <= START_MIN_ONES;
            sec_tens   <= START_SEC_TENS;
            sec_ones   <= START_SEC_ONES;
        end else if (sync_valid) begin
            time_valid <= 1'b1;
            {hour_tens,hour_ones,min_tens,min_ones,sec_tens,sec_ones} <= sync_bcd;
            tick_count <= sync_ms * (CLK_HZ / 1000);
        end else if (tick_count == CLK_HZ - 1) begin
            tick_count <= {TICK_WIDTH{1'b0}};

            if (sec_ones != 4'd9) begin
                sec_ones <= sec_ones + 4'd1;
            end else begin
                sec_ones <= 4'd0;
                if (sec_tens != 4'd5) begin
                    sec_tens <= sec_tens + 4'd1;
                end else begin
                    sec_tens <= 4'd0;
                    if (min_ones != 4'd9) begin
                        min_ones <= min_ones + 4'd1;
                    end else begin
                        min_ones <= 4'd0;
                        if (min_tens != 4'd5) begin
                            min_tens <= min_tens + 4'd1;
                        end else begin
                            min_tens <= 4'd0;
                            if (hour_tens == 4'd2 && hour_ones == 4'd3) begin
                                hour_tens <= 4'd0;
                                hour_ones <= 4'd0;
                            end else if (hour_ones != 4'd9) begin
                                hour_ones <= hour_ones + 4'd1;
                            end else if (hour_tens == 4'd1 && hour_ones == 4'd9) begin
                                hour_tens <= 4'd2;
                                hour_ones <= 4'd0;
                            end else begin
                                hour_tens <= hour_tens + 4'd1;
                                hour_ones <= 4'd0;
                            end
                        end
                    end
                end
            end
        end else begin
            tick_count <= tick_count + 1'b1;
        end
    end
endmodule

`default_nettype wire
