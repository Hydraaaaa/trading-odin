package stats

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "core:os"
import "core:encoding/csv"
import "vendor:raylib"

import "../main"

HalfHourCandleWeek :: struct
{
    data : [7][48]DataList,
    highestValue : f32,
    lowestValue : f32,
}

DataList :: struct
{
	values : [dynamic]f32,
	mean : f32,
	median : f32,
	Q1 : f32,
	Q3 : f32,
}

APR_1ST_2020 :: 323_395_200
MAY_17TH_2021 :: 358_905_600

// Volume of each half hour candle in the week
HalfHourCandleWeek_Volume :: proc(chart : main.Chart) -> HalfHourCandleWeek
{
    using main

    week : HalfHourCandleWeek

    for day in 0 ..< 7
    {
        candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], MAY_17TH_2021 + i32(day) * 86400)
        candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

        for i := 0; i < len(candles); i += 48 * 7
        {
            for dataIndex in 0 ..< 48
            {
                append(&week.data[day][dataIndex].values, candles[i + dataIndex].volume)
                week.data[day][dataIndex].mean += candles[i + dataIndex].volume
            }
        }
    }

    CalculateDatapoints(&week)

    return week
}

// Difference between open and close of each half hour candle in the week
HalfHourCandleWeek_PriceMovement :: proc(chart : main.Chart, abs : bool = false) -> HalfHourCandleWeek
{
    using main

    week : HalfHourCandleWeek

    for day in 0 ..< 7
    {
        candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], APR_1ST_2020 + i32(day) * 86400)
        candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

        for i := 0; i < len(candles); i += 48 * 7
        {
            for dataIndex in 0 ..< 48
            {
                if abs
                {
                    append(&week.data[day][dataIndex].values, math.abs(candles[i + dataIndex].close - candles[i + dataIndex].open))
                    week.data[day][dataIndex].mean += math.abs(candles[i + dataIndex].close - candles[i + dataIndex].open)
                }
                else
                {
                    append(&week.data[day][dataIndex].values, candles[i + dataIndex].close - candles[i + dataIndex].open)
                    week.data[day][dataIndex].mean += candles[i + dataIndex].close - candles[i + dataIndex].open
                }
            }
        }
    }

    CalculateDatapoints(&week)

    return week
}

// Difference between close of each half hour candle, and the open of the first candle of the day or week
HalfHourCandleWeek_CloseOffset :: proc(chart : main.Chart, sampleWeek : bool = false) -> HalfHourCandleWeek
{
    using main

    week : HalfHourCandleWeek

    candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], APR_1ST_2020)
    candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

    for day in 0 ..< 7
    {
        for weekIndex := 0; weekIndex < len(candles) - 48 * 7; weekIndex += 48 * 7
        {
            for dataIndex in 0 ..< 48
            {
                candleIndex := weekIndex + day * 48 + dataIndex
                if sampleWeek
                {
                    append(&week.data[day][dataIndex].values, candles[candleIndex].close - candles[weekIndex].open)
                    week.data[day][dataIndex].mean += candles[candleIndex].close - candles[weekIndex].open
                }
                else
                {
                    append(&week.data[day][dataIndex].values, candles[candleIndex].close - candles[weekIndex + day * 48].open)
                    week.data[day][dataIndex].mean += candles[candleIndex].close - candles[weekIndex + day * 48].open
                }
            }
        }
    }

    CalculateDatapoints(&week)

    return week
}

// Difference between high and low of each half hour candle
HalfHourCandleWeek_Range :: proc(chart : main.Chart) -> HalfHourCandleWeek
{
    using main

    week : HalfHourCandleWeek

    candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], APR_1ST_2020)
    candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

    for day in 0 ..< 7
    {
        for weekIndex := 0; weekIndex < len(candles) - 48 * 7; weekIndex += 48 * 7
        {
            for dataIndex in 0 ..< 48
            {
                candleIndex := weekIndex + day * 48 + dataIndex
                append(&week.data[day][dataIndex].values, candles[candleIndex].high - candles[candleIndex].low)
                week.data[day][dataIndex].mean += candles[candleIndex].high - candles[candleIndex].low
            }
        }
    }

    CalculateDatapoints(&week)

    return week
}

// WIP
// Difference between high of each half hour candle, and the average price of the week
//HalfHourCandleWeek_High :: proc(chart : main.Chart) -> HalfHourCandleWeek
//{
//    using main
//
//    week : HalfHourCandleWeek
//
//    candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], APR_1ST_2020)
//    candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]
//
//    weekAverages : [dynamic]f32
//
//    for weekIndex := 0; weekIndex < len(candles) / (48 * 7) - 1; weekIndex += 1
//    {
//        for dataIndex in 0 ..< 48 * 7
//        {
//            weekAverages[weekIndex] += candles[weekIndex * 48 * 7 + dataIndex]
//        }
//
//        weekAverages[weekIndex] /= 48 * 7
//    }
//
//    for day in 0 ..< 7
//    {
//        for weekIndex := 0; weekIndex < len(candles) - 48 * 7; weekIndex += 48 * 7
//        {
//            for dataIndex in 0 ..< 48
//            {
//                candleIndex := weekIndex + day * 48 + dataIndex
//                append(&week.data[day][dataIndex].values, candles[candleIndex].close - candles[weekIndex].open)
//                week.data[day][dataIndex].mean += candles[candleIndex].close - candles[weekIndex].open
//            }
//        }
//    }
//
//    CalculateDatapoints(&week)
//
//    return week
//}

CalculateDatapoints :: proc(week : ^HalfHourCandleWeek)
{
    for day in 0 ..< 7
    {
        for dataIndex in 0 ..< 48
        {
            week.data[day][dataIndex].mean /= f32(len(week.data[day][dataIndex].values))

            slice.sort(week.data[day][dataIndex].values[:])

            week.data[day][dataIndex].median = week.data[day][dataIndex].values[int(f32(len(week.data[day][dataIndex].values)) * 0.5)]
            week.data[day][dataIndex].Q1 = week.data[day][dataIndex].values[int(f32(len(week.data[day][dataIndex].values)) * 0.25)]
            week.data[day][dataIndex].Q3 = week.data[day][dataIndex].values[int(f32(len(week.data[day][dataIndex].values)) * 0.75)]

            week.highestValue = math.max(week.highestValue, week.data[day][dataIndex].mean)
            week.highestValue = math.max(week.highestValue, week.data[day][dataIndex].Q3)

            // Won't go below 0, which I don't mind
            week.lowestValue = math.min(week.lowestValue, week.data[day][dataIndex].mean)
            week.lowestValue = math.min(week.lowestValue, week.data[day][dataIndex].Q1)
        }
    }
}

DrawHalfHourCandleDataset :: proc(dataset : [48]DataList, font : raylib.Font, posX : f32, posY : f32, width : f32, height : f32, highestValue : f32, lowestValue : f32)
{
    using main
    using raylib

    asiaStart := i32(posX)
    asiaLength := i32(width / (48.0 / 16))
    londonStart := i32(posX) + asiaLength
    londonLength := i32(width / (48.0 / 17))
    newYorkStart := i32(posX + width / (48.0 / 27))
    newYorkLength := i32(width / (48.0 / 13))

    asiaColor := RED
    asiaColor.a = 63
    londonColor := YELLOW
    londonColor.a = 63
    newYorkColor := BLUE
    newYorkColor.a = 63

    DrawRectangle(asiaStart, i32(posY), asiaLength, i32(height), asiaColor)
    DrawTextEx(font, "Asia\x00", {f32(asiaStart), posY + height - 14}, FONT_SIZE, 0, WHITE)
    DrawRectangle(londonStart, i32(posY), londonLength, i32(height), londonColor)
    DrawTextEx(font, "London\x00", {f32(londonStart), posY + height - 14}, FONT_SIZE, 0, WHITE)
    DrawRectangle(newYorkStart, i32(posY), newYorkLength, i32(height), newYorkColor)
    DrawTextEx(font, "New York\x00", {f32(newYorkStart), posY + height - 14}, FONT_SIZE, 0, WHITE)

    range := highestValue - lowestValue

    columnWidth := f32(width / 48)

    for data, i in dataset
    {
        Q3Y := posY + (1 - ((data.Q3 - lowestValue) / range)) * height
        medianY := posY + (1 - ((data.median - lowestValue) / range)) * height
        Q1Y := posY + (1 - ((data.Q1 - lowestValue) / range)) * height

        DrawRectangle(i32(posX + f32(i) * columnWidth), i32(Q3Y), i32(columnWidth), i32(medianY - Q3Y), BLUE)
        DrawRectangle(i32(posX + f32(i) * columnWidth), i32(medianY), i32(columnWidth), i32(Q1Y - medianY), BLUE)
        DrawLine(i32(posX + f32(i) * columnWidth), i32(medianY), i32(posX + f32(i) * columnWidth + columnWidth), i32(medianY), WHITE)

        meanY := i32(posY + (1 - ((data.mean - lowestValue) / range)) * height)
        DrawCircle(i32(posX + f32(i) * columnWidth + columnWidth / 2), meanY, columnWidth / 3, RED)
    }
}