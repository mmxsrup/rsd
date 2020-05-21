// Copyright 2019- RSD contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.


//
// 2-read/write set-associative data cache
//

`include "BasicMacros.sv"

import BasicTypes::*;
import OpFormatTypes::*;
import CacheSystemTypes::*;
import OpFormatTypes::*;
import MemoryMapTypes::*;
import LoadStoreUnitTypes::*;

// Merge stored data and fetched line.
function automatic void MergeStoreDataToLine(
    output DCacheLinePath dstLine,
    input DCacheLinePath fetchedLine,
    input DCacheLinePath storedLine,
    input logic [DCACHE_LINE_BYTE_NUM-1:0] storedDirty
);
    for (int i = 0; i < DCACHE_LINE_BYTE_NUM; i++) begin
        for (int b = 0; b < 8; b++) begin
            dstLine[i*8 + b] = storedDirty[i] ? storedLine[i*8 + b] : fetchedLine[i*8 + b];
        end
    end
endfunction



// To a line address (index+tag) from a full address.
function automatic PhyAddrPath ToLineAddrFromFullAddr(input PhyAddrPath addr);
    return {
        addr[PHY_ADDR_WIDTH-1 : DCACHE_LINE_BYTE_NUM_BIT_WIDTH],
        { DCACHE_LINE_BYTE_NUM_BIT_WIDTH{1'b0} }
    };
endfunction

// To a line address (index+tag) part from a full address.
function automatic DCacheLineAddr ToLinePartFromFullAddr(input PhyAddrPath addr);
    return addr[PHY_ADDR_WIDTH-1 : DCACHE_LINE_BYTE_NUM_BIT_WIDTH];
endfunction

// To a line index from a full address.
function automatic DCacheIndexPath ToIndexPartFromFullAddr(input PhyAddrPath addr);
    return addr[PHY_ADDR_WIDTH-DCACHE_TAG_BIT_WIDTH-1 : DCACHE_LINE_BYTE_NUM_BIT_WIDTH];
endfunction

// To a line tag from a full address.
function automatic DCacheTagPath ToTagPartFromFullAddr(input PhyAddrPath addr);
    return addr[PHY_ADDR_WIDTH - 1 : PHY_ADDR_WIDTH - DCACHE_TAG_BIT_WIDTH];
endfunction

// Build a full address from index and tag parts.
function automatic PhyAddrPath BuildFullAddr(input DCacheIndexPath index, input DCacheTagPath tag);
    return {
        tag,
        index,
        { DCACHE_LINE_BYTE_NUM_BIT_WIDTH{1'b0} }
    };
endfunction

// To a part of a line index from a full address.
function automatic DCacheIndexSubsetPath ToIndexSubsetPartFromFullAddr(input PhyAddrPath addr);
    return addr[DCACHE_LINE_BYTE_NUM_BIT_WIDTH+DCACHE_INDEX_SUBSET_BIT_WIDTH-1 : DCACHE_LINE_BYTE_NUM_BIT_WIDTH];
endfunction

// 0-cleared MSHR entry.
function automatic MissStatusHandlingRegister ClearedMSHR();
    MissStatusHandlingRegister mshr;
    mshr = '0;
    return mshr;
endfunction

//
// The arbiter of the ports of the main memory.
//
module DCacheMemoryReqPortArbiter(DCacheIF.DCacheMemoryReqPortArbiter port);

    logic req[MSHR_NUM];
    logic grant[MSHR_NUM];
    MSHR_IndexPath memInSel;
    logic memValid;

    always_comb begin
        // Clear
        for (int r = 0; r < MSHR_NUM; r++) begin
            grant[r] = FALSE;
            req[r] = port.mshrMemReq[r];
        end

        // Arbitrate
        memInSel = '0;
        memValid = FALSE;
        for (int r = 0; r < MSHR_NUM; r++) begin
            if (req[r]) begin
                grant[r] = TRUE;
                memInSel = r;
                memValid = TRUE;
                break;
            end
        end

        // Outputs
        port.memInSel = memInSel;
        port.memValid = memValid;
        for (int r = 0; r < MSHR_NUM; r++) begin
            port.mshrMemGrt[r] = grant[r];
        end
    end

endmodule : DCacheMemoryReqPortArbiter

//
// Multiplexer for a memory signals
//

module DCacheMemoryReqPortMultiplexer(DCacheIF.DCacheMemoryReqPortMultiplexer port);

    MSHR_IndexPath portIn;
    always_comb begin

        portIn = port.memInSel;

        port.memAddr = port.mshrMemMuxIn[portIn].addr;
        port.memData = port.mshrMemMuxIn[portIn].data;
        port.memWE = port.mshrMemMuxIn[portIn].we;

        for (int i = 0; i < MSHR_NUM; i++) begin
            port.mshrMemMuxOut[i].ack = port.memReqAck;
            port.mshrMemMuxOut[i].serial = port.memSerial;
            port.mshrMemMuxOut[i].wserial = port.memWSerial;
        end

    end

endmodule : DCacheMemoryReqPortMultiplexer


//
// An arbiter of the ports of the tag/data array.
// 以下から来るアクセス要求に対して，最大 DCache のポート分だけ grant を返す
//   load unit/store unit: port.lsuCacheReq 
//   mshr の全エントリ:     mshrCacheReq    
// 
//   cacheArrayInSel[P]=r: 
//     上記の R個 リクエストのうち，r 番目 が
//     キャッシュの p 番目のポートに割り当てられた
//   cacheArrayOutSel[r]=p, grant[r]: 
//     上記の R個 リクエストのうち，r 番目 が
//     キャッシュの p 番目のポートに割り当てられた
//
// 典型的には，
//   grant[0]: load, grant[1]: store, grant[2],grant[3]...: mshr
//
module DCacheArrayPortArbiter(DCacheIF.DCacheArrayPortArbiter port);

    logic req[DCACHE_MUX_PORT_NUM];
    logic grant[DCACHE_MUX_PORT_NUM];
    DCacheMuxPortIndexPath cacheArrayInSel[DCACHE_ARRAY_PORT_NUM];
    DCacheArrayPortIndex   cacheArrayOutSel[DCACHE_MUX_PORT_NUM];

    always_comb begin
        // Clear
        for (int r = 0; r < DCACHE_MUX_PORT_NUM; r++) begin
            cacheArrayOutSel[r] = '0;
            grant[r] = FALSE;
        end

        // Merge inputs.
        for (int r = 0; r < DCACHE_LSU_PORT_NUM; r++) begin
            req[r] = port.lsuCacheReq[r];
        end
        for (int r = 0; r < MSHR_NUM; r++) begin
            req[r + DCACHE_LSU_PORT_NUM] = port.mshrCacheReq[r];
        end

        // Arbitrate
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++ ) begin
            cacheArrayInSel[p] = '0;
            for (int r = 0; r < DCACHE_MUX_PORT_NUM; r++) begin
                if (req[r]) begin
                    req[r] = FALSE;
                    grant[r] = TRUE;
                    cacheArrayInSel[p] = r;
                    cacheArrayOutSel[r] = p;
                    break;
                end
            end
        end

        // Outputs
        port.cacheArrayInSel = cacheArrayInSel;
        port.cacheArrayOutSel = cacheArrayOutSel;

        for (int r = 0; r < DCACHE_LSU_PORT_NUM; r++) begin
            port.lsuCacheGrt[r] = grant[r];
        end
        for (int r = 0; r < MSHR_NUM; r++) begin
            port.mshrCacheGrt[r] = grant[r + DCACHE_LSU_PORT_NUM];
        end
    end

endmodule : DCacheArrayPortArbiter



//
// Multiplexer for d-cache signals
//
// DCacheArrayPortArbiter でアービトレーションした結果に基づき，
// DCache の各ポートと load/store/mshr の各ユニットをスイッチする．
// DCache アクセスはパイプライン化されているため，スイッチもパイプラインの各ステージ
// にあわせて行われる．
//
module DCacheArrayPortMultiplexer(DCacheIF.DCacheArrayPortMultiplexer port);

    DCacheMuxPortIndexPath portIn;
    DCacheMuxPortIndexPath portInRegTagStg[DCACHE_ARRAY_PORT_NUM];

    DCacheArrayPortIndex portOutRegTagStg[DCACHE_MUX_PORT_NUM];
    DCacheArrayPortIndex portOutRegDataStg[DCACHE_MUX_PORT_NUM];

    DCachePortMultiplexerIn muxIn[DCACHE_MUX_PORT_NUM];
    DCachePortMultiplexerIn muxInReg[DCACHE_ARRAY_PORT_NUM];    // DCACHE_ARRAY_PORT_NUM!

    DCachePortMultiplexerTagOut muxTagOut[DCACHE_MUX_PORT_NUM];
    DCachePortMultiplexerDataOut muxDataOut[DCACHE_MUX_PORT_NUM];

    logic tagHit[DCACHE_ARRAY_PORT_NUM];
    logic mshrConflict[DCACHE_ARRAY_PORT_NUM];

    logic mshrAddrHit[DCACHE_ARRAY_PORT_NUM];
    MSHR_IndexPath mshrAddrHitMSHRID[DCACHE_ARRAY_PORT_NUM];
    logic mshrReadHit[DCACHE_ARRAY_PORT_NUM];
    DCacheLinePath mshrReadData[DCACHE_ARRAY_PORT_NUM];
    DCacheLinePath portMSHRData[MSHR_NUM];
    logic portMSHRCanBeInvalid[MSHR_NUM];

    // *** Hack for Synplify...
    // Signals in an interface are set to temproraly signals for avoiding
    // errors outputted by Synplify.
    DCacheTagPath   tagArrayDataOutTmp[DCACHE_ARRAY_PORT_NUM];
    logic           tagArrayValidOutTmp[DCACHE_ARRAY_PORT_NUM];
    logic           dataArrayDirtyOutTmp[DCACHE_ARRAY_PORT_NUM];
    DCacheLinePath  dataArrayDataOutTmp[DCACHE_ARRAY_PORT_NUM];


    always_ff @(posedge port.clk) begin


        for (int i = 0; i < DCACHE_ARRAY_PORT_NUM; i++) begin
            if (port.rst) begin
                portInRegTagStg[i] <= '0;
                muxInReg[i] <= '0;
            end
            else begin
                portInRegTagStg[i] <= port.cacheArrayInSel[i];
                muxInReg[i] <= muxIn[ port.cacheArrayInSel[i] ];
            end

        end

        for (int i = 0; i < DCACHE_MUX_PORT_NUM; i++) begin
            if (port.rst) begin
                portOutRegTagStg[i] <= '0;
                portOutRegDataStg[i] <= '0;
            end
            else begin
                portOutRegTagStg[i] <= port.cacheArrayOutSel[i];
                portOutRegDataStg[i] <= portOutRegTagStg[i];
            end
        end

    end


    always_comb begin

        // Merge inputs.
        for (int r = 0; r < DCACHE_LSU_PORT_NUM; r++) begin
            muxIn[r] = port.lsuMuxIn[r];
        end
        for (int r = 0; r < MSHR_NUM; r++) begin
            muxIn[r + DCACHE_LSU_PORT_NUM] = port.mshrCacheMuxIn[r];
        end

        for (int r = 0; r < MSHR_NUM; r++) begin
            portMSHRCanBeInvalid[r] = FALSE;
            portMSHRData[r] = port.mshrData[r];
        end


        //
        // stage:   | ADDR   | D$TAG    | D$DATA   |
        // process: | tag-in | tag-out  |          |
        //          |        | hit/miss |          |
        //          |        | data-in  | data-out |
        //
        // Pipeline regs between ADDR<>D$TAG:   portInRegTagStg, portOutRegTagStg, muxInReg
        // Pipeline regs between D$TAG<>D$DATA: portOutRegDataStg
        //

        // --- Address calculation stage (ADDR, MemoryExecutionStage).
        // Tag array inputs
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            portIn = port.cacheArrayInSel[p];
            port.tagArrayWE[p]      = muxIn[ portIn ].tagWE;
            port.tagArrayIndexIn[p] = muxIn[ portIn ].indexIn;
            port.tagArrayDataIn[p]  = muxIn[ portIn ].tagDataIn;
            port.tagArrayValidIn[p] = muxIn[ portIn ].tagValidIn;
        end


        // --- Tag access stage (D$TAG, MemoryTagAccessStage).

        tagArrayDataOutTmp = port.tagArrayDataOut;
        tagArrayValidOutTmp = port.tagArrayValidOut;

        // Hit/miss detection
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            mshrConflict[p] = FALSE;
            mshrReadHit[p] = FALSE;
            mshrAddrHit[p] = FALSE;
            mshrAddrHitMSHRID[p] = '0;
            mshrReadData[p] = '0;
            for (int m = 0; m < MSHR_NUM; m++) begin
                if (port.mshrValid[m] &&
                    muxInReg[p].indexIn == ToIndexPartFromFullAddr(port.mshrAddr[m])
                ) begin
                    mshrConflict[p] = TRUE;

                    // When request addr hits mshr,
                    // 1. the mahr allocator load must bypass data from MSHR,
                    // 2. other loads can bypass data from MSHR if possoble.
                    if (muxInReg[p].tagDataIn == ToTagPartFromFullAddr(port.mshrAddr[m])) begin
                        // To bypass data from MSHR.
                        if (port.mshrPhase[m] > (MSHR_PHASE_MISS_WRITE_CACHE_REQUEST-1)) begin
                            if (muxInReg[p].makeMSHRCanBeInvalid) begin
                                portMSHRCanBeInvalid[m] = TRUE;
                            end
                            mshrReadHit[p] = TRUE;
                        end
                        mshrAddrHit[p] = TRUE;
                        mshrAddrHitMSHRID[p] = m;
                        mshrReadData[p] = portMSHRData[m];
                    end
                end
            end

            tagHit[p] =
                (tagArrayDataOutTmp[p] == muxInReg[p].tagDataIn) &&
                tagArrayValidOutTmp[p] &&
                !mshrConflict[p];
        end

        // Tag array outputs
        for (int r = 0; r < DCACHE_MUX_PORT_NUM; r++) begin
            muxTagOut[r].tagDataOut  = tagArrayDataOutTmp[ portOutRegTagStg[r] ];
            muxTagOut[r].tagValidOut = tagArrayValidOutTmp[ portOutRegTagStg[r] ];
            muxTagOut[r].tagHit = tagHit[ portOutRegTagStg[r] ];
            muxTagOut[r].mshrConflict = mshrConflict[ portOutRegTagStg[r] ];
            muxTagOut[r].mshrReadHit = mshrReadHit[ portOutRegTagStg[r] ];
            muxTagOut[r].mshrAddrHit = mshrAddrHit[ portOutRegTagStg[r] ];
            muxTagOut[r].mshrAddrHitMSHRID = mshrAddrHitMSHRID[ portOutRegTagStg[r] ];
            muxTagOut[r].mshrReadData = mshrReadData[ portOutRegTagStg[r] ];
        end


        for (int r = 0; r < MSHR_NUM; r++) begin
            port.mshrCanBeInvalid[r] = portMSHRCanBeInvalid[r];
        end

        // Data array inputs
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            port.dataArrayDataIn[p]     = muxInReg[p].dataDataIn;
            port.dataArrayDirtyIn[p]    = muxInReg[p].dataDirtyIn;
            port.dataArrayByteWE_In[p]  = muxInReg[p].dataByteWE;
            port.dataArrayWE[p]         =
                muxInReg[p].dataWE || (muxInReg[p].dataWE_OnTagHit && tagHit[p]);
            port.dataArrayIndexIn[p]    = muxInReg[p].indexIn;
        end


        // ---Data array access stage (D$DATA, MemoryAccessStage).
        // Data array outputs
        dataArrayDataOutTmp = port.dataArrayDataOut;
        dataArrayDirtyOutTmp = port.dataArrayDirtyOut;
        for (int r = 0; r < DCACHE_MUX_PORT_NUM; r++) begin
            muxDataOut[r].dataDataOut = dataArrayDataOutTmp[ portOutRegDataStg[r] ];
            muxDataOut[r].dataDirtyOut = dataArrayDirtyOutTmp[ portOutRegDataStg[r] ];
        end
    end


    // Output to each port.
    always_comb begin
        for (int r = 0; r < DCACHE_LSU_PORT_NUM; r++) begin
            port.lsuMuxTagOut[r] = muxTagOut[r];
            port.lsuMuxDataOut[r] = muxDataOut[r];
        end
        for (int r = 0; r < MSHR_NUM; r++) begin
            port.mshrCacheMuxTagOut[r] = muxTagOut[r + DCACHE_LSU_PORT_NUM];
            port.mshrCacheMuxDataOut[r] = muxDataOut[r + DCACHE_LSU_PORT_NUM];
        end
    end

endmodule : DCacheArrayPortMultiplexer


//
// Tag/data/dirty bits array.
//
module DCacheArray(DCacheIF.DCacheArray port);
    // Data array signals
    logic dataArrayWE[DCACHE_WAY_NUM][DCACHE_ARRAY_PORT_NUM];
    logic dataArrayByteWE[DCACHE_LINE_BYTE_NUM][DCACHE_WAY_NUM][DCACHE_ARRAY_PORT_NUM];
    DCacheIndexPath dataArrayIndex[DCACHE_ARRAY_PORT_NUM];
    BytePath        dataArrayIn[DCACHE_LINE_BYTE_NUM][DCACHE_ARRAY_PORT_NUM];
    BytePath        dataArrayOut[DCACHE_LINE_BYTE_NUM][DCACHE_WAY_NUM][DCACHE_ARRAY_PORT_NUM];
    logic           dataArrayDirtyIn[DCACHE_ARRAY_PORT_NUM];
    logic           dataArrayDirtyOut[DCACHE_WAY_NUM][DCACHE_ARRAY_PORT_NUM];

    // *** Hack for Synplify...
    DCacheByteEnablePath dataArrayByteWE_Tmp[DCACHE_ARRAY_PORT_NUM];
    DCacheLinePath dataArrayInTmp[DCACHE_ARRAY_PORT_NUM];
    DCacheLinePath dataArrayOutTmp[DCACHE_ARRAY_PORT_NUM];

    // Tag array signals
    logic tagArrayWE[DCACHE_WAY_NUM][DCACHE_ARRAY_PORT_NUM];
    DCacheIndexPath tagArrayIndex[DCACHE_ARRAY_PORT_NUM];
    DCacheTagValidPath tagArrayIn[DCACHE_ARRAY_PORT_NUM];
    DCacheTagValidPath tagArrayOut[DCACHE_WAY_NUM][DCACHE_ARRAY_PORT_NUM];

    // Reset signals
    DCacheIndexPath rstIndex;

    DCacheWayPath hitWay;
    DCacheWayPath wayToEvict;

    always_ff @(posedge port.clk) begin
        if (port.rstStart)
            rstIndex <= '0;
        else
            rstIndex <= rstIndex + 1;
    end


    generate
        for (genvar way = 0; way < DCACHE_WAY_NUM; way++) begin
            // Data array instance
            for (genvar i = 0; i < DCACHE_LINE_BYTE_NUM; i++) begin
                BlockTrueDualPortRAM #(
                    .ENTRY_NUM( DCACHE_INDEX_NUM ),
                    .ENTRY_BIT_SIZE( $bits(BytePath) )
                    //.PORT_NUM( DCACHE_ARRAY_PORT_NUM )
                ) dataArray (
                    .clk( port.clk ),
                    .we( dataArrayByteWE[i][way] ),
                    .rwa( dataArrayIndex ),
                    .wv( dataArrayIn[i] ),
                    .rv( dataArrayOut[i][way] )
                );
            end

            // Dirty array instance
            // The dirty array is synchronized with the data array.
            BlockTrueDualPortRAM #(
                .ENTRY_NUM( DCACHE_INDEX_NUM ),
                .ENTRY_BIT_SIZE( 1 )
                //.PORT_NUM( DCACHE_ARRAY_PORT_NUM )
            ) dirtyArray (
                .clk( port.clk ),
                .we( dataArrayWE[way] ),
                .rwa( dataArrayIndex ),
                .wv( dataArrayDirtyIn ),
                .rv( dataArrayDirtyOut[way] )
            );

            // Tag array instance
            BlockTrueDualPortRAM #(
                .ENTRY_NUM( DCACHE_INDEX_NUM ),
                .ENTRY_BIT_SIZE( $bits(DCacheTagValidPath) )
                //.PORT_NUM( DCACHE_ARRAY_PORT_NUM )
            ) tagArray (
                .clk( port.clk ),
                .we( tagArrayWE[way] ),
                .rwa( tagArrayIndex ),
                .wv( tagArrayIn ),
                .rv( tagArrayOut[way] )
            );
        end
    endgenerate


    always_comb begin

        // Check cache hit
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            hitWay[p] = '0;
            // Detect which way is hit
            for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                if (tagArrayOut[way][p].valid && tagArrayOut[way][p].tag == port.tagArrayDataIn[p]) begin
                    hitWay[p] = way;
                    break;
                end
            end
        end

        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            wayToEvict[p] = '0;
        end


        // Data array signals
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                dataArrayWE[way][p] = FALSE;
            end
            dataArrayIndex[p] = port.dataArrayIndexIn[p];
            dataArrayDirtyIn[p] = port.dataArrayDirtyIn[p];
            dataArrayWE[wayToEvict[p]][p] = port.dataArrayWE[p];
        end

        // *** Hack for Synplify...
        // Signals in an interface are set to temproraly signals for avoiding
        // errors outputted by Synplify.
        dataArrayByteWE_Tmp = port.dataArrayByteWE_In;
        dataArrayInTmp = port.dataArrayDataIn;

        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            for (int i = 0; i < DCACHE_LINE_BYTE_NUM; i++) begin
                for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                    dataArrayByteWE[i][way][p] = FALSE;
                end
                dataArrayByteWE[i][wayToEvict[p]][p] = port.dataArrayWE[p] && dataArrayByteWE_Tmp[p][i];
                for (int b = 0; b < 8; b++) begin
                    dataArrayIn[i][p][b] = dataArrayInTmp[p][i*8 + b];
                    dataArrayOutTmp[p][i*8 + b] = dataArrayOut[i][hitWay[p]][p][b];
                end
            end
        end

        port.dataArrayDataOut = dataArrayOutTmp;
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            port.dataArrayDirtyOut[p] = dataArrayDirtyOut[hitWay[p]][p];
        end


        // Tag signals
        for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
            for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                tagArrayWE[way][p] = FALSE;
            end
            tagArrayIndex[p]    = port.tagArrayIndexIn[p];
            tagArrayWE[wayToEvict[p]][p]       = port.tagArrayWE[p];
            tagArrayIn[p].tag   = port.tagArrayDataIn[p];
            tagArrayIn[p].valid = port.tagArrayValidIn[p];

            port.tagArrayDataOut[p]  = tagArrayOut[hitWay[p]][p].tag;
            port.tagArrayValidOut[p] = tagArrayOut[hitWay[p]][p].valid;
        end


        // Reset
        if (port.rst) begin
            for (int p = 0; p < DCACHE_ARRAY_PORT_NUM; p++) begin
                for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                    for (int i = 0; i < DCACHE_LINE_BYTE_NUM; i++) begin
                        dataArrayByteWE[i][way][p] = FALSE;
                    end
                    tagArrayWE[way][p] = FALSE;
                end
            end

            // Port 0 is used for reset.
            for (int i = 0; i < DCACHE_LINE_BYTE_NUM; i++) begin
                for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                    dataArrayByteWE[i][way][0] = TRUE;
                end
                dataArrayIn[i][0] = 8'hcd;
            end

            for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                dataArrayWE[way][0] = TRUE;
            end

            dataArrayIndex[0] = rstIndex;
            dataArrayDirtyIn[0] = FALSE;

            tagArrayIndex[0] = rstIndex;
            for (int way = 0; way < DCACHE_WAY_NUM; way++) begin
                tagArrayWE[way][0] = TRUE;
            end
            tagArrayIn[0].tag = 0;
            tagArrayIn[0].valid = FALSE;


        end
    end

endmodule : DCacheArray

//
// Data cache main module.
//
module DCache(
    LoadStoreUnitIF.DCache lsu,
    CacheSystemIF.DCache cacheSystem,
    ControllerIF.DCache ctrl
);

    logic hit[DCACHE_LSU_PORT_NUM];
    logic missReq[DCACHE_LSU_PORT_NUM];
    PhyAddrPath missAddr[DCACHE_LSU_PORT_NUM];


    // Tag array
    DCacheIF port(lsu.clk, lsu.rst, lsu.rstStart);

    DCacheArray array(port);
    DCacheArrayPortArbiter arrayArbiter(port);
    DCacheArrayPortMultiplexer arrayMux(port);

    DCacheMemoryReqPortArbiter memArbiter(port);
    DCacheMemoryReqPortMultiplexer memMux(port);

    DCacheMissHandler missHandler(port);


    // Stored data
    DCacheLinePath storedLineData;
    logic [DCACHE_LINE_BYTE_NUM-1:0] storedLineByteWE;

    // Pipeline registers
    //
    // ----------------------------->
    // ADDR  | D$TAG | D$DATA | WB
    //       |  LSQ  |        |
    // Addresses are input to the tag array in the ADDR stage (MemoryExecutionStage).
    //
    PhyAddrPath dcReadAddrRegTagStg[DCACHE_LSU_READ_PORT_NUM];
    PhyAddrPath dcReadAddrRegDataStg[DCACHE_LSU_READ_PORT_NUM];
    logic dcReadReqReg[DCACHE_LSU_READ_PORT_NUM];
    logic lsuCacheGrtReg[DCACHE_LSU_PORT_NUM];

    logic dcWriteReqReg;
    PhyAddrPath dcWriteAddrReg;


    logic lsuLoadHasAllocatedMSHR[DCACHE_LSU_READ_PORT_NUM];
    MSHR_IndexPath lsuLoadMSHRID[DCACHE_LSU_READ_PORT_NUM];
    logic lsuStoreHasAllocatedMSHR[DCACHE_LSU_WRITE_PORT_NUM];
    MSHR_IndexPath lsuStoreMSHRID[DCACHE_LSU_WRITE_PORT_NUM];

    // MSHRからのLoad
    logic lsuMSHRAddrHit[DCACHE_LSU_READ_PORT_NUM];
    MSHR_IndexPath lsuMSHRAddrHitMSHRID[DCACHE_LSU_READ_PORT_NUM];
    logic lsuMSHRReadHit[DCACHE_LSU_READ_PORT_NUM];
    DCacheLinePath lsuMSHRReadData[DCACHE_LSU_READ_PORT_NUM];

    // MSHRをAllocateした命令からのメモリリクエストかどうか
    // MSHRをAllocateしたLoad命令がMemoryRegisterReadStageでflushされた場合，AllocateされたMSHRは解放可能になる
    logic lsuMakeMSHRCanBeInvalidByMemoryRegisterReadStage[MSHR_NUM];

    // そのリクエストがアクセスに成功した場合，AllocateされたMSHRは解放可能になる
    logic lsuMakeMSHRCanBeInvalid[DCACHE_LSU_READ_PORT_NUM];

    // MSHRをAllocateしたLoad命令がStoreForwardingによって完了した場合，AllocateされたMSHRは解放可能になる
    logic lsuMakeMSHRCanBeInvalidByMemoryTagAccessStage[MSHR_NUM];

    // MSHRをAllocateしたLoad命令がReplayQueueの先頭でflushされた場合，AllocateされたMSHRは解放可能になる
    logic lsuMakeMSHRCanBeInvalidByReplayQueue[MSHR_NUM];

`ifndef RSD_SYNTHESIS
    `ifndef RSD_VIVADO_SIMULATION
        // Don't care these values, but avoiding undefined status in Questa.
        initial begin
            for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
                dcReadAddrRegTagStg[i] = '0;
                dcReadAddrRegDataStg[i] = '0;
            end
            dcWriteAddrReg = '0;
        end
    `endif
`endif

    always_ff @(posedge port.clk) begin
        if (port.rst) begin
            for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
                dcReadReqReg[i] <= FALSE;
            end
            for (int i = 0; i < DCACHE_LSU_PORT_NUM; i++) begin
                lsuCacheGrtReg[i] <= FALSE;
            end
            dcWriteReqReg <= '0;
        end
        else begin
            lsuCacheGrtReg <= port.lsuCacheGrt;

            for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
                dcReadReqReg[i] <= lsu.dcReadReq[i];
                dcReadAddrRegTagStg[i] <= lsu.dcReadAddr[i];
            end

            dcReadAddrRegDataStg <= dcReadAddrRegTagStg;

            dcWriteReqReg <= lsu.dcWriteReq;
            dcWriteAddrReg <= lsu.dcWriteAddr;
        end
    end

`ifdef RSD_ENABLE_VECTOR_PATH
    `RSD_STATIC_ASSERT(
        $bits(VectorPath) == $bits(DCacheLinePath), 
        "The width of a DCache line must be same as the width of a vector register."
    );
`endif

    `RSD_STATIC_ASSERT(
        $bits(LSQ_BlockDataPath) <= $bits(DCacheLinePath), 
        "The width of a DCache line must be same or greater than that of an LSQ block."
    );

    always_comb begin

        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            lsuMakeMSHRCanBeInvalid[i] = lsu.makeMSHRCanBeInvalid[i];
        end

        // --- In the address execution stage (MemoryExecutionStage)
        // Load request
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin

            port.lsuCacheReq[(i+DCACHE_LSU_READ_PORT_BEGIN)] = lsu.dcReadReq[i];
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].tagWE = FALSE;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].indexIn = ToIndexPartFromFullAddr(lsu.dcReadAddr[i]);
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].tagDataIn = ToTagPartFromFullAddr(lsu.dcReadAddr[i]);
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].tagValidIn = TRUE;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].dataDataIn = '0;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].dataByteWE = '0;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].dataWE = FALSE;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].dataWE_OnTagHit = FALSE;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].dataDirtyIn = FALSE;
            port.lsuMuxIn[(i+DCACHE_LSU_READ_PORT_BEGIN)].makeMSHRCanBeInvalid = lsuMakeMSHRCanBeInvalid[i];
        end

        // --- In the tag access stage (MemoryTagAccessStage)
        // Hit/miss detection
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            hit[i] = FALSE;
            if (port.lsuMuxTagOut[(i+DCACHE_LSU_READ_PORT_BEGIN)].tagHit && lsuCacheGrtReg[(i+DCACHE_LSU_READ_PORT_BEGIN)]) begin
                hit[i] = TRUE;
            end
        end

        //
        // --- In the data array access stage.
        // Load data from a cache line.
        //
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            // Read data address is aligned to word boundary in ReadDataFromLine.
            lsu.dcReadData[i] = port.lsuMuxDataOut[i].dataDataOut;
            lsu.dcReadHit[i] = hit[i];
        end
/*
        for (int i = DCACHE_LSU_READ_PORT_NUM; i < MEM_ISSUE_WIDTH; i++) begin
            lsu.dcReadData[i] = '0;
            lsu.dcReadHit[i] = FALSE;
            
        end
*/


        // --- In the first stage of the commit stages.
        // Write request


        for (int i = 0; i < DCACHE_LSU_WRITE_PORT_NUM; i++) begin
            assert(DCACHE_LSU_WRITE_PORT_NUM == 1);

            // Write data is not aligned?
            storedLineData = lsu.dcWriteData;
            storedLineByteWE = lsu.dcWriteByteWE;

            port.lsuCacheReq[(i+DCACHE_LSU_WRITE_PORT_BEGIN)] = lsu.dcWriteReq;
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].tagWE = FALSE;    // First, stores read tag.
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].indexIn = ToIndexPartFromFullAddr(lsu.dcWriteAddr);
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].tagDataIn = ToTagPartFromFullAddr(lsu.dcWriteAddr);
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].tagValidIn = TRUE;
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].dataDataIn = storedLineData;
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].dataByteWE = storedLineByteWE;
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].dataWE = FALSE;
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].dataWE_OnTagHit = TRUE;
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].dataDirtyIn = TRUE;
            // ストアはコミット時に初めて MSHR にアクセスするので，キャンセルはしないはず？
            port.lsuMuxIn[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].makeMSHRCanBeInvalid = FALSE;//lsuMakeMSHRCanBeInvalid[(i+DCACHE_LSU_WRITE_PORT_BEGIN)];

            lsu.dcWriteReqAck = port.lsuCacheGrt[(i+DCACHE_LSU_WRITE_PORT_BEGIN)];
        end


        // --- In the first stage of the commit stages.
        // Hit/miss detection

        for (int i = 0; i < DCACHE_LSU_WRITE_PORT_NUM; i++) begin
            assert(DCACHE_LSU_WRITE_PORT_NUM == 1);

            // Store data to the array after miss handling finishes.
            hit[(i+DCACHE_LSU_WRITE_PORT_BEGIN)] = FALSE;
            if (port.lsuMuxTagOut[(i+DCACHE_LSU_WRITE_PORT_BEGIN)].tagHit && lsuCacheGrtReg[(i+DCACHE_LSU_WRITE_PORT_BEGIN)]) begin
                hit[(i+DCACHE_LSU_WRITE_PORT_BEGIN)] = TRUE;
            end

            lsu.dcWriteHit = hit[(i+DCACHE_LSU_WRITE_PORT_BEGIN)];
        end

    end

    always_comb begin
        port.storedLineData = storedLineData;
        port.storedLineByteWE = storedLineByteWE;
    end

    //
    // --- Miss requests.
    // In the tag access stage/second commit stage.
    //
    always_comb begin

        // Read requests from a memory execution stage.
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            missReq[i] = 
                !hit[i] && 
                !port.lsuMuxTagOut[i].mshrConflict && 
                dcReadReqReg[i] && 
                lsuCacheGrtReg[i] && 
                !lsu.dcReadCancelFromMT_Stage[i];
            missAddr[i] = dcReadAddrRegTagStg[i];
        end

        // Write requests from a store queue commitor.
        for (int i = DCACHE_LSU_WRITE_PORT_BEGIN; i < DCACHE_LSU_WRITE_PORT_NUM + DCACHE_LSU_READ_PORT_NUM; i++) begin
            assert(DCACHE_LSU_WRITE_PORT_NUM == 1);
            missReq[i] = !hit[i] && !port.lsuMuxTagOut[i].mshrConflict && dcWriteReqReg && lsuCacheGrtReg[i];
            missAddr[i] = dcWriteAddrReg;
        end

    end


    // 1. MSHR 登録
    //   * 確保できない場合，待たせる
    //   * 以降は MSHR 登録アドレスへの操作は全部ブロック
    logic mshrConflict[DCACHE_LSU_PORT_NUM];

        // Miss handler
    logic portInitMSHR[MSHR_NUM];
    PhyAddrPath portInitMSHR_Addr[MSHR_NUM];
    logic portIsAllocatedByStore[MSHR_NUM];

    always_comb begin

        // MSHR alloc signals for ReplayQueue
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            lsuLoadHasAllocatedMSHR[i] = FALSE;
            lsuLoadMSHRID[i] = '0;
        end

        // MSHR alloc signals for storeCommitter
        for (int i = 0; i < DCACHE_LSU_WRITE_PORT_NUM; i++) begin
            lsuStoreHasAllocatedMSHR[i] = FALSE;
            lsuStoreMSHRID[i] = '0;
        end

        // MSHR addr/data hit and data signals for MemoryAccessBackend
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            lsuMSHRAddrHit[i] = port.lsuMuxTagOut[i].mshrAddrHit;
            lsuMSHRAddrHitMSHRID[i] = port.lsuMuxTagOut[i].mshrAddrHitMSHRID;
            lsuMSHRReadHit[i] = port.lsuMuxTagOut[i].mshrReadHit;
            lsuMSHRReadData[i] = port.lsuMuxTagOut[i].mshrReadData;
        end

        for (int i = 0; i < DCACHE_LSU_PORT_NUM; i++) begin
            mshrConflict[i] = port.lsuMuxTagOut[i].mshrConflict;
        end

        // Check address conflict in missed access in this cycle.
        for (int i = 0; i < DCACHE_LSU_PORT_NUM; i++) begin
            for (int m = 0; m < i; m++) begin
                if (missReq[m] &&
                    ToIndexPartFromFullAddr(missAddr[i]) == ToIndexPartFromFullAddr(missAddr[m])
                ) begin
                    // An access with the same index cannot enter to the MSHR.
                    mshrConflict[i] = TRUE;
                end
            end
        end

        for (int i = 0; i < MSHR_NUM; i++) begin
            portInitMSHR[i] = FALSE;
            portInitMSHR_Addr[i] = '0;
            portIsAllocatedByStore[i] = FALSE;
        end

        for (int i = 0; i < DCACHE_LSU_PORT_NUM; i++) begin
            if (!missReq[i] || mshrConflict[i]) begin
                // This access hits the cache or is invalid.
                // An access with the same index cannot enter to the MSHR.
                continue;
            end

            // Search free MSHR entry and allocate.
            for (int m = 0; m < MSHR_NUM; m++) begin
                if (!port.mshrValid[m] && !portInitMSHR[m]) begin
                    portInitMSHR[m] = TRUE;
                    portInitMSHR_Addr[m] = missAddr[i];
                    if (i < DCACHE_LSU_READ_PORT_NUM) begin
                        lsuLoadHasAllocatedMSHR[i] = TRUE;
                        lsuLoadMSHRID[i] = m;
                    end
                    else begin
                        lsuStoreHasAllocatedMSHR[i-DCACHE_LSU_READ_PORT_NUM] = TRUE;
                        lsuStoreMSHRID[i-DCACHE_LSU_READ_PORT_NUM] = m;
                        portIsAllocatedByStore[m] = TRUE;
                    end
                    break;
                end
            end
        end

        for (int i = 0; i < MSHR_NUM; i++) begin
            port.initMSHR[i] = portInitMSHR[i];
            port.initMSHR_Addr[i] = portInitMSHR_Addr[i];
            port.isAllocatedByStore[i] = portIsAllocatedByStore[i];
        end

        // Output control signals
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            lsu.dcReadBusy[i] = mshrConflict[i];
        end
        lsu.dcWriteBusy = mshrConflict[DCACHE_LSU_WRITE_PORT_BEGIN];

        // MSHR addr/data hit and data signals for MemoryAccessBackend
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            lsu.mshrAddrHit[i] = lsuMSHRAddrHit[i];
            lsu.mshrAddrHitMSHRID[i] = lsuMSHRAddrHitMSHRID[i];
            lsu.mshrReadHit[i] = lsuMSHRReadHit[i];
            lsu.mshrReadData[i] = lsuMSHRReadData[i];
        end

        // MSHR alloc signals for ReplayQueue
        for (int i = 0; i < DCACHE_LSU_READ_PORT_NUM; i++) begin
            lsu.loadHasAllocatedMSHR[i] = lsuLoadHasAllocatedMSHR[i];
            lsu.loadMSHRID[i] = lsuLoadMSHRID[i];
        end

        // MSHR alloc signals for storeCommitter
        for (int i = 0; i < DCACHE_LSU_WRITE_PORT_NUM; i++) begin
            lsu.storeHasAllocatedMSHR[i] = lsuStoreHasAllocatedMSHR[i];
            lsu.storeMSHRID[i] = lsuStoreMSHRID[i];
        end

    end

    always_comb begin
        for (int i = 0; i < MSHR_NUM; i++) begin
            lsuMakeMSHRCanBeInvalidByMemoryRegisterReadStage[i] = lsu.makeMSHRCanBeInvalidByMemoryRegisterReadStage[i];
            lsuMakeMSHRCanBeInvalidByMemoryTagAccessStage[i] = lsu.makeMSHRCanBeInvalidByMemoryTagAccessStage[i];
            lsuMakeMSHRCanBeInvalidByReplayQueue[i] = lsu.makeMSHRCanBeInvalidByReplayQueue[i];
        end
    end

    always_comb begin
        for (int i = 0; i < MSHR_NUM; i++) begin
            port.makeMSHRCanBeInvalidByMemoryRegisterReadStage[i] = lsuMakeMSHRCanBeInvalidByMemoryRegisterReadStage[i];
            port.makeMSHRCanBeInvalidByMemoryTagAccessStage[i] = lsuMakeMSHRCanBeInvalidByMemoryTagAccessStage[i];
            port.makeMSHRCanBeInvalidByReplayQueue[i] = lsuMakeMSHRCanBeInvalidByReplayQueue[i];
        end
    end


    //
    // Main memory
    //
    always_comb begin
        cacheSystem.dcMemAccessReq.valid = port.memValid;
        cacheSystem.dcMemAccessReq.we = port.memWE;
        cacheSystem.dcMemAccessReq.addr = port.memAddr;
        cacheSystem.dcMemAccessReq.data = port.memData;
        // To notice mshr phases and addr subset to ReplayQueue.
        for (int i = 0; i < MSHR_NUM; i++) begin
            lsu.mshrPhase[i] = port.mshrPhase[i];
            lsu.mshrAddrSubset[i] = port.mshrAddrSubset[i];
            lsu.mshrValid[i] = port.mshrValid[i];
        end
        port.memReqAck = cacheSystem.dcMemAccessReqAck.ack;
        port.memSerial = cacheSystem.dcMemAccessReqAck.serial;
        port.memAccessResult = cacheSystem.dcMemAccessResult;
        port.memWSerial = cacheSystem.dcMemAccessReqAck.wserial;
        port.memAccessResponse = cacheSystem.dcMemAccessResponse;
    end

endmodule : DCache


module DCacheMissHandler(
    DCacheIF.DCacheMissHandler port
);

    MissStatusHandlingRegister nextMSHR[MSHR_NUM];
    MissStatusHandlingRegister mshr[MSHR_NUM];

    logic portIsAllocatedByStore[MSHR_NUM];
    DCacheLinePath mergedLine[MSHR_NUM];

`ifndef RSD_SYNTHESIS
    // Don't care these values, but avoiding undefined status in Questa.
    initial begin
        for (int i = 0; i < MSHR_NUM; i++) begin
            mshr[i] = '0;
        end
    end
`endif

    // MSHR
    always_ff@(posedge port.clk) begin
        if (port.rst) begin
            for (int i = 0; i < MSHR_NUM; i++) begin
                mshr[i].valid <= FALSE;
                mshr[i].phase <= MSHR_PHASE_INVALID;
                mshr[i].canBeInvalid <= FALSE;
                mshr[i].isAllocatedByStore <= FALSE;
            end
        end
        else begin
            mshr <= nextMSHR;
        end
    end

    always_comb begin
        for (int i = 0; i < MSHR_NUM; i++) begin
            // To notice mshr phases to ReplayQueue.
            port.mshrPhase[i] = mshr[i].phase;

            // To notice mshr newAddr subset to ReplayQueue.
            port.mshrAddrSubset[i] = ToIndexSubsetPartFromFullAddr(mshr[i].newAddr);

            // To bypass mshr data to load insts.
            port.mshrData[i] = mshr[i].line;

            port.mshrValid[i] = mshr[i].valid;
            port.mshrAddr[i] = mshr[i].newAddr;
        end
    end

    DCacheLinePath portStoredLineData;
    logic [DCACHE_LINE_BYTE_NUM-1:0] portStoredLineByteWE;
    always_comb begin
        portStoredLineData = port.storedLineData;
        portStoredLineByteWE = port.storedLineByteWE;
    end


    always_comb begin

        for (int i = 0; i < MSHR_NUM; i++) begin
            portIsAllocatedByStore[i] = port.isAllocatedByStore[i];
        end

        for (int i = 0; i < MSHR_NUM; i++) begin
            nextMSHR[i] = mshr[i];

            // Both MSHR_PHASE_VICTIM_READ_FROM_CACHE & MSHR_PHASE_MISS_WRITE_CACHE_REQUEST phases
            // use newAddr for a cache index.
            // The other phases do not use an index.
            port.mshrCacheMuxIn[i].indexIn = ToIndexPartFromFullAddr(mshr[i].newAddr);

            // Only MSHR_PHASE_MISS_WRITE_CACHE_REQUEST uses tagDataIn, dataByteWE and dataDataIn.
            port.mshrCacheMuxIn[i].tagDataIn = ToTagPartFromFullAddr(mshr[i].newAddr);
            port.mshrCacheMuxIn[i].dataDataIn = mshr[i].line;
            port.mshrCacheMuxIn[i].dataByteWE = {DCACHE_LINE_BYTE_NUM{1'b1}};
            port.mshrCacheMuxIn[i].tagValidIn = TRUE;        // Don't care for the other phases.

            // Other cache request signals.
            port.mshrCacheReq[i] = FALSE;
            port.mshrCacheMuxIn[i].tagWE = FALSE;
            port.mshrCacheMuxIn[i].dataWE = FALSE;
            port.mshrCacheMuxIn[i].dataWE_OnTagHit = FALSE;
            port.mshrCacheMuxIn[i].dataDirtyIn = FALSE;
            port.mshrCacheMuxIn[i].makeMSHRCanBeInvalid = FALSE;

            // Memory request signals
            port.mshrMemReq[i] = FALSE;
            port.mshrMemMuxIn[i].data = mshr[i].line;

            // Don't care
            port.mshrMemMuxIn[i].we = FALSE;
            port.mshrMemMuxIn[i].addr = mshr[i].victimAddr;

            case(mshr[i].phase)
                default: begin

                    // Initialize or read a  MSHR.
                    if (port.initMSHR[i]) begin
                        // 1. MSHR 登録
                        // Initial phase
                        nextMSHR[i].valid = TRUE;
                        nextMSHR[i].phase = MSHR_PHASE_VICTIM_REQEUST;
                        nextMSHR[i].newAddr = port.initMSHR_Addr[i];
                        nextMSHR[i].newValid = FALSE;
                        nextMSHR[i].victimValid = FALSE;

                        nextMSHR[i].victimDirty = FALSE;
                        nextMSHR[i].victimReceived = FALSE;
                        nextMSHR[i].memSerial = '0;
                        nextMSHR[i].memWSerial = '0;

                        nextMSHR[i].canBeInvalid = FALSE;
                        nextMSHR[i].isAllocatedByStore = portIsAllocatedByStore[i];

                        // Dont'care
                        //nextMSHR[i].line = '0;

                    end
                end


                // 2. リプレース対象の読み出し
                //  * フィル対象の決定
                //      if (セット内に invalid なウェイがある) {
                //          フィル対象 = invalid なウェイ
                //      } else {
                //          フィル対象 = LR Uの示すウェイ
                //      }
                //  * ラインの読み出し
                //      if (! 追い出し対象が invalid ){
                //          ラインをキャッシュから読み出す
                //      }
                MSHR_PHASE_VICTIM_REQEUST: begin
                    // Access the cache array.
                    port.mshrCacheReq[i] = TRUE;
                    port.mshrCacheMuxIn[i].tagWE = FALSE;
                    port.mshrCacheMuxIn[i].dataWE = FALSE;
                    port.mshrCacheMuxIn[i].dataWE_OnTagHit = FALSE;
                    port.mshrCacheMuxIn[i].dataDirtyIn = FALSE;

                    nextMSHR[i].phase =
                        port.mshrCacheGrt[i] ?
                        MSHR_PHASE_VICTIM_RECEIVE_TAG : MSHR_PHASE_VICTIM_REQEUST;
                end

                MSHR_PHASE_VICTIM_RECEIVE_TAG: begin
                    // Read a victim line.
                    if (port.mshrCacheMuxTagOut[i].tagValidOut) begin
                        nextMSHR[i].victimAddr =
                            BuildFullAddr(
                                ToIndexPartFromFullAddr(mshr[i].newAddr),
                                port.mshrCacheMuxTagOut[i].tagDataOut
                            );
                        nextMSHR[i].victimValid = TRUE;
                        nextMSHR[i].phase = MSHR_PHASE_VICTIM_RECEIVE_DATA;
                    end
                    else begin
                        nextMSHR[i].victimValid = FALSE;
                        // Skip receiving data and writing back.
                        nextMSHR[i].phase = MSHR_PHASE_MISS_READ_MEM_REQUEST;
                    end

                end


                MSHR_PHASE_VICTIM_RECEIVE_DATA: begin
                    // Receive cache data.
                    nextMSHR[i].victimReceived = TRUE;
                    nextMSHR[i].line = port.mshrCacheMuxDataOut[i].dataDataOut;
                    nextMSHR[i].victimDirty = port.mshrCacheMuxDataOut[i].dataDirtyOut;

                    if (nextMSHR[i].victimDirty) begin
                        nextMSHR[i].phase = MSHR_PHASE_VICTIM_WRITE_TO_MEM;
                    end
                    else begin
                        nextMSHR[i].phase = MSHR_PHASE_MISS_READ_MEM_REQUEST;
                    end
                end

                // 3. リプレース対象の書き出し
                // * if (! 追い出し対象が invalid ){
                //        ラインをメモリに書き出す
                //   }

                MSHR_PHASE_VICTIM_WRITE_TO_MEM: begin
                    port.mshrMemReq[i] = TRUE;
                    port.mshrMemMuxIn[i].we = TRUE;
                    port.mshrMemMuxIn[i].addr = mshr[i].victimAddr;

                    if (port.mshrMemGrt[i] && port.mshrMemMuxOut[i].ack) begin
                        nextMSHR[i].memWSerial = port.mshrMemMuxOut[i].wserial;
                        nextMSHR[i].phase = MSHR_PHASE_VICTIM_WRITE_COMPLETE;
                    end
                    else begin
                        // Waiting until the request is accepted.
                        nextMSHR[i].phase = MSHR_PHASE_VICTIM_WRITE_TO_MEM;
                    end

                end

                // 4. リプレース対象の書き込み完了まで待機
                MSHR_PHASE_VICTIM_WRITE_COMPLETE: begin
                    port.mshrMemReq[i] = FALSE;
                    if (mshr[i].victimValid &&
                        mshr[i].victimDirty &&
                        !(port.memAccessResponse.valid &&
                        mshr[i].memWSerial == port.memAccessResponse.serial)
                    ) begin
                        // Wait MSHR_PHASE_VICTIM_WRITE_TO_MEM.
                        nextMSHR[i].phase = MSHR_PHASE_VICTIM_WRITE_COMPLETE;
                    end
                    else begin
                        nextMSHR[i].phase = MSHR_PHASE_MISS_READ_MEM_REQUEST;
                    end
                end

                // 5. ミスデータのメモリからの読みだし
                MSHR_PHASE_MISS_READ_MEM_REQUEST: begin
                    /* メモリ書込はResultを待たないように仕様変更
                    if (mshr[i].victimValid &&
                        mshr[i].victimDirty &&
                        !(port.memAccessResult.valid &&
                        mshr[i].memSerial == port.memAccessResult.serial)
                    ) begin
                        // Wait MSHR_PHASE_VICTIM_WRITE_TO_MEM.
                        port.mshrMemReq[i] = FALSE;
                    end
                    */
                    //else begin
                    if (TRUE) begin
                        // A victim line has been written to the memory and
                        // data on an MSHR entry is not valid.
                        nextMSHR[i].victimValid = FALSE;

                        // Fetch a missed line.
                        port.mshrMemReq[i] = TRUE;
                        port.mshrMemMuxIn[i].we = FALSE;
                        port.mshrMemMuxIn[i].addr = ToLineAddrFromFullAddr(mshr[i].newAddr);

                        if (port.mshrMemGrt[i] && port.mshrMemMuxOut[i].ack) begin
                            nextMSHR[i].memSerial = port.mshrMemMuxOut[i].serial;
                            nextMSHR[i].phase = MSHR_PHASE_MISS_READ_MEM_RECEIVE;
                        end
                        else begin
                            // Waiting until the request is accepted.
                            nextMSHR[i].phase = MSHR_PHASE_MISS_READ_MEM_REQUEST;
                        end
                    end
                end

                // Receive memory data.
                MSHR_PHASE_MISS_READ_MEM_RECEIVE: begin
                    if (!(port.memAccessResult.valid &&
                        mshr[i].memSerial == port.memAccessResult.serial)
                    ) begin
                        // Waiting until data is received.
                        nextMSHR[i].phase = MSHR_PHASE_MISS_READ_MEM_RECEIVE;
                    end
                    else begin
                        // Set a fetched line to a MSHR entry and go to the next phase.
                        nextMSHR[i].line = port.memAccessResult.data;
                        nextMSHR[i].newValid = TRUE;
                        if (mshr[i].isAllocatedByStore) begin
                            nextMSHR[i].phase = MSHR_PHASE_MISS_MERGE_STORE_DATA;
                        end
                        else begin
                            nextMSHR[i].phase = MSHR_PHASE_MISS_WRITE_CACHE_REQUEST;
                        end
                    end
                end

                // 5.5. MSHRエントリの割り当て者がStore命令の場合，ミスデータとストア命令のデータを結合する
                MSHR_PHASE_MISS_MERGE_STORE_DATA: begin
                    // Merge the allocator store data and the fetched line.
                    MergeStoreDataToLine(mergedLine[i], mshr[i].line,
                        portStoredLineData, portStoredLineByteWE);
                    nextMSHR[i].line = mergedLine[i];
                    nextMSHR[i].phase = MSHR_PHASE_MISS_WRITE_CACHE_REQUEST;
                end


                // 6. ミスデータのキャッシュへの書き込み
                MSHR_PHASE_MISS_WRITE_CACHE_REQUEST: begin
                    // Fille the cache array.
                    port.mshrCacheReq[i] = TRUE;
                    port.mshrCacheMuxIn[i].tagWE = TRUE;
                    port.mshrCacheMuxIn[i].dataWE = TRUE;
                    port.mshrCacheMuxIn[i].dataWE_OnTagHit = FALSE;
                    port.mshrCacheMuxIn[i].dataDirtyIn = mshr[i].isAllocatedByStore;



                    if (port.mshrCacheGrt[i]) begin
                        // If my request is granted, miss handling finishes.
                        nextMSHR[i].phase = MSHR_PHASE_MISS_WRITE_CACHE_FINISH;
                    end
                    else begin
                        nextMSHR[i].phase = MSHR_PHASE_MISS_WRITE_CACHE_REQUEST;
                    end
                end

                // 7.データアレイへの書き込みと解放可能条件を待って MSHR 解放
                // 現在の開放可能条件は
                // ・割り当て者がLoadでそのLoadへのデータの受け渡しが完了した場合
                // ・割り当て者がStoreの場合 (該当Storeのデータはこの時点でキャッシュに書き込まれている)
                MSHR_PHASE_MISS_WRITE_CACHE_FINISH: begin
                    if (mshr[i].canBeInvalid || mshr[i].isAllocatedByStore) begin
                        nextMSHR[i].phase = MSHR_PHASE_INVALID;
                        nextMSHR[i].valid = FALSE;
                    end
                end
            endcase // case(mshr[i].phase)

            if (port.makeMSHRCanBeInvalidByMemoryRegisterReadStage[i]) begin
                // MSHR can be invalid when
                // its allocator load has been flushed at MemoryRegisterReadStage.
                nextMSHR[i].canBeInvalid = TRUE;
            end
            else if (port.makeMSHRCanBeInvalidByMemoryTagAccessStage[i]) begin
                // MSHR can be invalid when
                // its allocator load has completed correctly because of StoreForwarding.
                nextMSHR[i].canBeInvalid = TRUE;
            end
            else if (port.makeMSHRCanBeInvalidByReplayQueue[i]) begin
                // MSHR can be invalid when
                // its allocator load has been flushed at the top of ReplayQueue.
                nextMSHR[i].canBeInvalid = TRUE;
            end
            else if (port.mshrCanBeInvalid[i] && (mshr[i].phase >= MSHR_PHASE_MISS_WRITE_CACHE_REQUEST)) begin
                nextMSHR[i].canBeInvalid = TRUE;
            end
        end // for (int i = 0; i < MSHR_NUM; i++) begin
    end



endmodule : DCacheMissHandler

