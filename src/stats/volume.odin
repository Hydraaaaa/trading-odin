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

HalfHourCandleVolume :: struct
{
    volumeData : [48]VolumeData,
    highestValue : f32,
}

VolumeData :: struct
{
	values : [dynamic]f32,
	mean : f32,
	median : f32,
	Q1 : f32,
	Q3 : f32,
}

// Gets a box plot of the volume of each half hour of a day
GetHalfHourCandleVolume :: proc(chart : main.Chart) -> HalfHourCandleVolume
{
    using main

    MAY_17TH :: 358_905_600
    candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], MAY_17TH)
    candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

	volume : HalfHourCandleVolume

    for i := 0; i < len(candles); i += 48
    {
		for vol in 0 ..< len(volume.volumeData)
		{
			append(&volume.volumeData[vol].values, candles[i + vol].volume)
            volume.volumeData[vol].mean += candles[i + vol].volume
        }
	}

	for i in 0 ..< len(volume.volumeData)
    {
		volume.volumeData[i].mean /= f32(len(volume.volumeData[i].values))

		slice.sort(volume.volumeData[i].values[:])

		volume.volumeData[i].median = volume.volumeData[i].values[int(f32(len(volume.volumeData[i].values)) * 0.5)]
		volume.volumeData[i].Q1 = volume.volumeData[i].values[int(f32(len(volume.volumeData[i].values)) * 0.25)]
		volume.volumeData[i].Q3 = volume.volumeData[i].values[int(f32(len(volume.volumeData[i].values)) * 0.75)]

		volume.highestValue = math.max(volume.highestValue, volume.volumeData[i].mean)
		volume.highestValue = math.max(volume.highestValue, volume.volumeData[i].Q3)
	}

    return volume
}

// Gets a box plot of the volume of each half hour of a day
GetHalfHourCandleVolumeByDayOfWeek :: proc(chart : main.Chart, day : main.DayOfWeek) -> HalfHourCandleVolume
{
    using main

    MAY_17TH :: 358_905_600
    candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], MAY_17TH + i32(day) * 86400)
    candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

	volume : HalfHourCandleVolume

    for i := 0; i < len(candles); i += 48 * 7
    {
		for vol in 0 ..< len(volume.volumeData)
		{
			append(&volume.volumeData[vol].values, candles[i + vol].volume)
            volume.volumeData[vol].mean += candles[i + vol].volume
        }
	}

	for i in 0 ..< len(volume.volumeData)
    {
		volume.volumeData[i].mean /= f32(len(volume.volumeData[i].values))

		slice.sort(volume.volumeData[i].values[:])

		volume.volumeData[i].median = volume.volumeData[i].values[int(f32(len(volume.volumeData[i].values)) * 0.5)]
		volume.volumeData[i].Q1 = volume.volumeData[i].values[int(f32(len(volume.volumeData[i].values)) * 0.25)]
		volume.volumeData[i].Q3 = volume.volumeData[i].values[int(f32(len(volume.volumeData[i].values)) * 0.75)]

		volume.highestValue = math.max(volume.highestValue, volume.volumeData[i].mean)
		volume.highestValue = math.max(volume.highestValue, volume.volumeData[i].Q3)
	}

    return volume
}

DrawHalfHourCandleVolume :: proc(volume : HalfHourCandleVolume, posX : i32, posY : i32, width : i32, height : i32, highestValue : f32 = 0)
{
    using main
    using raylib

    high := highestValue == 0 ? volume.highestValue  : highestValue

	columnHeaders := [48]string{"10:00", "10:30", "11:00", "11:30", "12:00", "12:30", "13:00", "13:30", "14:00", "14:30", "15:00", "15:30", "16:00", "16:30", "17:00", "17:30", "18:00", "18:30", "19:00", "19:30", "20:00", "20:30", "21:00", "21:30", "22:00", "22:30", "23:00", "23:30", "00:00", "00:30", "01:00", "01:30", "02:00", "02:30", "03:00", "03:30", "04:00", "04:30", "05:00", "05:30", "06:00", "06:30", "07:00", "07:30", "08:00", "08:30", "09:00", "09:30"}
    columnWidth := width / 48

    for volumeData, i in volume.volumeData
    {
        Q3Y := posY + i32((1 - (volumeData.Q3 / high)) * f32(height))
        medianY := posY + i32((1 - (volumeData.median / high)) * f32(height))
        Q1Y := posY + i32((1 - (volumeData.Q1 / high)) * f32(height))

        DrawRectangle(posX + i32(i) * columnWidth, Q3Y, columnWidth, medianY - Q3Y, BLUE)
        DrawRectangle(posX + i32(i) * columnWidth, medianY, columnWidth, Q1Y - medianY, BLUE)
        DrawLine(posX + i32(i) * columnWidth, medianY, posX + i32(i) * columnWidth + columnWidth, medianY, WHITE)

        meanY := posY + i32((1 - (volumeData.mean / high)) * f32(height))
        DrawCircle(posX + i32(i) * columnWidth + columnWidth / 2, meanY, f32(columnWidth) / 4, RED)
    }
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