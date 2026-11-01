`default_nettype none
// Two ordered streams from ONE SDRAM port. Only one burst is outstanding:
// response routing retains its stream tag until EVERY returned beat is seen.
module frame_dual_reader #(
    parameter integer ADDR_BITS=21,
    parameter integer BURST_SIZE=128,
    parameter integer FIFO_DEPTH=512,
    parameter integer ENABLE_SLIDE=0,
    parameter integer ENABLE_CUBE=0,
    parameter integer FRAME_WIDTH=640,
    // At 125 MHz, 4096 idle cycles = 32.768 us excluding busy/refresh.
    // A response resets the watchdog; busy/refresh pauses (not resets) it.
    parameter integer RESPONSE_IDLE_CYCLES=4096
)(
    input wire rst, mem_clk, read_clk,
    input wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy, App_wr_busy,
    output reg O_rd_busy,
    output wire App_rd_en,
    output wire [ADDR_BITS-1:0] App_rd_addr,
    input wire Sdr_rd_en,
    input wire [31:0] Sdr_rd_dout,
    input wire read_req,
    output reg read_req_ack,
    output wire read_finish,
    input wire [ADDR_BITS-1:0] read_addr_0,read_addr_1,read_addr_2,read_addr_3,
    input wire [1:0] read_addr_index,read_addr_index_b,
    input wire read_dual_enable,
    input wire read_slide_enable,
    input wire read_cube_enable,
    input wire [9:0] read_slide_offset,
    input wire [ADDR_BITS-1:0] read_len,
    input wire read_en,read_frame_start,
    output wire [31:0] read_data,read_data_b,
    output reg read_frame_ready,
    output reg read_underflow
);
    (* async_reg="true" *) reg req0,req1,req2;
    reg [1:0] idxa0,idxa1,idxb0,idxb1;
    reg dual0,dual1,dual_latched;
    reg slide0,slide1,slide_latched,segment_new;
    reg cube0,cube1,cube_latched;
    reg [9:0] scale_phase;
    reg [8:0] cube_kept;
    reg [9:0] shift0,shift1,old_width,new_width,segment_left;
    reg [9:0] face_width_q,face_threshold_q;
    // Reuse the extended subtraction's borrow bit for the comparison. A
    // separate comparator followed by a selected subtractor was a 125 MHz
    // critical path. Both the decision and low ten result bits are identical.
    wire [10:0] cube_phase_difference={1'b0,scale_phase}-{1'b0,face_threshold_q};
    wire cube_emit=!cube_phase_difference[10];
    reg [ADDR_BITS-1:0] row_old,row_new;
    reg [ADDR_BITS-1:0] row_old_next,row_new_next,slide_addr;
    reg old_empty,new_empty,segment_ends,writer_busy_q;
    wire [9:0] bounded_shift=(shift1>FRAME_WIDTH)?FRAME_WIDTH:shift1;
    reg [ADDR_BITS-1:0] len0,len1,len_latched,addr_a,addr_b,count_a,count_b;
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            req0<=0;req1<=0;req2<=0;idxa0<=0;idxa1<=0;idxb0<=0;idxb1<=0;
            dual0<=0;dual1<=0;len0<=0;len1<=0;
            slide0<=0;slide1<=0;shift0<=0;shift1<=0;
            cube0<=0;cube1<=0;
        end else begin
            req0<=read_req;req1<=req0;req2<=req1;
            idxa0<=read_addr_index;idxa1<=idxa0;
            idxb0<=read_addr_index_b;idxb1<=idxb0;
            dual0<=read_dual_enable;dual1<=dual0;len0<=read_len;len1<=len0;
            slide0<=ENABLE_SLIDE ? read_slide_enable : 1'b0;slide1<=slide0;
            cube0<=ENABLE_CUBE ? read_cube_enable : 1'b0;cube1<=cube0;
            shift0<=(ENABLE_SLIDE || ENABLE_CUBE) ? read_slide_offset : 10'd0;shift1<=shift0;
        end
    end
    function [ADDR_BITS-1:0] base_addr;
        input [1:0] index;
        begin case(index)
            0:base_addr=read_addr_0;1:base_addr=read_addr_1;
            2:base_addr=read_addr_2;default:base_addr=read_addr_3;
        endcase end
    endfunction
    localparam IDLE=0,ACK=1,SETTLE=2,CHECK=3,ISSUE=4,DRAIN=5,GUARD=6,PREPARE=7,
               CONFIGURE=8,ADVANCE=9,NEXT_SEGMENT=10,RESERVE=11;
    reg [3:0] state;
    reg fifo_clear,stream_b;
    reg [8:0] burst_len,issued,received;
    // Slide reads use aligned, full physical bursts. Prefix/suffix pixels
    // outside the visible segment are consumed but never enter the FIFO.
    // BURST_SIZE must be a power of two (production uses 128 words).
    localparam ALIGN_BITS=$clog2(BURST_SIZE);
    reg [ADDR_BITS-1:0] slide_burst_base;
    reg [8:0] slide_skip,slide_keep,slide_end,issue_last;
    reg [8:0] slide_prefix_q,slide_room_q,slide_payload_q;
    reg [3:0] guard_count;
    localparam WAIT_BITS=(RESPONSE_IDLE_CYCLES<2)?1:$clog2(RESPONSE_IDLE_CYCLES+1);
    reg [WAIT_BITS-1:0] response_idle_count;
    reg response_timeout_q,responses_done_q;
    wire [8:0] used_a,used_b;
    reg [8:0] used_a_q,used_b_q,burst_a_q,burst_b_q;
    reg [ADDR_BITS-1:0] remaining_a,remaining_b;
    reg need_a,need_b;
    wire empty_a,empty_b,full_a,full_b;
    wire [31:0] data_a,data_b;
    // Serve the emptier FIFO, A on exact ties. A completed burst raises its
    // occupancy before the next decision, so B cannot starve. Avoid a second
    // wide equality comparator and tie-history mux on this small device.
    wire choose_b=need_b && (!need_a || used_b_q<used_a_q);
    wire response=(state==ISSUE || state==DRAIN) && Sdr_rd_en;
    wire source_visible=(received>=slide_skip && received<slide_end);
    wire keep_response=!slide_latched || source_visible;
    assign App_rd_en=(state==ISSUE);
    assign App_rd_addr=slide_latched ?
                       {slide_burst_base[ADDR_BITS-1:ALIGN_BITS],issued[ALIGN_BITS-1:0]} :
                       (stream_b ? addr_b : addr_a);
    assign read_finish=(state==CHECK && count_a==len_latched &&
                        (!dual_latched || count_b==len_latched));
    // Both FIFOs advance together, or neither advances. Once an underflow
    // occurs, hold the last pixel pair for the REST of this frame; next frame
    // resets both FIFOs so a late stream cannot shift all subsequent pixels.
    wire pop=read_en && !read_underflow && !empty_a &&
             (!read_dual_enable || !empty_b) && !fifo_clear;
    always @(posedge read_clk or posedge rst) begin
        if(rst) read_underflow<=0;
        else if(read_frame_start) read_underflow<=0;
        else if(read_en && (empty_a || (read_dual_enable && empty_b) || fifo_clear))
            read_underflow<=1;
    end
    assign read_data=data_a;
    assign read_data_b=read_dual_enable ? data_b : data_a;
    // Keep response qualification off the FIFO RAM write-address/enable path.
    // Data and its stream/visible tag travel through the same register stage.
    reg fifo_we_a,fifo_we_b;
    reg [31:0] fifo_data;
    // The async FIFO count includes a Gray-to-binary decode and subtraction.
    // Register it before arbitration. GUARD/RESERVE provide more than enough
    // cycles for these snapshots after the last return, while the 16-word
    // admission margin still covers the one-stage response pipeline.
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            used_a_q<=0;used_b_q<=0;need_a<=0;need_b<=0;
            remaining_a<=0;remaining_b<=0;burst_a_q<=0;burst_b_q<=0;
        end else begin
            used_a_q<=used_a;used_b_q<=used_b;
            need_a<=(count_a<len_latched) && (used_a_q<=FIFO_DEPTH-BURST_SIZE-16);
            need_b<=dual_latched && (count_b<len_latched) && (used_b_q<=FIFO_DEPTH-BURST_SIZE-16);
            remaining_a<=len_latched-count_a;remaining_b<=len_latched-count_b;
            burst_a_q<=(remaining_a<BURST_SIZE)?remaining_a:BURST_SIZE;
            burst_b_q<=(remaining_b<BURST_SIZE)?remaining_b:BURST_SIZE;
        end
    end
    // Reserve the bus before consulting a registered writer-busy indication.
    // The reservation prevents a new writer burst; an already granted burst
    // drains normally. This removes the writer FIFO's wide admission adder
    // from the reader state transition path without trusting stale busy data.
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            writer_busy_q<=1;row_old_next<=0;row_new_next<=0;
            face_width_q<=0;face_threshold_q<=0;
            slide_prefix_q<=0;slide_room_q<=0;slide_payload_q<=0;
        end
        else begin
            // Only sample busy after our registered reservation is asserted.
            // The writer's speculative FIFO admission is then disabled, so
            // this captures an active burst without its 21-bit admission sum.
            // RESERVE waits three cycles before trusting this indication.
            writer_busy_q<=App_wr_busy && O_rd_busy;
            row_old_next<=row_old+FRAME_WIDTH;
            row_new_next<=row_new+FRAME_WIDTH;
            // Segment selection settles during GUARD/RESERVE, before ISSUE.
            // Keep its mux out of the 125 MHz per-return decimation path.
            face_width_q<=segment_new ? new_width : old_width;
            face_threshold_q<=segment_new ? old_width : new_width;
            slide_prefix_q<=slide_addr[ALIGN_BITS-1:0];
            slide_room_q<=BURST_SIZE-slide_addr[ALIGN_BITS-1:0];
            slide_payload_q<=(segment_left<slide_room_q)?segment_left:slide_room_q;
        end
    end
    // Wide return-count/watchdog comparisons stop here, before FSM decoding.
    // The extra drain cycle also lets the registered FIFO write settle.
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin response_timeout_q<=0;responses_done_q<=0;end
        else begin
            response_timeout_q<=(response_idle_count>=RESPONSE_IDLE_CYCLES-1);
            responses_done_q<=(received==burst_len);
        end
    end
    reg cube_source_valid_q;
    reg [31:0] cube_source_data_q;
    reg plain_source_valid_q,plain_stream_b_q,plain_keep_q;
    // Cube source rows and frame bases are 128-word aligned (640-pixel
    // production rows). All returned beats belong to the face being scaled.
    // Register each source beat BEFORE decimation; do not put SDRAM return
    // count comparisons on the accumulator/counter/FIFO enable paths.
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            cube_source_valid_q<=0;cube_source_data_q<=0;
            plain_source_valid_q<=0;plain_stream_b_q<=0;plain_keep_q<=0;
        end
        else begin
            cube_source_valid_q<=response && cube_latched && !fifo_clear;
            cube_source_data_q<=Sdr_rd_dout;
            // Share the data register for every mode. Capture the slide
            // comparison separately from the FIFO enable mux, rather than
            // chaining both through the same 8 ns memory-clock cycle.
            plain_source_valid_q<=response && !cube_latched && !fifo_clear;
            plain_stream_b_q<=stream_b;
            plain_keep_q<=keep_response;
        end
    end
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin scale_phase<=0;cube_kept<=0;end
        else begin
            if(state==ACK || (state==NEXT_SEGMENT && segment_ends)) scale_phase<=0;
            else if(cube_source_valid_q)
                scale_phase<=cube_emit ? cube_phase_difference[9:0] : scale_phase+face_width_q;
            if(state==PREPARE) cube_kept<=0;
            else if(cube_source_valid_q && cube_emit) cube_kept<=cube_kept+1'b1;
        end
    end
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin fifo_we_a<=0;fifo_we_b<=0;fifo_data<=0;end
        else begin
            fifo_we_a<=cube_latched ? (cube_source_valid_q && cube_emit) :
                (plain_source_valid_q && !plain_stream_b_q && plain_keep_q);
            fifo_we_b<=plain_source_valid_q && plain_stream_b_q;
            fifo_data<=cube_source_data_q;
        end
    end
    rfifo_32_32_512 fifo_a(
        .rst(rst|fifo_clear),.clkw(mem_clk),.clkr(read_clk),
        .we(fifo_we_a),.di(fifo_data),.re(pop),.dout(data_a),
        .empty_flag(empty_a),.full_flag(full_a),.wrusedw(used_a),
        .valid(),.afull(),.aempty(),.rdusedw());
    rfifo_32_32_512 fifo_b(
        .rst(rst|fifo_clear),.clkw(mem_clk),.clkr(read_clk),
        .we(fifo_we_b),.di(fifo_data),.re(pop && read_dual_enable),.dout(data_b),
        .empty_flag(empty_b),.full_flag(full_b),.wrusedw(used_b),
        .valid(),.afull(),.aempty(),.rdusedw());

    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;fifo_clear<=1;read_req_ack<=0;read_frame_ready<=0;O_rd_busy<=0;
            dual_latched<=0;len_latched<=0;addr_a<=0;addr_b<=0;count_a<=0;count_b<=0;
            stream_b<=0;burst_len<=0;issued<=0;received<=0;guard_count<=0;
            slide_latched<=0;segment_new<=0;old_width<=0;new_width<=0;
            cube_latched<=0;
            segment_left<=0;row_old<=0;row_new<=0;
            response_idle_count<=0;
            slide_burst_base<=0;slide_skip<=0;slide_keep<=0;slide_end<=0;issue_last<=0;
            slide_addr<=0;old_empty<=0;new_empty<=1;segment_ends<=0;
        end else begin
            if(state!=DRAIN || Sdr_rd_en)
                response_idle_count<=0;
            else if(!Sdr_busy && !Sdr_init_ref_vld && response_idle_count<RESPONSE_IDLE_CYCLES)
                response_idle_count<=response_idle_count+1'b1;
            if(fifo_clear) read_frame_ready<=0;
            else if(used_a_q>=BURST_SIZE && (!dual_latched || used_b_q>=BURST_SIZE))
                read_frame_ready<=1;
            if(response) received<=received+1'b1;
            case(state)
                IDLE: if(req2 && Sdr_init_done) state<=ACK;
                ACK: begin
                    O_rd_busy<=0;
                    fifo_clear<=1;read_req_ack<=1;read_frame_ready<=0;
                    addr_a<=base_addr(idxa1);
                    slide_addr<=(bounded_shift==FRAME_WIDTH)?base_addr(idxb1):
                        base_addr(idxa1)+(cube1 ? 10'd0 : bounded_shift);
                    addr_b<=base_addr(idxb1);
                    count_a<=0;count_b<=0;len_latched<=len1;dual_latched<=dual1 && !slide1 && !cube1;
                    slide_latched<=slide1 || cube1;cube_latched<=cube1;
                    old_width<=FRAME_WIDTH-bounded_shift;new_width<=bounded_shift;
                    old_empty<=(bounded_shift==FRAME_WIDTH);new_empty<=(bounded_shift==0);
                    row_old<=base_addr(idxa1)+(cube1 ? 10'd0 : bounded_shift);row_new<=base_addr(idxb1);
                    segment_new<=(bounded_shift==FRAME_WIDTH);
                    segment_left<=cube1 ? FRAME_WIDTH :
                        (bounded_shift==FRAME_WIDTH)?FRAME_WIDTH:FRAME_WIDTH-bounded_shift;
                    if(!req2) begin
                        read_req_ack<=0;fifo_clear<=0;guard_count<=7;state<=SETTLE;
                    end
                end
                SETTLE: if(guard_count==0) state<=CHECK;
                        else guard_count<=guard_count-1'b1;
                CHECK: begin
                    if(req2) state<=ACK;
                    else if(Sdr_init_done && (need_a || need_b)) begin
                        guard_count<=3;state<=RESERVE;O_rd_busy<=1;
                    end
                end
                RESERVE: begin
                    if(guard_count!=0) guard_count<=guard_count-1'b1;
                    else if(!writer_busy_q && !Sdr_busy && !Sdr_init_ref_vld)
                        state<=PREPARE;
                end
                // Bus reservation is registered before configuring the burst.
                // This breaks the writer-FIFO-count -> many register-enable path.
                PREPARE: begin
                    stream_b<=choose_b;issued<=0;received<=0;state<=CONFIGURE;
                    slide_burst_base<={slide_addr[ADDR_BITS-1:ALIGN_BITS],{ALIGN_BITS{1'b0}}};
                    slide_skip<=slide_prefix_q;slide_keep<=slide_payload_q;
                    if(choose_b)
                        burst_len<=burst_b_q;
                    else if(slide_latched)
                        // Physical read stays aligned and contiguous. Visible
                        // pixels still never cross the seam or row boundary.
                        burst_len<=BURST_SIZE;
                    else
                        burst_len<=burst_a_q;
                end
                CONFIGURE: begin
                    slide_end<=slide_skip+slide_keep;
                    issue_last<=burst_len-1'b1;
                    state<=ISSUE;
                end
                ISSUE: begin
                    issued<=issued+1'b1;
                    if(stream_b) begin addr_b<=addr_b+1'b1;count_b<=count_b+1'b1;end
                    else if(!slide_latched) begin
                        addr_a<=addr_a+1'b1;count_a<=count_a+1'b1;
                    end
                    if(issued==issue_last) state<=DRAIN;
                end
                DRAIN: if(responses_done_q) begin
                    guard_count<=10;
                    state<=slide_latched ? ADVANCE : GUARD;
                end else if(response_timeout_q &&
                            !Sdr_rd_en && !Sdr_busy && !Sdr_init_ref_vld) begin
                    // A missing response used to hold read-busy forever and
                    // block all later frame requests AND SDRAM writes. Once
                    // the controller has been quiet and idle for the whole
                    // watchdog interval, discard this frame and restart at
                    // the next request; never mix epochs in the pixel FIFOs.
                    fifo_clear<=1;read_frame_ready<=0;state<=IDLE;O_rd_busy<=0;
                end
                // The old pixel-rate update combined keep comparisons,
                // segment-end detection and a row/address mux in one 8 ns
                // cycle (routed slack -2.513 ns). Commit a complete burst,
                // then decide the next segment in a separate cycle instead.
                ADVANCE: begin
                    slide_addr<=slide_addr+slide_keep;
                    count_a<=count_a+(cube_latched ? cube_kept : slide_keep);
                    segment_left<=segment_left-slide_keep;
                    segment_ends<=(segment_left==slide_keep);
                    state<=NEXT_SEGMENT;
                end
                NEXT_SEGMENT: begin
                    if(segment_ends) begin
                        if(!segment_new && !new_empty) begin
                            slide_addr<=row_new;segment_new<=1;
                            segment_left<=cube_latched ? FRAME_WIDTH : new_width;
                        end else begin
                            row_old<=row_old_next;row_new<=row_new_next;
                            segment_new<=old_empty;
                            segment_left<=cube_latched ? FRAME_WIDTH : old_empty?new_width:old_width;
                            slide_addr<=old_empty?row_new_next:row_old_next;
                        end
                    end
                    state<=GUARD;
                end
                GUARD: if(guard_count==0) begin state<=CHECK;O_rd_busy<=0;end
                       else guard_count<=guard_count-1'b1;
                default:begin state<=IDLE;O_rd_busy<=0;end
            endcase
        end
    end
endmodule
`default_nettype wire
