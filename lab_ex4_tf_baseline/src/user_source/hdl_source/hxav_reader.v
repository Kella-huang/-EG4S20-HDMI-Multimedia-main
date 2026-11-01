`default_nettype none
// HXAV0001 v1: fixed 160x120 RGB565LE / 15fps / PCM16 stereo 48kHz.
// Two SDRAM frame banks and two PCM banks share the same ownership toggles.
// A bank is published only after CRC validation AND SDRAM write completion.
module hxav_reader #(
    parameter integer TIMEOUT_CYCLES=100_000_000
)(
    input wire clk,rst,sd_init_done,
    output reg sd_read,
    output reg [31:0] sd_addr,
    input wire [7:0] sd_data,
    input wire sd_valid,sd_end,
    output reg write_req,
    input wire write_ack,write_ready,write_finish_toggle,
    output wire write_en,
    output wire [31:0] write_data,
    output wire write_bank,
    output reg audio_we,
    output reg [12:0] audio_addr,
    output reg [31:0] audio_data,
    output reg [1:0] filled_toggle,
    input wire [1:0] released_toggle_async,
    output reg [7:0] error_code,
    output wire [3:0] status,
    output reg [6:0] load_frame
);
    localparam INIT=0,FETCH=1,RECV=2,CHECK=3,WRREQ=4,WRDROP=5,
               PROCESS=6,EXPAND=7,FINISH=8,FREE=9,FAILED=10;
    reg [3:0] state;
    reg global_header,bank,header_bad,write_done;
    reg [6:0] sector_no;
    reg [31:0] frame_lba,timeout_count;
    reg [9:0] byte_count,proc_index;
    reg [31:0] word_shift,header_crc,stored_header_crc;
    reg [31:0] video_crc,audio_crc,expected_video_crc,expected_audio_crc;
    reg [7:0] low_pixel,line_x;
    reg [9:0] out_x;
    reg [1:0] out_repeat;
    reg [11:0] audio_index;
    reg [31:0] audio_shift;
    reg [7:0] sector_mem[0:511];
    reg [15:0] line_mem[0:159];
    wire [7:0] current_byte=sector_mem[proc_index[8:0]];
    wire [15:0] pixel=line_mem[out_x[9:2]];
    wire is_header=global_header || sector_no==0;
    wire [31:0] assembled_word={sd_data,word_shift[31:8]};
    (* async_reg="true" *) reg [1:0] release_meta,release_sync;
    (* async_reg="true" *) reg ack_meta,ack_sync;
    (* async_reg="true" *) reg [2:0] finish_sync;
    wire finish_event=finish_sync[2]^finish_sync[1];
    assign status=state;
    assign write_bank=bank;
    assign write_en=(state==EXPAND) && write_ready;
    assign write_data={{pixel[15:11],pixel[15:13]},
                       {pixel[10:5],pixel[10:9]},
                       {pixel[4:0],pixel[4:2]},8'b0};
    function [31:0] crc_byte;
        input [31:0] old;
        input [7:0] data;
        reg [31:0] c;
        integer j;
        begin
            c=old^{24'd0,data};
            for(j=0;j<8;j=j+1) c=c[0] ? (c>>1)^32'hedb88320 : c>>1;
            crc_byte=c;
        end
    endfunction
    function bad_word;
        input global_h;
        input [6:0] index;
        input [31:0] value;
        begin
            bad_word=0;
            if(global_h) case(index)
                0:bad_word=value!=32'h56415848; // HXAV
                1:bad_word=value!=32'h31303030; // 0001
                2:bad_word=value!=1;
                3,4:bad_word=value!=512;
                6,30:bad_word=value!=4;
                8:bad_word=value!=160;
                9:bad_word=value!=120;
                10,12:bad_word=value!=1;
                11:bad_word=value!=15;
                13:bad_word=value!=90;
                14:bad_word=value!=48000;
                15:bad_word=value!=2;
                16:bad_word=value!=16;
                17:bad_word=value!=3200;
                18:bad_word=value!=8193;
                19:bad_word=value!=101;
                20:bad_word=value!=38400;
                21:bad_word=value!=12800;
                27:bad_word=value!=288000;
                28:bad_word=value!=128;
                29:bad_word=value!=64;
                default:bad_word=0;
            endcase
            else case(index)
                0:bad_word=value!=32'h52465641; // AVFR
                1:bad_word=value!=32'h3130304d; // M001
                2:bad_word=value!={25'd0,load_frame};
                3:bad_word=value!=load_frame*32'd3200;
                4:bad_word=value!=3200;
                5:bad_word=value!=38400;
                6:bad_word=value!=12800;
                default:bad_word=0;
            endcase
        end
    endfunction
    task fail;
        input [7:0] code;
        begin error_code<=code;state<=FAILED;write_req<=0;sd_read<=0;end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            release_meta<=0;release_sync<=0;ack_meta<=0;ack_sync<=0;finish_sync<=0;
        end else begin
            release_meta<=released_toggle_async;release_sync<=release_meta;
            ack_meta<=write_ack;ack_sync<=ack_meta;
            finish_sync<={finish_sync[1:0],write_finish_toggle};
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=INIT;global_header<=1;bank<=0;sector_no<=0;frame_lba<=8193;
            sd_read<=0;sd_addr<=8192;write_req<=0;audio_we<=0;audio_addr<=0;audio_data<=0;
            filled_toggle<=0;error_code<=0;load_frame<=0;timeout_count<=0;
            byte_count<=0;proc_index<=0;word_shift<=0;header_crc<=32'hffffffff;
            stored_header_crc<=0;header_bad<=0;video_crc<=32'hffffffff;audio_crc<=32'hffffffff;
            expected_video_crc<=0;expected_audio_crc<=0;low_pixel<=0;line_x<=0;
            out_x<=0;out_repeat<=0;audio_index<=0;audio_shift<=0;write_done<=0;
        end else begin
            sd_read<=0;audio_we<=0;
            if(finish_event) write_done<=1;
            if(state==FREE || state==FAILED || sd_valid || sd_end || write_en ||
               state==PROCESS || state==CHECK || state==FETCH) timeout_count<=0;
            else if(timeout_count<TIMEOUT_CYCLES) timeout_count<=timeout_count+1'b1;
            case(state)
                INIT:if(sd_init_done) begin sd_addr<=8192;state<=FETCH;end
                FETCH:begin
                    byte_count<=0;word_shift<=0;header_crc<=32'hffffffff;
                    stored_header_crc<=0;header_bad<=0;sd_read<=1;state<=RECV;
                end
                RECV:begin
                    if(sd_valid) begin
                        if(byte_count>=512) fail(8'he1);
                        else begin
                            sector_mem[byte_count[8:0]]<=sd_data;
                            byte_count<=byte_count+1'b1;
                            word_shift<=assembled_word;
                            if(is_header) begin
                                if(byte_count<508) header_crc<=crc_byte(header_crc,sd_data);
                                if(byte_count[1:0]==3) begin
                                    if(byte_count==511) stored_header_crc<=assembled_word;
                                    else if(bad_word(global_header,byte_count[8:2],assembled_word)) header_bad<=1;
                                    if(!global_header && byte_count==31) expected_video_crc<=assembled_word;
                                    if(!global_header && byte_count==35) expected_audio_crc<=assembled_word;
                                end
                            end else if(sector_no<=75) video_crc<=crc_byte(video_crc,sd_data);
                            else audio_crc<=crc_byte(audio_crc,sd_data);
                        end
                    end
                    if(sd_end) begin
                        if(sd_valid && byte_count>=512) fail(8'he1);
                        else state<=CHECK;
                    end
                end
                CHECK:begin
                    if(byte_count!=512) fail(8'he1);
                    else if(is_header && (header_bad || (~header_crc)!=stored_header_crc))
                        fail(global_header?8'he2:8'he3);
                    else if(global_header) begin global_header<=0;state<=FREE;end
                    else if(sector_no==0) begin
                        write_done<=0;video_crc<=32'hffffffff;audio_crc<=32'hffffffff;
                        line_x<=0;audio_index<=0;write_req<=1;state<=WRREQ;
                    end else if(sector_no==75 && (~video_crc)!=expected_video_crc) fail(8'he4);
                    else if(sector_no==100 && (~audio_crc)!=expected_audio_crc) fail(8'he5);
                    else begin proc_index<=0;state<=PROCESS;end
                end
                WRREQ:if(ack_sync) begin write_req<=0;state<=WRDROP;end
                WRDROP:if(!ack_sync && write_ready) begin sector_no<=1;sd_addr<=frame_lba+1;state<=FETCH;end
                PROCESS:begin
                    if(proc_index==512) begin
                        if(sector_no==100) state<=FINISH;
                        else begin sector_no<=sector_no+1'b1;sd_addr<=sd_addr+1'b1;state<=FETCH;end
                    end else begin
                        proc_index<=proc_index+1'b1;
                        if(sector_no<=75) begin
                            if(!proc_index[0]) low_pixel<=current_byte;
                            else begin
                                line_mem[line_x]<={current_byte,low_pixel};
                                if(line_x==159) begin line_x<=0;out_x<=0;out_repeat<=0;state<=EXPAND;end
                                else line_x<=line_x+1'b1;
                            end
                        end else begin
                            audio_shift<={current_byte,audio_shift[31:8]};
                            if(proc_index[1:0]==3) begin
                                audio_addr<={bank,audio_index};audio_data<={current_byte,audio_shift[31:8]};
                                audio_we<=1;audio_index<=audio_index+1'b1;
                            end
                        end
                    end
                end
                EXPAND:if(write_ready) begin
                    if(out_x==639) begin
                        out_x<=0;
                        if(out_repeat==3) state<=PROCESS;
                        else out_repeat<=out_repeat+1'b1;
                    end else out_x<=out_x+1'b1;
                end
                FINISH:if(write_done) begin
                    if(audio_index!=3200 || line_x!=0) fail(8'he6);
                    else begin
                        filled_toggle[bank]<=~filled_toggle[bank];bank<=~bank;
                        if(load_frame==89) begin load_frame<=0;frame_lba<=8193;end
                        else begin load_frame<=load_frame+1'b1;frame_lba<=frame_lba+101;end
                        state<=FREE;
                    end
                end
                FREE:if(filled_toggle[bank]==release_sync[bank]) begin
                    sector_no<=0;sd_addr<=frame_lba;state<=FETCH;
                end
                FAILED:begin write_req<=0;sd_read<=0;end
                default:fail(8'hef);
            endcase
            if(state!=FREE && state!=FAILED && timeout_count>=TIMEOUT_CYCLES-1) fail(8'he0);
        end
    end
endmodule
`default_nettype wire
