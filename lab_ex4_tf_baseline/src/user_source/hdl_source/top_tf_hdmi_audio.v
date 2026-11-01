
module top(
    input                       uart_rx,        // CH340 RXD, FPGA pin F12
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关 (unchanged)
    input                       key_av,         // NEW: B1 video pause/resume
    input                       sw_video,       // NEW: C8, 0=images, 1=video
    input                       sw_tone,        // NEW: C7, diagnostic tone override

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,
    output [15:0]               lcd_d,
    output                      lcd_cs_n,lcd_wr_n,lcd_rd_n,lcd_dc,lcd_rst_n,lcd_bl,
    output                      tp_sclk,tp_cs_n,tp_mosi,
    input                       tp_miso,tp_pen_n
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS  = 24'd307200;   // 640*480
parameter [ADDR_BITS-1:0] BUF0_ADDR     = 24'd0;
parameter [ADDR_BITS-1:0] BUF1_ADDR     = FRAME_PIXELS;
parameter [ADDR_BITS-1:0] BUF2_ADDR     = FRAME_PIXELS * 2;
parameter [ADDR_BITS-1:0] BUF3_ADDR     = FRAME_PIXELS * 3;
// 3 = repeat crossfade, push-left, cube rotation, horizontal blinds.
parameter TRANSITION_MODE = 3;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;
wire sys_pll_lock,video_pll_lock,rst_all,rst_all_reg;
wire rst_pixel,rst_media_pixel,rst_mem,rst_serial;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw, vout_data_b_raw;
wire [23:0] vout_data;
wire [23:0] vout_data_osd;
wire [23:0] vout_data_waveform;
wire hs_waveform, vs_waveform, de_waveform;
wire        display_valid; // SD-side ownership bookkeeping only
wire        image_ready, transition_done, transition_busy;
wire [1:0]  image_ready_buf, active_read_buf, next_read_buf;
wire        display_valid_video;
wire [8:0]  crossfade_alpha;
wire        dual_read_enable, fade_from_black, read_underflow;
wire        slide_enable;
wire        cube_enable;
wire [1:0]  effect_kind;
wire [127:0] resolution_banks_bcd;
wire [3:0] resolution_banks_valid;
// Follow the outgoing image until the exact all-new endpoint frame.
wire [1:0] resolution_bank=(crossfade_alpha==256 && transition_busy) ? next_read_buf : active_read_buf;
wire [31:0] resolution_async=resolution_banks_bcd[resolution_bank*32+:32];
(* async_reg="true" *) reg [31:0] resolution_meta,resolution_sync;
(* async_reg="true" *) reg resolution_valid_meta,resolution_valid_sync;
always @(posedge video_clk or posedge rst_pixel) begin
    if(rst_pixel) begin resolution_meta<=0;resolution_sync<=0;resolution_valid_meta<=0;resolution_valid_sync<=0;end
    else begin
        resolution_meta<=resolution_async;resolution_sync<=resolution_meta;
        resolution_valid_meta<=resolution_banks_valid[resolution_bank];resolution_valid_sync<=resolution_valid_meta;
    end
end
wire [9:0]  slide_offset;
wire        timing_read_req, timing_read_ack, frame_tick, frame_prefetched;
wire        read_frame_ready;
wire        hs_fade, vs_fade, de_fade;
wire        hs_osd, vs_osd, de_osd;
wire        menu_next_toggle,menu_auto_toggle,menu_next_event,menu_auto_event;
wire [23:0] vout_data_fade;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data, video_read_data_b;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        sd_card_write_ready;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;
wire axis_raw_user,axis_raw_valid,axis_raw_last;
wire [23:0] axis_raw_data;
wire hdmi_stream_reset,hdmi_stream_fault,hdmi_video_locked;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// Keep the HDMI raster/PHY alive while only the media clients restart.
av_reset_sync u_reset_pixel(.clk(video_clk),.async_reset(rst_all_reg),.reset_out(rst_pixel));
av_reset_sync u_reset_media_pixel(.clk(video_clk),.async_reset(rst_all),.reset_out(rst_media_pixel));
av_reset_sync u_reset_mem(.clk(ext_mem_clk),.async_reset(rst_all),.reset_out(rst_mem));
av_reset_sync u_reset_serial(.clk(hdmi_5x_clk),.async_reset(rst_all_reg),.reset_out(rst_serial));

display_power_reset u_display_power_reset(.clk(clk),.reset_n(rst_n),
    .sys_locked(sys_pll_lock),.video_locked(video_pll_lock),.reset_out(rst_all_reg));

wire [1:0] media_mode;
wire av_mode=(media_mode==1);
wire tone_mode=(media_mode==2);
wire touch_valid;
wire [3:0] touch_command;
wire touch_selected_video;
// Declare the disabled diagnostic before every gating use.
wire bmp_row_test_mode=1'b0;
touch_mode_bridge u_touch_mode_bridge(
    .src_clk(video_clk),.src_rst(rst_pixel),.command_valid(touch_valid && !bmp_row_test_mode),
    .command(touch_command),.dst_clk(clk),.dst_rst(rst_all_reg),
    .physical_video(sw_video),.selected_video(touch_selected_video));
// Touch RESET (command 11) must actually restart the media pipeline: the SD
// controller, SDRAM and both readers return to their power-on state, so the
// current picture/video reloads from the card. The LCD panel keeps its own
// rst_pixel and therefore never re-runs its calibration.
// The request crosses as a single held level; only its rising edge may start a
// reset, because the reset itself clears the request. Edge-detecting both edges
// (a toggle) would let the clearing edge re-trigger the reset forever.
wire control_reset_request;
(* async_reg="true" *) reg [2:0] reset_req_sync;
always @(posedge clk or posedge rst_all_reg)
    if(rst_all_reg) reset_req_sync<=0;
    else reset_req_sync<={reset_req_sync[1:0],control_reset_request};
// The shift register feeds new samples into the LSB, so sync[0] is the newest
// and sync[2] the oldest. A rising edge therefore shows up as "second stage is
// high while the oldest is still low": sync[1] & ~sync[2].
// Using sync[2] & ~sync[1] silently never fires, because sync[1] has already
// gone high by the time sync[2] does.
wire manual_reset_pulse=reset_req_sync[1] & ~reset_req_sync[2];
av_mode_control u_av_mode_control(.clk(clk),.power_reset(rst_all_reg),
    .sw_video(touch_selected_video),.sw_tone(sw_tone),.manual_reset(manual_reset_pulse),
    .mode(media_mode),.media_reset(rst_all));

// The BMP row-source exerciser is removed. It was a bring-up diagnostic entered
// by holding both keys through reset, cost 1520 LUT + 3 BRAM, and took over the
// SD SPI bus. The TF bus now has exactly one owner, which also removes a whole
// class of mid-sector ownership mistakes.
// Kept as a constant so the remaining gating conditions fold away in synthesis.
wire normal_sd_cs,normal_sd_clk,normal_sd_mosi;
assign sd_ncs=normal_sd_cs;
assign sd_dclk=normal_sd_clk;
assign sd_mosi=normal_sd_mosi;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// One physical TF controller; mode changes reset both clients before reuse.
wire shared_sd_init,shared_sd_valid,shared_sd_end,pic_sd_read,av_sd_read;
wire [7:0] shared_sd_data;
wire [31:0] pic_sd_addr,av_sd_addr;
wire pic_write_req,pic_write_en,av_write_req,av_write_en,av_write_bank;
wire [31:0] pic_write_data,av_write_data;
wire [1:0] pic_write_buf_idx;
wire av_read_bank,av_display_valid,av_paused,av_display_fault;
wire [7:0] av_error;
wire [3:0] av_status;
wire [6:0] av_load_frame,av_play_frame;
wire [15:0] av_stalls;
wire [1:0] av_filled,av_released;
wire [1:0] av_audio_released;
wire av_audio_we;
wire [12:0] av_audio_waddr,av_audio_raddr;
wire [31:0] av_audio_wdata,av_audio_rdata;
wire [23:0] av_pcm_left,av_pcm_right,tone_pcm;
wire av_pcm_active;
wire sample_tick,acr_valid;
wire [19:0] acr_n,acr_cts;
wire av_pause_event,av_key_pause_event,av_key_down,av_key_long;
wire av_pixel_reset;
assign av_pause_event=av_key_pause_event ||
    (touch_valid && touch_command==5 && av_mode && !av_pixel_reset && !bmp_row_test_mode);
wire av_reset=rst_all || bmp_row_test_mode || !av_mode;
av_reset_sync u_reset_av_pixel(.clk(video_clk),.async_reset(av_reset),.reset_out(av_pixel_reset));
wire actual_display_valid=av_mode ? av_display_valid : display_valid_video;
wire [1:0] actual_read_buf=av_mode ? {1'b0,av_read_bank} : active_read_buf;
assign sd_card_write_req=av_mode ? av_write_req : pic_write_req;
assign sd_card_write_en=av_mode ? av_write_en : pic_write_en;
assign sd_card_write_data=av_mode ? av_write_data : pic_write_data;
assign write_buf_idx=av_mode ? {1'b0,av_write_bank} : pic_write_buf_idx;
// Reset together with the media chain on a mode change, as the baseline did.
// Leaving it unreset (tried 2026-10-19) desynchronises it from the reader's
// restart: the video reader then waits for data that never comes and times out
// to a black screen. Resetting it is the behaviour that actually switches modes,
// so keep it until the init handshake is reworked properly.
sd_card_top #(.SPI_LOW_SPEED_DIV(123)) u_shared_sd(
    .clk(clk),.rst(rst_all),
    .SD_nCS(normal_sd_cs),.SD_DCLK(normal_sd_clk),.SD_MOSI(normal_sd_mosi),.SD_MISO(sd_miso),
    .sd_init_done(shared_sd_init),.sd_sec_read(av_mode?av_sd_read:pic_sd_read),
    .sd_sec_read_addr(av_mode?av_sd_addr:pic_sd_addr),.sd_sec_read_data(shared_sd_data),
    .sd_sec_read_data_valid(shared_sd_valid),.sd_sec_read_end(shared_sd_end),
    .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
    .sd_sec_write_data_req(),.sd_sec_write_end());
hxav_hd_reader #(.EARLY_AUDIO_PREFETCH(1)) u_av_reader(
    .clk(clk),.rst(av_reset),.sd_init_done(shared_sd_init),
    .sd_read(av_sd_read),.sd_addr(av_sd_addr),.sd_data(shared_sd_data),
    .sd_valid(shared_sd_valid),.sd_end(shared_sd_end),
    .write_req(av_write_req),.write_ack(sd_card_write_req_ack),.write_ready(sd_card_write_ready),
    .write_finish_toggle(frame_write_toggle_mem),.write_en(av_write_en),
    .write_data(av_write_data),.write_bank(av_write_bank),
    .audio_we(av_audio_we),.audio_addr(av_audio_waddr),.audio_data(av_audio_wdata),
    .filled_toggle(av_filled),.released_toggle_async(av_released),
    .audio_released_toggle_async(av_audio_released),
    .error_code(av_error),.status(av_status),.load_frame(av_load_frame));
hxav_pcm_banks #(.SAMPLES_PER_BANK(4000)) u_av_pcm_banks(.wr_clk(clk),.wr_en(av_audio_we),
    .wr_addr(av_audio_waddr),.wr_data(av_audio_wdata),.rd_clk(video_clk),
    .rd_addr(av_audio_raddr),.rd_data(av_audio_rdata));
display_key_gesture u_av_pause_key(.clk(video_clk),.rst(av_pixel_reset),.button_n(key_av),
    .down(av_key_down),.short_press(av_key_pause_event),.long_press(av_key_long));
hxav_playback #(.SAMPLES_PER_FRAME(4000),.FRAME_COUNT(72),.PREBUFFER_FRAMES(2)) u_av_playback(.clk(video_clk),.rst(av_pixel_reset),.sample_tick(sample_tick),
    .frame_tick(frame_tick),.frame_prefetched(frame_prefetched),.frame_underflow(read_underflow),
    .pause_event(av_pause_event),.filled_toggle_async(av_filled),.source_error_async(|av_error),
    .released_toggle(av_released),.audio_released_toggle(av_audio_released),.read_bank(av_read_bank),.display_valid(av_display_valid),
    .audio_addr(av_audio_raddr),.audio_data(av_audio_rdata),.pcm_left(av_pcm_left),.pcm_right(av_pcm_right),.pcm_active(av_pcm_active),
    .paused(av_paused),.playing_frame(av_play_frame),.stall_count(av_stalls),.display_fault(av_display_fault));
hdmi_pcm_clock u_hdmi_pcm_clock(.clk(video_clk),.rst(rst_pixel),.sample_tick(sample_tick),
    .acr_valid(acr_valid),.acr_n(acr_n),.acr_cts(acr_cts),.test_pcm(tone_pcm));
wire hdmi_audio_valid,video_audio_valid;
wire [23:0] hdmi_audio_left,hdmi_audio_right,video_audio_left,video_audio_right;
reg tone_audio_valid;
reg [23:0] tone_audio_data;
// Preserve the already verified diagnostic tone path and its timing.
always @(posedge video_clk or posedge rst_pixel) begin
    if(rst_pixel) begin tone_audio_valid<=0;tone_audio_data<=0;end
    else begin tone_audio_valid<=sample_tick;tone_audio_data<=tone_pcm;end
end
assign hdmi_audio_valid=tone_mode ? tone_audio_valid : video_audio_valid;
assign hdmi_audio_left=bmp_row_test_mode ? 24'd0 : (tone_mode ? tone_audio_data : video_audio_left);
assign hdmi_audio_right=bmp_row_test_mode ? 24'd0 : (tone_mode ? tone_audio_data : video_audio_right);
hdmi_audio_conditioner #(.FADE_SAMPLES(512)) u_hdmi_audio_conditioner(
    .clk(video_clk),.rst(rst_pixel),.sample_tick(sample_tick),
    .source_active(!bmp_row_test_mode && av_mode && av_pcm_active),
    .source_left(av_pcm_left),.source_right(av_pcm_right),
    .audio_valid(video_audio_valid),.audio_left(video_audio_left),.audio_right(video_audio_right));
// Six hex digits in AV mode: E/error, pause, stall low byte, frame low byte.
// Status display crosses via a sampled diagnostic bus, never used for control.
wire [23:0] av_digits=(av_mode && av_error!=0) ? {8'he0,av_error,8'd0} :
    ((!hdmi_video_locked || !actual_display_valid) ?
     {4'hd,sys_pll_lock,video_pll_lock,shared_sd_init,Sdr_init_done,
      3'd0,actual_display_valid,3'd0,hdmi_video_locked,3'd0,hdmi_stream_fault,
      (av_mode ? av_status : state_code)} :
     {4'hA,3'd0,av_paused,av_stalls[7:0],1'b0,av_play_frame});
reg [23:0] av_digits_meta,av_digits_sync;
always @(posedge clk) begin av_digits_meta<=av_digits;av_digits_sync<=av_digits_meta;end
wire show_startup_status=(av_digits_sync[23:20]==4'hd);
wire [6:0] av_segments[0:5];
genvar av_digit;
generate for(av_digit=0;av_digit<6;av_digit=av_digit+1) begin: av_hex_digits
    seg_decoder decode(.bin_data(av_display_fault ? (av_digit==0?4'he:4'h7) :
        av_digits_sync[23-av_digit*4 -:4]),.seg_data(av_segments[av_digit]));
end endgenerate

// ===================== TF 多图扫描与缓存（双缓冲） =====================
wire touch_auto_enabled;
display_event_sync u_next_event_sync(.clk(clk),.rst(rst_all || bmp_row_test_mode),
    .toggle_async(menu_next_toggle),.pulse(menu_next_event));
display_event_sync u_auto_event_sync(.clk(clk),.rst(rst_all || bmp_row_test_mode),
    .toggle_async(menu_auto_toggle),.pulse(menu_auto_event));
sd_card_bmp #(
    .EXTERNAL_KEY_EVENTS(1),
    .CACHE_ALL_IMAGES (1),
    .REPORT_RESOLUTION(1),
    .EXTERNAL_SD      (1),
    .SCALE_ENABLE      (1),
    .SCALE_BILINEAR    (1),
    .CLK_FREQ_HZ       (50_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (clk),
    .rst               (rst_all || bmp_row_test_mode || av_mode),
    .key_next          (1'b1), // raw keys are owned exclusively by the menu
    .key_auto          (1'b1),
    .key_next_event    (menu_next_event),
    .key_auto_event    (menu_auto_event),
    .touch_auto_enabled(touch_auto_enabled),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .image_ready       (image_ready),
    .image_ready_buf   (image_ready_buf),
    .resolution_banks_bcd(resolution_banks_bcd),.resolution_banks_valid(resolution_banks_valid),
    .transition_done   (transition_done),
    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (pic_write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (pic_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_ready       (sd_card_write_ready),
    .write_en          (pic_write_en),
    .write_data        (pic_write_data),
    .SD_nCS            (),.SD_DCLK(),.SD_MOSI(),.SD_MISO(sd_miso),
    .ext_sd_init_done(shared_sd_init),.ext_sd_data(shared_sd_data),
    .ext_sd_valid(shared_sd_valid),.ext_sd_end(shared_sd_end),
    .ext_sd_read(pic_sd_read),.ext_sd_addr(pic_sd_addr)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,((av_mode || show_startup_status)?av_segments[0]:7'b1111_111)}),
    .seg_data_1        ({1'b1,((av_mode || show_startup_status)?av_segments[1]:7'b1111_111)}),
    .seg_data_2        ({1'b1,((av_mode || show_startup_status)?av_segments[2]:7'b1111_111)}),
    .seg_data_3        ({1'b1,((av_mode || show_startup_status)?av_segments[3]:7'b1111_111)}),
    .seg_data_4        ({1'b1,((av_mode || show_startup_status)?av_segments[4]:7'b1111_111)}),
    .seg_data_5        ({1'b1,((av_mode || show_startup_status)?av_segments[5]:seg_data_0)})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_pixel),
    .read_req          (timing_read_req),
    .read_req_ack      (timing_read_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay #(.DATA_WIDTH(48)) video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_pixel),
    .read_en           (video_read_en),
    .read_data         ({video_read_data_b[31:8],video_read_data[31:8]}),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         ({vout_data_b_raw,vout_data_raw})
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = (actual_display_valid && (av_mode || !fade_from_black)) ? vout_data_raw : 24'd0;

video_frame_read_bridge u_frame_read_bridge(
    .clk(video_clk), .rst(rst_media_pixel), .timing_req(timing_read_req),
    .mem_ack_async(video_read_req_ack), .mem_ready_async(read_frame_ready),
    .timing_ack(timing_read_ack), .frame_tick(frame_tick),
    .mem_req(video_read_req), .frame_prefetched(frame_prefetched)
);
image_crossfade_control #(.TRANSITION_MODE(TRANSITION_MODE)) u_image_crossfade_control(
    .clk(video_clk),.rst(rst_media_pixel),.image_ready_async(image_ready),
    .ready_buf_async(image_ready_buf),.frame_tick(frame_tick),
    .frame_prefetched(frame_prefetched),.frame_underflow(read_underflow),
    .transition_done(transition_done),.active_buf(active_read_buf),.next_buf(next_read_buf),
    .dual_enable(dual_read_enable),.display_valid(display_valid_video),
    .fade_from_black(fade_from_black),.alpha(crossfade_alpha),.transition_busy(transition_busy),
    .slide_enable(slide_enable),.slide_offset(slide_offset),
    .cube_enable(cube_enable),.effect_kind(effect_kind)
);
video_image_transition u_video_crossfade_rgb(
    .clk(video_clk),.rst(rst_pixel),.hs(hs),.vs(vs),.de(de),
    .rgb_old(vout_data),.rgb_new(display_valid_video ? vout_data_b_raw : 24'd0),
    // Slide reader already assembled a shifted image in stream A. Keep the
    // same two-stage RGB/timing pipeline, at exact unity gain on A.
    .alpha(av_mode ? 9'd0 : crossfade_alpha),
    .effect_kind(av_mode ? 2'd0 : effect_kind),
    .hs_out(hs_fade),.vs_out(vs_fade),.de_out(de_fade),.rgb_out(vout_data_fade)
);

// Reset menu state on a mode change without interrupting its timing pipeline.
wire touch_menu;
wire signed [8:0] touch_brightness;
wire [8:0] touch_contrast;
wire touch_control_valid=touch_valid && !rst_media_pixel && !bmp_row_test_mode &&
    ((touch_command==3 || touch_command==4) ? (!av_mode && actual_display_valid) : 1'b1);
video_display_controls #(.FAST_NEXT(1),.ENABLE_TOUCH(1),.ENABLE_RESOLUTION(1),.SEPARATE_CONTROL_RESET(1)) u_display_controls(
    .clk(video_clk),.rst(rst_pixel),.control_reset(rst_media_pixel),.diagnostic_mode(bmp_row_test_mode),
    .touch_valid(touch_control_valid),.touch_command(touch_command),
    .touch_menu(touch_menu),.touch_brightness(touch_brightness),.touch_contrast(touch_contrast),
    .key1(key1),.key2(key2),.uart_rx(uart_rx),
    .hs(hs_fade),.vs(vs_fade),.de(de_fade),.picture_valid(actual_display_valid),
    .rgb_in(vout_data_fade),.next_toggle(menu_next_toggle),.auto_toggle(menu_auto_toggle),
    .resolution_enable(!av_mode && !bmp_row_test_mode),
    .resolution_valid(resolution_valid_sync),.resolution_bcd(resolution_sync),
    .hs_out(hs_osd),.vs_out(vs_osd),.de_out(de_osd),.rgb_out(vout_data_osd),
    .control_reset_request(control_reset_request));

// LCD owns no SDRAM/BRAM and is never reset by a playback mode change.
wire touch_sample_valid,touch_sample_down;
wire [11:0] touch_raw_u,touch_raw_v;
wire [1:0] touch_calibration;
wire [1:0] touch_rendered_calibration;
wire touch_calibration_error;
(* async_reg="true" *) reg [1:0] touch_auto_sync;
(* async_reg="true" *) reg [1:0] touch_av_sync,touch_tone_sync;
always @(posedge video_clk or posedge rst_pixel)
    if(rst_pixel) begin touch_auto_sync<=0;touch_av_sync<=0;touch_tone_sync<=0;end
    else begin
        touch_auto_sync<={touch_auto_sync[0],touch_auto_enabled};
        touch_av_sync<={touch_av_sync[0],av_mode};touch_tone_sync<={touch_tone_sync[0],tone_mode};
    end
touch_xpt2046 u_touch_adc(.clk(video_clk),.rst(rst_pixel),.pen_n(tp_pen_n),.miso(tp_miso),
    .sclk(tp_sclk),.cs_n(tp_cs_n),.mosi(tp_mosi),
    .sample_valid(touch_sample_valid),.sample_down(touch_sample_down),
    .raw_u(touch_raw_u),.raw_v(touch_raw_v));
touch_panel_control u_touch_control(.clk(video_clk),.rst(rst_pixel),
    .sample_valid(touch_sample_valid && lcd_bl && touch_rendered_calibration==touch_calibration),
    .sample_down(touch_sample_down),.raw_u(touch_raw_u),.raw_v(touch_raw_v),
    .calibration(touch_calibration),.calibration_error(touch_calibration_error),
    .command_valid(touch_valid),.command(touch_command));
lcd_ili9341_panel u_lcd_panel(.clk(video_clk),.rst(rst_pixel),
    .calibration(touch_calibration),.calibration_error(touch_calibration_error),
    .mode(touch_tone_sync[1]?2'd2:{1'b0,touch_av_sync[1]}),.image_index(active_read_buf),
    .auto_enabled(touch_auto_sync[1]),.paused(av_paused),
    .media_ready(actual_display_valid && !rst_media_pixel && !bmp_row_test_mode),
    .menu_open(touch_menu),.brightness(touch_brightness),.contrast(touch_contrast),
    .lcd_d(lcd_d),.lcd_cs_n(lcd_cs_n),.lcd_wr_n(lcd_wr_n),.lcd_rd_n(lcd_rd_n),
    .lcd_dc(lcd_dc),.lcd_rst_n(lcd_rst_n),.lcd_bl(lcd_bl),.initialized(),
    .rendered_calibration(touch_rendered_calibration),
    .debug_x(),.debug_y(),.debug_pixel(),.debug_accept());

// Observe delivered video PCM. No playback control or existing key consumed.
video_audio_waveform u_audio_waveform(
    .clk(video_clk),.rst(rst_pixel),
    .enable(av_mode && !bmp_row_test_mode && av_display_valid),
    .hs(hs_osd),.vs(vs_osd),.de(de_osd),.rgb_in(vout_data_osd),
    .audio_valid(video_audio_valid),.audio_left(video_audio_left),.audio_right(video_audio_right),
    .hs_out(hs_waveform),.vs_out(vs_waveform),.de_out(de_waveform),.rgb_out(vout_data_waveform));

frame_read_write #(
    .DUAL_READ        (1),
    .ENABLE_SLIDE     (1),
    .ENABLE_CUBE      (1),
    .WRITE_V_FLIP     (0), // row source already normalizes BMP orientation
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_frame_ready  (read_frame_ready),
    .read_addr_index_b (next_read_buf),
    .read_dual_enable  (dual_read_enable && !av_mode),
    .read_slide_enable (slide_enable && !av_mode),
    .read_cube_enable  (cube_enable && !av_mode),
    .read_slide_offset (slide_offset),
    .read_frame_start  (frame_tick),
    .read_underflow    (read_underflow),
    .read_data_b       (video_read_data_b),
    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (actual_read_buf),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_ready       (sd_card_write_ready)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_pixel),
    .I_vs          (vs_waveform),
    .I_de          (de_waveform),
    .I_rgb         ((!rst_media_pixel && actual_display_valid) ? vout_data_waveform : 24'd0),
    .O_video_user  (axis_raw_user),
    .O_video_valid (axis_raw_valid),
    .O_video_last  (axis_raw_last),
    .O_video_data  (axis_raw_data)
);
hdmi_line_elastic u_hdmi_line_elastic(
    .clk(video_clk),.rst(rst_pixel),.in_valid(axis_raw_valid),
    .in_user(axis_raw_user),.in_last(axis_raw_last),.in_data(axis_raw_data),
    .receiver_ready(axis_s_ready),.out_valid(axis_s_valid),.out_user(axis_s_user),
    .out_last(axis_s_last),.out_data(axis_s_data),
    .recover_reset(hdmi_stream_reset),.fault_seen(hdmi_stream_fault));

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_pixel),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_pixel || hdmi_stream_reset),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (hdmi_audio_valid),
    .I_audio_left_data  (hdmi_audio_left),
    .I_audio_right_data (hdmi_audio_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (hdmi_video_locked),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_serial),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
