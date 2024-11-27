package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "core:os"
import "core:encoding/csv"
import rl "vendor:raylib"

DayByWeekHighLow :: struct
{
    numHighs : [7]i32,
    numLows : [7]i32,
    numBoth : [7]i32,
    highestTotalCount : i32,
    totalEntries : int,
}

DayByWeek_HighLow :: proc(chart : Chart) -> DayByWeekHighLow
{
    days : DayByWeekHighLow

    candleStartOffset := chart.candles[Timeframe.WEEK].offset + DAY * 7
    weekStartIndex := int(CandleList_TimestampToIndex(chart.candles[Timeframe.WEEK], candleStartOffset))
    dayCandles := chart.candles[Timeframe.DAY].candles
    
    dayIndex := int(CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], candleStartOffset))
    
    for weekIndex in weekStartIndex ..< len(chart.candles[Timeframe.WEEK].candles) - 1
    {
        highestIndex := 0
        lowestIndex := 0
        highestHigh := dayCandles[dayIndex].high
        lowestLow := dayCandles[dayIndex].low

        for day in 1 ..< 7
        {
            if dayCandles[dayIndex + day].high > highestHigh
            {
                highestHigh = dayCandles[dayIndex + day].high
                highestIndex = day
            }

            if dayCandles[dayIndex + day].low < lowestLow
            {
                lowestLow = dayCandles[dayIndex + day].low
                lowestIndex = day
            }
        }

        if highestIndex == lowestIndex
        {
            days.numBoth[highestIndex] += 1

            days.totalEntries += 1
        }
        else
        {
            days.numHighs[highestIndex] += 1
            days.numLows[lowestIndex] += 1

            days.totalEntries += 2
        }

        dayIndex += 7
    }
    
    days.highestTotalCount = days.numHighs[0] + days.numLows[0] + days.numBoth[0]
    
    for i in 1 ..< 7
    {
        days.highestTotalCount = math.max(days.highestTotalCount, days.numHighs[i] + days.numLows[i] + days.numBoth[i])
    }
    
    return days
}

DrawDayByWeek :: proc(dayByWeek : DayByWeekHighLow, posX : f32, posY : f32, width : f32, height : f32)
{
    columnWidth := f32(width / 7)

    for i in 0 ..< 7
    {
        bothY := (1 - f32(dayByWeek.numBoth[i]) / f32(dayByWeek.highestTotalCount)) * height
        lowsY := (1 - f32(dayByWeek.numBoth[i] + dayByWeek.numLows[i]) / f32(dayByWeek.highestTotalCount)) * height
        highsY := (1 - f32(dayByWeek.numBoth[i] + dayByWeek.numLows[i] + dayByWeek.numHighs[i]) / f32(dayByWeek.highestTotalCount)) * height

        rl.DrawRectangle(i32(posX + f32(i) * columnWidth), i32(posY + highsY), i32(columnWidth), i32(height - highsY), rl.BLUE)
        rl.DrawRectangle(i32(posX + f32(i) * columnWidth), i32(posY + lowsY), i32(columnWidth), i32(height - lowsY), rl.RED)
        rl.DrawRectangle(i32(posX + f32(i) * columnWidth), i32(posY + bothY), i32(columnWidth), i32(height - bothY), rl.YELLOW)
    }
}
