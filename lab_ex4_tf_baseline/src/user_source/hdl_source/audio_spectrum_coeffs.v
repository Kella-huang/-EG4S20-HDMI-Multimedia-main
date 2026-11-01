`default_nettype none
// Generated Q16 recurrence/cos/sin, Q10 first-difference gain compensation.
// Selected DFT frequency points, not sums of contiguous frequency bands.
module audio_spectrum_coeffs(input wire [3:0] band,input wire [7:0] window_index,
    output reg signed [17:0] recurrence,cosine,sine,compensation,
    output reg [15:0] hann);
    always @* begin
        recurrence=0;cosine=0;sine=0;compensation=0;
        case(band)
            4'd0:begin recurrence=18'sd131033;cosine=18'sd65516;sine=18'sd1608;compensation=18'sd41723;end // 187.5 Hz
            4'd1:begin recurrence=18'sd130914;cosine=18'sd65457;sine=18'sd3216;compensation=18'sd20863;end // 375 Hz
            4'd2:begin recurrence=18'sd130717;cosine=18'sd65358;sine=18'sd4821;compensation=18'sd13910;end // 562.5 Hz
            4'd3:begin recurrence=18'sd130441;cosine=18'sd65220;sine=18'sd6424;compensation=18'sd10435;end // 750 Hz
            4'd4:begin recurrence=18'sd130086;cosine=18'sd65043;sine=18'sd8022;compensation=18'sd8350;end // 937.5 Hz
            4'd5:begin recurrence=18'sd129653;cosine=18'sd64827;sine=18'sd9616;compensation=18'sd6960;end // 1125 Hz
            4'd6:begin recurrence=18'sd128553;cosine=18'sd64277;sine=18'sd12785;compensation=18'sd5224;end // 1500 Hz
            4'd7:begin recurrence=18'sd127144;cosine=18'sd63572;sine=18'sd15924;compensation=18'sd4183;end // 1875 Hz
            4'd8:begin recurrence=18'sd123410;cosine=18'sd61705;sine=18'sd22078;compensation=18'sd2995;end // 2625 Hz
            4'd9:begin recurrence=18'sd118488;cosine=18'sd59244;sine=18'sd28020;compensation=18'sd2337;end // 3375 Hz
            4'd10:begin recurrence=18'sd105278;cosine=18'sd52639;sine=18'sd39040;compensation=18'sd1632;end // 4875 Hz
            4'd11:begin recurrence=18'sd80640;cosine=18'sd40320;sine=18'sd51665;compensation=18'sd1167;end // 6937.5 Hz
            4'd12:begin recurrence=18'sd41115;cosine=18'sd20557;sine=18'sd62228;compensation=18'sd874;end // 9562.5 Hz
            4'd13:begin recurrence=-18'sd16045;cosine=-18'sd8022;sine=18'sd65043;compensation=18'sd683;end // 12937.5 Hz
            4'd14:begin recurrence=-18'sd83151;cosine=-18'sd41576;sine=18'sd50660;compensation=18'sd566;end // 17250 Hz
            4'd15:begin recurrence=-18'sd126324;cosine=-18'sd63162;sine=18'sd17479;compensation=18'sd517;end // 21937.5 Hz
        endcase
    end
    wire [6:0] windex=window_index[7] ? 8'd255-window_index : window_index;
    always @* begin
        case(windex)
            7'd0:hann=16'd0;
            7'd1:hann=16'd5;
            7'd2:hann=16'd20;
            7'd3:hann=16'd45;
            7'd4:hann=16'd80;
            7'd5:hann=16'd124;
            7'd6:hann=16'd179;
            7'd7:hann=16'd243;
            7'd8:hann=16'd317;
            7'd9:hann=16'd401;
            7'd10:hann=16'd495;
            7'd11:hann=16'd598;
            7'd12:hann=16'd711;
            7'd13:hann=16'd833;
            7'd14:hann=16'd965;
            7'd15:hann=16'd1106;
            7'd16:hann=16'd1257;
            7'd17:hann=16'd1416;
            7'd18:hann=16'd1585;
            7'd19:hann=16'd1763;
            7'd20:hann=16'd1949;
            7'd21:hann=16'd2145;
            7'd22:hann=16'd2349;
            7'd23:hann=16'd2561;
            7'd24:hann=16'd2782;
            7'd25:hann=16'd3011;
            7'd26:hann=16'd3249;
            7'd27:hann=16'd3494;
            7'd28:hann=16'd3747;
            7'd29:hann=16'd4008;
            7'd30:hann=16'd4276;
            7'd31:hann=16'd4552;
            7'd32:hann=16'd4834;
            7'd33:hann=16'd5124;
            7'd34:hann=16'd5421;
            7'd35:hann=16'd5724;
            7'd36:hann=16'd6034;
            7'd37:hann=16'd6350;
            7'd38:hann=16'd6672;
            7'd39:hann=16'd7000;
            7'd40:hann=16'd7334;
            7'd41:hann=16'd7673;
            7'd42:hann=16'd8018;
            7'd43:hann=16'd8367;
            7'd44:hann=16'd8722;
            7'd45:hann=16'd9081;
            7'd46:hann=16'd9444;
            7'd47:hann=16'd9812;
            7'd48:hann=16'd10184;
            7'd49:hann=16'd10559;
            7'd50:hann=16'd10938;
            7'd51:hann=16'd11321;
            7'd52:hann=16'd11706;
            7'd53:hann=16'd12094;
            7'd54:hann=16'd12485;
            7'd55:hann=16'd12879;
            7'd56:hann=16'd13274;
            7'd57:hann=16'd13671;
            7'd58:hann=16'd14070;
            7'd59:hann=16'd14470;
            7'd60:hann=16'd14872;
            7'd61:hann=16'd15274;
            7'd62:hann=16'd15677;
            7'd63:hann=16'd16081;
            7'd64:hann=16'd16484;
            7'd65:hann=16'd16888;
            7'd66:hann=16'd17291;
            7'd67:hann=16'd17694;
            7'd68:hann=16'd18096;
            7'd69:hann=16'd18497;
            7'd70:hann=16'd18897;
            7'd71:hann=16'd19295;
            7'd72:hann=16'd19691;
            7'd73:hann=16'd20085;
            7'd74:hann=16'd20477;
            7'd75:hann=16'd20867;
            7'd76:hann=16'd21254;
            7'd77:hann=16'd21638;
            7'd78:hann=16'd22019;
            7'd79:hann=16'd22396;
            7'd80:hann=16'd22770;
            7'd81:hann=16'd23139;
            7'd82:hann=16'd23505;
            7'd83:hann=16'd23866;
            7'd84:hann=16'd24223;
            7'd85:hann=16'd24575;
            7'd86:hann=16'd24922;
            7'd87:hann=16'd25264;
            7'd88:hann=16'd25601;
            7'd89:hann=16'd25932;
            7'd90:hann=16'd26257;
            7'd91:hann=16'd26576;
            7'd92:hann=16'd26889;
            7'd93:hann=16'd27195;
            7'd94:hann=16'd27495;
            7'd95:hann=16'd27789;
            7'd96:hann=16'd28075;
            7'd97:hann=16'd28354;
            7'd98:hann=16'd28626;
            7'd99:hann=16'd28891;
            7'd100:hann=16'd29148;
            7'd101:hann=16'd29397;
            7'd102:hann=16'd29638;
            7'd103:hann=16'd29871;
            7'd104:hann=16'd30096;
            7'd105:hann=16'd30313;
            7'd106:hann=16'd30521;
            7'd107:hann=16'd30721;
            7'd108:hann=16'd30912;
            7'd109:hann=16'd31094;
            7'd110:hann=16'd31267;
            7'd111:hann=16'd31432;
            7'd112:hann=16'd31587;
            7'd113:hann=16'd31732;
            7'd114:hann=16'd31869;
            7'd115:hann=16'd31996;
            7'd116:hann=16'd32114;
            7'd117:hann=16'd32222;
            7'd118:hann=16'd32320;
            7'd119:hann=16'd32409;
            7'd120:hann=16'd32488;
            7'd121:hann=16'd32557;
            7'd122:hann=16'd32617;
            7'd123:hann=16'd32666;
            7'd124:hann=16'd32706;
            7'd125:hann=16'd32736;
            7'd126:hann=16'd32756;
            7'd127:hann=16'd32766;
            default:hann=0;
        endcase
    end
endmodule
`default_nettype wire
