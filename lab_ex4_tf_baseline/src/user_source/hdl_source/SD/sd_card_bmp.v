
module sd_card_bmp #(
    parameter integer EXTERNAL_KEY_EVENTS = 0,
    // Four immutable SDRAM banks; preload once, then switch without SD reads.
    parameter integer CACHE_ALL_IMAGES = 0,
    parameter integer REPORT_RESOLUTION = 0,
    parameter integer EXTERNAL_SD = 0,
    parameter integer SCALE_ENABLE     = 0,
    parameter integer SCALE_BILINEAR   = 0,
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer LOAD_IDLE_TIMEOUT_CYCLES = CLK_FREQ_HZ
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       key_next_event,
    input                       key_auto_event,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,

    // Four-phase bundled-data handshake: hold ready buffer until transition_done.
    output reg                  image_ready,
    output [1:0]                image_ready_buf,
    input                       transition_done,
    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    input                       write_ready,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,
    input wire ext_sd_init_done,
    input wire [7:0] ext_sd_data,
    input wire ext_sd_valid,ext_sd_end,
    output wire ext_sd_read,
    output wire [31:0] ext_sd_addr,
    output wire [127:0] resolution_banks_bcd,
    output wire [3:0] resolution_banks_valid,
    output wire touch_auto_enabled
);

wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             source_failed;
wire             source_meta_valid;
wire [15:0]      source_width,source_height;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
assign touch_auto_enabled=auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
// The production scan is bounded to 17-bit sectors. Keep those bits intact
// and reuse/extend the upper bits for committed 24-bit compact BCD metadata.
localparam REUSE_SECTOR_METADATA=REPORT_RESOLUTION && CACHE_ALL_IMAGES && SCAN_MAX_SECTOR<=131071;
reg [40:0]       img_sector0,img_sector1,img_sector2,img_sector3;
wire [31:0]     resolution_converted_bcd;
wire            resolution_converted_valid;
reg [2:0]        cached_count;
reg              next_req_pending;
reg              load_busy;
reg [31:0]       load_timeout_cnt;

reg              load_abort;
reg              write_ack_d;
(* async_reg = "true" *) reg write_ack_meta, write_ack_sync;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_busy_seen;
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

(* async_reg = "true" *) reg done_meta, done_sync;
always @(posedge clk or posedge rst) begin
    if (rst) begin done_meta <= 0; done_sync <= 0; end
    else begin done_meta <= transition_done; done_sync <= done_meta; end
end
assign image_ready_buf = pending_buf_idx;
wire can_load = !load_busy && !image_ready && !done_sync && !load_abort;
// Measure inactivity, NOT the total time needed to transfer a BMP. A 640x480
// file can legitimately take more than one second on a slow TF card.
wire load_progress = sd_sec_read_data_valid || sd_sec_read_end ||
                     bmp_data_wr_en ||
                     (write_ack_sync && !write_ack_d) || write_finish_pulse ||
                     load_start_pulse || (!bmp_ready && !source_busy_seen) ||
                     (source_busy_seen && bmp_ready && !source_done_seen);

wire auto_tick;
wire [1:0] next_from_current;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = state_code_i;

generate if(EXTERNAL_KEY_EVENTS) begin: event_keys
    assign key_next_press=key_next_event;
    assign key_auto_press=key_auto_event;
end else begin: legacy_keys
key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);
end endgenerate

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = REUSE_SECTOR_METADATA ? {15'd0,img_sector0[16:0]} : img_sector0[31:0];
            2'd1: sector_lut = REUSE_SECTOR_METADATA ? {15'd0,img_sector1[16:0]} : img_sector1[31:0];
            2'd2: sector_lut = REUSE_SECTOR_METADATA ? {15'd0,img_sector2[16:0]} : img_sector2[31:0];
            2'd3: sector_lut = REUSE_SECTOR_METADATA ? {15'd0,img_sector3[16:0]} : img_sector3[31:0];
            default: sector_lut = REUSE_SECTOR_METADATA ? {15'd0,img_sector0[16:0]} : img_sector0[31:0];
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        write_ack_d          <= 1'b0;
        write_ack_meta       <= 1'b0;
        write_ack_sync       <= 1'b0;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        cached_count          <= 3'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        source_busy_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        image_ready           <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        write_ack_meta  <= write_req_ack;
        write_ack_sync  <= write_ack_meta;
        write_ack_d     <= write_ack_sync;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            cached_count          <= 3'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            source_busy_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            image_ready           <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= REUSE_SECTOR_METADATA ? {24'd0,scan_found_sector[16:0]} : {9'd0,scan_found_sector};
                    3'd1: img_sector1 <= REUSE_SECTOR_METADATA ? {24'd0,scan_found_sector[16:0]} : {9'd0,scan_found_sector};
                    3'd2: img_sector2 <= REUSE_SECTOR_METADATA ? {24'd0,scan_found_sector[16:0]} : {9'd0,scan_found_sector};
                    3'd3: img_sector3 <= REUSE_SECTOR_METADATA ? {24'd0,scan_found_sector[16:0]} : {9'd0,scan_found_sector};
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && !bmp_ready)
                source_busy_seen <= 1'b1;
            if (load_busy && source_busy_seen && bmp_ready)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // Step 1: loading completion publishes a stable buffer descriptor.
            // Ownership is retained until the video-domain fade/commit completes.
            if (image_ready && done_sync) begin
                image_ready           <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
            end
            if (load_busy && source_busy_seen && source_failed) begin
                // Never publish a partial or failed scaled frame.
                load_busy<=0;source_done_seen<=0;source_busy_seen<=0;
                write_done_seen<=0;load_timeout_cnt<=0;
            end else if (load_busy && source_done_seen && write_done_seen) begin
                if(REUSE_SECTOR_METADATA && resolution_converted_valid) begin
                    case(pending_buf_idx)
                        0:img_sector0[40:17]<={resolution_converted_bcd[28:16],resolution_converted_bcd[10:0]};
                        1:img_sector1[40:17]<={resolution_converted_bcd[28:16],resolution_converted_bcd[10:0]};
                        2:img_sector2[40:17]<={resolution_converted_bcd[28:16],resolution_converted_bcd[10:0]};
                        3:img_sector3[40:17]<={resolution_converted_bcd[28:16],resolution_converted_bcd[10:0]};
                    endcase
                end
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                source_busy_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                if (CACHE_ALL_IMAGES)
                    cached_count <= cached_count + 3'd1;
                else
                    image_ready <= 1'b1;
            end else if (load_busy) begin
                if (load_progress) begin
                    load_timeout_cnt <= 32'd0;
                end else if (load_timeout_cnt >= LOAD_IDLE_TIMEOUT_CYCLES - 1) begin
                    // Preserve the displayed image; bmp_read drains any sector
                    // already in flight before accepting the next load request.
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    source_busy_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                cached_count          <= 3'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                image_ready           <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                source_busy_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关
                if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 1s 计数：只有加载和转场均结束后才计时
                if (scan_done && auto_play_en && display_valid && can_load && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                if (CACHE_ALL_IMAGES) begin
                    // Publish nothing until all complete frames are resident. This
                    // moves slow media I/O to startup and gives every index the
                    // same key-to-transition latency. A failed load never advances
                    // cached_count, so partial frames cannot be displayed.
                    if (scan_done && bmp_ready && can_load &&
                        cached_count < img_found_count) begin
                        load_idx <= cached_count[1:0];
                        load_sector <= sector_lut(cached_count[1:0]);
                        pending_buf_idx <= cached_count[1:0];
                        write_buf_idx <= cached_count[1:0];
                        load_start_pulse <= 1'b1;
                        load_busy <= 1'b1;
                        source_done_seen <= 1'b0;
                        source_busy_seen <= 1'b0;
                        write_done_seen <= 1'b0;
                    end else if (scan_done && can_load &&
                                 cached_count == img_found_count && cached_count != 0) begin
                        if (!first_image_committed) begin
                            load_idx <= 0;pending_buf_idx <= 0;image_ready <= 1;
                            auto_cnt <= 0;
                        end else if (next_req_pending ||
                                     (auto_play_en && auto_tick && img_found_count > 1)) begin
                            load_idx <= next_from_current;
                            pending_buf_idx <= next_from_current;
                            image_ready <= 1;
                            next_req_pending <= 0;auto_cnt <= 0;
                        end
                    end
                end else begin
                // 首图自动加载到 buffer0
                if (scan_done && !first_image_committed && bmp_ready && can_load && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    load_sector      <= sector_lut(0);
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_busy_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && can_load && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_busy_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && can_load && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_busy_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                end // legacy two-bank demand loader
            end
        end
    end
end

generate if(SCALE_ENABLE) begin: scaled_reader
    bmp_scaled_read #(.BILINEAR(SCALE_BILINEAR),.TIMEOUT_CYCLES(LOAD_IDLE_TIMEOUT_CYCLES)) bmp_read_m0(
        .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.ready(bmp_ready),
        .scan_start(scan_start_pulse),.scan_start_sector(SCAN_START_SECTOR),
        .scan_max_sector(SCAN_MAX_SECTOR),.scan_target_count(SCAN_TARGET_COUNT),
        .scan_done(scan_done),.scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector),.scan_found_total(scan_found_total),
        .load_start(load_start_pulse),.load_abort(load_abort),.load_sector(load_sector),
        .state_code(state_code_i),.load_failed(source_failed),
        .write_req(write_req),.write_req_ack(write_ack_sync),.write_ready(write_ready),
        .bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data),
        .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .source_meta_valid(source_meta_valid),.source_width(source_width),.source_height(source_height));
end else begin: legacy_reader
assign source_failed=1'b0;
assign source_meta_valid=load_start_pulse;
assign source_width=bmp_width;
assign source_height=bmp_height;
bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_ack_sync),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

end endgenerate

generate if(REPORT_RESOLUTION) begin: resolution_metadata
    wire [127:0] private_words;
    image_resolution_cache #(.STORE_BANKS(!REUSE_SECTOR_METADATA)) cache(
        .clk(clk),.rst(rst),.invalidate(!sd_init_done),.meta_valid(source_meta_valid),
        .commit(load_busy && source_done_seen && write_done_seen && !source_failed),
        .bank(pending_buf_idx),.source_width(source_width),.source_height(source_height),
        .bank_bcd(private_words),.bank_valid(resolution_banks_valid),
        .converted_bcd(resolution_converted_bcd),.converted_valid(resolution_converted_valid));
    assign resolution_banks_bcd=REUSE_SECTOR_METADATA ?
        {3'b0,img_sector3[40:28],5'b0,img_sector3[27:17],
         3'b0,img_sector2[40:28],5'b0,img_sector2[27:17],
         3'b0,img_sector1[40:28],5'b0,img_sector1[27:17],
         3'b0,img_sector0[40:28],5'b0,img_sector0[27:17]} : private_words;
end else begin: no_resolution_metadata
    assign resolution_banks_bcd=0;
    assign resolution_banks_valid=0;
    assign resolution_converted_bcd=0;assign resolution_converted_valid=0;
end endgenerate

assign ext_sd_read=sd_sec_read;
assign ext_sd_addr=sd_sec_read_addr;
generate if(EXTERNAL_SD) begin: shared_transport
    assign sd_init_done=ext_sd_init_done;
    assign sd_sec_read_data=ext_sd_data;
    assign sd_sec_read_data_valid=ext_sd_valid;
    assign sd_sec_read_end=ext_sd_end;
    assign SD_nCS=1'b1;assign SD_DCLK=1'b1;assign SD_MOSI=1'b1;
end else begin: internal_transport
sd_card_top #(.SPI_LOW_SPEED_DIV((CLK_FREQ_HZ>=800000)?CLK_FREQ_HZ/400000-2:0)) sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

end endgenerate
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
