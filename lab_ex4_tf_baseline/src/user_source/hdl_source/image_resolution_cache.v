`default_nettype none
// Sideband metadata only: never stalls image loading or cached switching.
// BMP dimensions are <=1024x768. Convert eleven binary bits to four BCD
// digits while the scaler is setting up, then publish only with a good frame.
module image_resolution_cache #(parameter integer STORE_BANKS=1)(
    input wire clk,rst,meta_valid,commit,
    input wire [1:0] bank,
    input wire [15:0] source_width,source_height,
    output wire [127:0] bank_bcd,
    output reg [3:0] bank_valid,
    input wire invalidate,
    output wire [31:0] converted_bcd,
    output wire converted_valid
);
    reg [10:0] width_shift;
    reg [9:0] height_shift;
    // Accepted headers are bounded by the existing 1024x768 parser.
    // Width's thousands digit is only 0/1; height has no thousands digit.
    reg [12:0] width_bcd;
    reg [10:0] height_bcd;
    reg [3:0] left;
    reg [1:0] pending_bank;
    reg converted;
    function [15:0] adjust;
        input [15:0] value;
        integer digit;
        begin
            adjust=value;
            for(digit=0;digit<4;digit=digit+1)
                if(value[digit*4+:4]>=5) adjust[digit*4+:4]=value[digit*4+:4]+4'd3;
        end
    endfunction
    wire [15:0] adjusted_width=adjust({3'b0,width_bcd}),adjusted_height=adjust({5'b0,height_bcd});
    wire [31:0] packed_bcd={3'b0,width_bcd,5'b0,height_bcd};
    assign converted_bcd=packed_bcd;
    assign converted_valid=converted && pending_bank==bank;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            bank_valid<=0;width_shift<=0;height_shift<=0;
            width_bcd<=0;height_bcd<=0;left<=0;pending_bank<=0;converted<=0;
        end else if(invalidate) begin
            // SD-init loss only invalidates the data. Keep the same async
            // reset control set as the existing image loader for packing.
            bank_valid<=0;left<=0;converted<=0;
        end else begin
            if(meta_valid) begin
                width_shift<=source_width[10:0];height_shift<=source_height[9:0];
                width_bcd<=0;height_bcd<=0;left<=11;pending_bank<=bank;converted<=0;
            end else if(left!=0) begin
                width_bcd<={adjusted_width[11:0],width_shift[10]};
                // The first of eleven rounds is the known zero height bit.
                height_bcd<={adjusted_height[9:0],left==11 ? 1'b0 : height_shift[9]};
                width_shift<=width_shift<<1;
                if(left!=11) height_shift<=height_shift<<1;
                left<=left-1'b1;
                if(left==1) converted<=1;
            end
            if(commit && converted && pending_bank==bank) begin
                bank_valid[bank]<=1;
            end
        end
    end
    generate if(STORE_BANKS) begin: private_banks
        reg [127:0] data;
        assign bank_bcd=data;
        always @(posedge clk or posedge rst) begin
            if(rst) data<=0;
            else if(!invalidate && commit && converted_valid) begin
                case(bank)
                    0:data[31:0]<=packed_bcd;1:data[63:32]<=packed_bcd;
                    2:data[95:64]<=packed_bcd;3:data[127:96]<=packed_bcd;
                endcase
            end
        end
    end else begin: shared_banks
        assign bank_bcd=0;
    end endgenerate
endmodule
`default_nettype wire
