package stats

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "core:os"
import "core:encoding/csv"
import "vendor:raylib"

import "../main"

Direction :: enum
{
    BELOW,
    ABOVE,
}

Outcome :: enum
{
    WIN,
    LOSS,
    NEAR_MISS,
}

VolumeProfileLevel :: enum
{
    POC,
    VWAP,
    VAL,
    VAH,
    TVVAL,
    TVVAH,
}

VolumeProfileSuccessDataRow :: struct
{
    timestamp : i32,
    level : VolumeProfileLevel,
    direction : Direction,
    outcome : Outcome,
    winPercentage : f32,
    lossPercentage : f32,
}

// Allocates dynamic array
//ExportPreviousDayVolumeProfileSuccessRate :: proc(chart : Chart) -> [dynamic]VolumeProfileSuccessDataRow
//{
//    WIN_MULTIPLE :: 1.01
//    LOSS_MULTIPLE :: 0.995
//    NEAR_MISS_MULTIPLE :: 1.00125
//
//    data := make([dynamic]VolumeProfileSuccessDataRow, 0, 4096)
//
//    for day, i in chart.candles[Timeframe.DAY].candles
//    {
//        startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
//        endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i) + 1)
//
//        profile := VolumeProfile_Create(startTimestamp, endTimestamp, day.high, day.low, chart, 25)
//        defer VolumeProfile_Destroy(profile)
//
//        startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE], endTimestamp)
//        // min to avoid an out of range exception on the final day
//        endIndex := math.min(CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE], CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i) + 2)), i32(len(chart.candles[Timeframe.MINUTE].candles)))
//
//        nextDataRow : VolumeProfileSuccessDataRow
//        nextDataRow.level = .VWAP
//
//        for minute, i in chart.candles[Timeframe.MINUTE].candles[startIndex:endIndex]
//        {
//            // If we're not currently in a test trade
//            if nextDataRow.timestamp == 0
//            {
//                if minute.open > profile.vwap
//                {
//                    // If trade is entered
//                    if minute.low <= profile.vwap
//                    {
//                    //    nextDataRow.timestamp = CandleList_IndexToTimestamp(chart.candles[Timeframe.MINUTE], startIndex + i32(i))
//                    //    nextDataRow.direction = .ABOVE
//                    }
//                    else if minute.low <= profile.vwap * NEAR_MISS_MULTIPLE
//                    {
//                        // This gets complicated, because I only want to count a near miss if it actually goes somewhere
//                        // If the near miss gets taken out shortly after, I don't want to record it as a near miss
//                        nextDataRow.timestamp = CandleList_IndexToTimestamp(chart.candles[Timeframe.MINUTE], startIndex + i32(i))
//                        nextDataRow.direction = .ABOVE
//                        nextDataRow.outcome = .NEAR_MISS
//                        nextDataRow.lossPercentage = -(minute.open - profile.vwap) / profile.vwap
//                        append(&data, nextDataRow)
//                        nextDataRow.timestamp = 0
//                    }
//                }
//            }
//
//            //if nextDataRow.timestamp != 0
//            //{
//            //    
//            //}
//        }
//    }
//
//    return data
//}