package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "core:os"
import "core:encoding/csv"
import "core:strings"
import rl "vendor:raylib"

HalfHourOfWeek_BoxPlot :: struct
{
    data : [336]DataList,

    startTimestamp : i32,
    endTimestamp : i32,
    
    highestValue : f32,
    lowestValue : f32,
    labelIncrement : f32,
    labelFormat : string,
}

HalfHourOfWeek_HighLow :: struct
{
    numHighs : [336]i32,
    numLows : [336]i32,
    numBoth : [336]i32,
    highestTotalCount : i32,
    totalEntries : int,
}

DataList :: struct
{
	values : []f32,
	mean : f32,
	median : f32,
	Q1 : f32,
	Q3 : f32,
}

// Volume of each half hour candle in the week
// HalfHourOfWeek_Volume :: proc(chart : Chart, startTimestamp : i32) -> HalfHourOfWeek_BoxPlot
// {
//     week : HalfHourOfWeek_BoxPlot

//     for day in 0 ..< 7
//     {
//         candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], startTimestamp + i32(day) * 86400)
//         candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

//         for i := 0; i < len(candles); i += 48 * 7
//         {
//             for dataIndex in 0 ..< 48
//             {
//                 append(&week.data[day][dataIndex].values, candles[i + dataIndex].volume)
//                 week.data[day][dataIndex].mean += candles[i + dataIndex].volume
//             }
//         }
//     }

//     CalculateDatapoints(&week)

//     week.title = "Volume\x00"
//     week.labelStart = 1000
//     week.labelIncrement = 1000
//     week.labelFormat = "%.0f\x00"

//     return week
// }

// Function does NOT support abs or percent changing from previous value
HalfHourOfWeek_PriceMovement_Resize :: proc(chart : Chart, startTimestamp : i32, endTimestamp : i32, existingPlot : HalfHourOfWeek_BoxPlot, abs : bool = false, percent : bool = false) -> HalfHourOfWeek_BoxPlot
{
    // TODO: This doesn't factor in if the region shrinks
    prependedData : [336]DataList
    existingData := existingPlot.data
    appendedData : [336]DataList

    // The indices to remove from the existing data
    removeStartData : [336]int
    removeEndData : [336]int
    
    if startTimestamp < existingPlot.startTimestamp
    {
        HalfHourOfWeek_PriceMovement_Data(chart, startTimestamp, existingPlot.startTimestamp, abs, percent)
    }
    else if startTimestamp > existingPlot.startTimestamp
    {
        firstWeekTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.WEEK], startTimestamp)
        firstHalfHourTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.MINUTE_30], startTimestamp)

        // TODO: Subtract part of data that is no longer relevant
    }
    
    if endTimestamp > existingPlot.endTimestamp
    {
        HalfHourOfWeek_PriceMovement_Data(chart, existingPlot.endTimestamp, endTimestamp, abs, percent)
    }
    else if endTimestamp < existingPlot.endTimestamp
    {
        lastWeekTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.WEEK], endTimestamp)
        lastHalfHourTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.MINUTE_30], endTimestamp)
        
        // TODO: Subtract part of data that is no longer relevant
    }

    newPlot : HalfHourOfWeek_BoxPlot

    newPlot.startTimestamp = startTimestamp
    newPlot.endTimestamp = endTimestamp

    newPlot.labelIncrement = existingPlot.labelIncrement
    newPlot.labelFormat = existingPlot.labelFormat

    for i in 0 ..< 336
    {
        newPlot.data[i].values = make([]f32, len(prependedData[i].values) + len(existingData[i].values) + len(appendedData[i].values) - removeStartData[i] - removeEndData[i])

        j := 0
        
        for value in prependedData[i].values
        {
            newPlot.data[i].values[j] = value
            j += 1
        }

        // In the event that the selection has shrunk, only add the remaining subsection
        startIndex := removeStartData[i]
        endIndex := len(existingData[i].values) - removeEndData[i]
        
        for value in existingData[i].values[startIndex:endIndex]
        {
            newPlot.data[i].values[j] = value
            j += 1
        }
        
        for value in appendedData[i].values
        {
            newPlot.data[i].values[j] = value
            j += 1
        }
    }

    return newPlot
}

HalfHourOfWeek_PriceMovement_Create :: proc(chart : Chart, startTimestamp : i32, endTimestamp : i32, abs : bool = false, percent : bool = false) -> HalfHourOfWeek_BoxPlot
{
    plot : HalfHourOfWeek_BoxPlot
    
    plot.data = HalfHourOfWeek_PriceMovement_Data(chart, startTimestamp, endTimestamp, abs, percent)

    plot.startTimestamp = startTimestamp
    plot.endTimestamp = endTimestamp

    CalculateDatapoints(&plot)

    if percent
    {
        plot.labelIncrement = 0.005
        plot.labelFormat = "%.3f\x00"
    }
    else
    {
        plot.labelIncrement = 250
        plot.labelFormat = "%.0f\x00"
    }

    return plot
}

@(private="file")
HalfHourOfWeek_PriceMovement_Data :: proc(chart : Chart, startTimestamp : i32, endTimestamp : i32, abs : bool = false, percent : bool = false) -> [336]DataList
{
    data : [336]DataList
    
    // Allocate exact array lengths for each half hour of the week
    firstWeekTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.WEEK], startTimestamp)
    lastWeekTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.WEEK], endTimestamp)
    firstHalfHourTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.MINUTE_30], startTimestamp)
    lastHalfHourTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.MINUTE_30], endTimestamp)

	timeframeIncrements := TIMEFRAME_INCREMENTS
	
    baseLength := (lastWeekTimestamp - firstWeekTimestamp - timeframeIncrements[Timeframe.WEEK]) / timeframeIncrements[Timeframe.WEEK]

    lengths : [336]i32 = {0..<336=baseLength}

    startIndex := (firstHalfHourTimestamp - firstWeekTimestamp) / timeframeIncrements[Timeframe.MINUTE_30]
    endIndex := (lastHalfHourTimestamp - lastWeekTimestamp) / timeframeIncrements[Timeframe.MINUTE_30]
    
    for &length in lengths[startIndex:]
    {
        length += 1
    }
    
    for &length in lengths[:endIndex]
    {
        length += 1
    }

    for length, i in lengths
    {
        if length > 0
        {
            data[i].values = make([]f32, length)
        }
    }

    total := 0
	
    // Calculate Values
    candlesStartIndex := CandleList_TimestampToIndex_Clamped(chart.candles[Timeframe.MINUTE_30], startTimestamp)
    candlesEndIndex := CandleList_TimestampToIndex_Clamped(chart.candles[Timeframe.MINUTE_30], endTimestamp)
    candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:candlesEndIndex]

    if abs
    {
        if percent
        {
            for candle, i in candles
            {
                data[(startIndex + i32(i)) % 336].values[i / 336] = math.abs(candle.close - candle.open) / candle.open
            }
        }
        else
        {
            for candle, i in candles
            {
                data[(startIndex + i32(i)) % 336].values[i / 336] = math.abs(candle.close - candle.open)
            }
        }
    }
    else
    {
        if percent
        {
            for candle, i in candles
            {
                data[(startIndex + i32(i)) % 336].values[i / 336] = (candle.close - candle.open) / candle.open
            }
        }
        else
        {
            for candle, i in candles
            {
                data[(startIndex + i32(i)) % 336].values[i / 336] = candle.close - candle.open
            }
        }
    }

    return data
}

// Percentage difference between close of each half hour candle, and the open of the first candle of the day or week
// HalfHourOfWeek_CloseOffset :: proc(chart : Chart, startTimestamp : i32, sampleWeek : bool = false) -> HalfHourOfWeek_BoxPlot
// {
//     week : HalfHourOfWeek_BoxPlot

//     candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], startTimestamp)
//     candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

//     for day in 0 ..< 7
//     {
//         for weekIndex := 0; weekIndex < len(candles) - 48 * 7; weekIndex += 48 * 7
//         {
//             for dataIndex in 0 ..< 48
//             {
//                 candleIndex := weekIndex + day * 48 + dataIndex
//                 if sampleWeek
//                 {
//                     append(&week.data[day][dataIndex].values, candles[candleIndex].close / candles[weekIndex].open)
//                     week.data[day][dataIndex].mean += candles[candleIndex].close / candles[weekIndex].open
//                 }
//                 else
//                 {
//                     append(&week.data[day][dataIndex].values, candles[candleIndex].close / candles[weekIndex + day * 48].open)
//                     week.data[day][dataIndex].mean += candles[candleIndex].close / candles[weekIndex + day * 48].open
//                 }
//             }
//         }
//     }

//     CalculateDatapoints(&week)

//     week.title = "Close Offset\x00"
//     week.labelStart = 0.95
//     week.labelIncrement = 0.005
//     week.labelFormat = "%.2f\x00"

//     return week
// }

// // Difference between high and low of each half hour candle
// HalfHourOfWeek_Range :: proc(chart : Chart, startTimestamp : i32) -> HalfHourOfWeek_BoxPlot
// {
//     week : HalfHourOfWeek_BoxPlot

//     candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], startTimestamp)
//     candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]

//     for day in 0 ..< 7
//     {
//         for weekIndex := 0; weekIndex < len(candles) - 48 * 7; weekIndex += 48 * 7
//         {
//             for dataIndex in 0 ..< 48
//             {
//                 candleIndex := weekIndex + day * 48 + dataIndex
//                 append(&week.data[day][dataIndex].values, candles[candleIndex].high - candles[candleIndex].low)
//                 week.data[day][dataIndex].mean += candles[candleIndex].high - candles[candleIndex].low
//             }
//         }
//     }

//     CalculateDatapoints(&week)

//     week.title = "Range\x00"
//     week.labelStart = 50
//     week.labelIncrement = 50
//     week.labelFormat = "%.0f\x00"

//     return week
// }

// // Difference between high of each half hour candle, and the average price of the week
// HalfHourOfWeek_High :: proc(chart : Chart, startTimestamp : i32) -> HalfHourOfWeek_BoxPlot
// {
//     week : HalfHourOfWeek_BoxPlot

//     candlesStartIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.MINUTE_30], startTimestamp)
//     candles := chart.candles[Timeframe.MINUTE_30].candles[candlesStartIndex:]
//     weeks := chart.candles[Timeframe.WEEK].candles[:]

//     vwaps : [dynamic]f32

//     for weekIndex in CandleList_TimestampToIndex(chart.candles[Timeframe.WEEK], startTimestamp) ..< i32(len(weeks))
//     {
//         startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], weekIndex)
//         endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], weekIndex + 1)

//         profile := VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
//         defer VolumeProfile_Destroy(profile)

//         append(&vwaps, f32(profile.pocIndex) * profile.bucketSize + profile.bottomPrice)
//     }

//     for day in 0 ..< 7
//     {
//         for weekIndex := 0; weekIndex < len(candles) - 48 * 7; weekIndex += 48 * 7
//         {
//             for dataIndex in 0 ..< 48
//             {
//                 candleIndex := weekIndex + day * 48 + dataIndex
//                 append(&week.data[day][dataIndex].values, candles[candleIndex].high / vwaps[weekIndex / (48 * 7)])
//                 week.data[day][dataIndex].mean += candles[candleIndex].high / vwaps[weekIndex / (48 * 7)]
//             }
//         }
//     }

//     CalculateDatapoints(&week)

//     week.title = "High\x00"
//     week.labelStart = 0.95
//     week.labelIncrement = 0.005
//     week.labelFormat = "%.2f\x00"

//     return week
// }

CalculateDatapoints :: proc(week : ^HalfHourOfWeek_BoxPlot)
{
    week.lowestValue = 10000000

    for &data in week.data
    {
        if len(data.values) == 0
        {
            continue
        }

        for value in data.values
        {
            data.mean += value
        }

        data.mean /= f32(len(data.values))

        slice.sort(data.values[:])

        data.median = data.values[int(f32(len(data.values)) * 0.5)]
        data.Q1 = data.values[int(f32(len(data.values)) * 0.25)]
        data.Q3 = data.values[int(f32(len(data.values)) * 0.75)]

        week.highestValue = math.max(week.highestValue, data.mean)
        week.highestValue = math.max(week.highestValue, data.Q3)

        week.lowestValue = math.min(week.lowestValue, data.mean)
        week.lowestValue = math.min(week.lowestValue, data.Q1)
    }
}

// DrawHalfHourOfWeek_BoxPlot :: proc(week : HalfHourOfWeek_BoxPlot, posX : f32, posY : f32, width : f32, height : f32)
// {
// 	dayOfWeekStrings := [7]string{"Mon\x00", "Tue\x00", "Wed\x00", "Thur\x00", "Fri\x00", "Sat\x00", "Sun\x00"}

//     dayWidth := width / 7

//     posX := posX

//     range := week.highestValue - week.lowestValue

//     labelValue := week.labelStart

//     labelHeight := (1 - ((f32(labelValue) - week.lowestValue) / range)) * height

//     textBuffer : [16]u8

//     lineColor := rl.WHITE
//     lineColor.a = 127

//     rl.DrawTextEx(labelFont, strings.unsafe_string_to_cstring(week.title), {posX + 4, posY + 18}, LABEL_FONT_SIZE * 2, 0, lineColor)

//     for labelHeight > 0
//     {
//         if labelHeight < height
//         {
//             fmt.bprintf(textBuffer[:], week.labelFormat, labelValue)
//             textDimensions := rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0)
//             rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {posX - textDimensions[0] - 4, posY + labelHeight - textDimensions[1] / 2}, LABEL_FONT_SIZE, 0, rl.WHITE)
//             rl.DrawLine(i32(posX), i32(posY + labelHeight), i32(width), i32(posY + labelHeight), lineColor)
//         }

//         labelValue += week.labelIncrement
//         labelHeight = (1 - ((f32(labelValue) - week.lowestValue) / range)) * height
//     }

//     for i in 0 ..< 7
//     {
//         DrawHalfHourCandleDataset(week.data[i], posX, posY, dayWidth, height, week.highestValue, week.lowestValue)

//         rl.DrawTextEx(labelFont, strings.unsafe_string_to_cstring(dayOfWeekStrings[i]), {f32(posX), posY}, LABEL_FONT_SIZE, 0, rl.WHITE)
//         rl.DrawLine(i32(posX), i32(posY), i32(posX), i32(posY + height), rl.WHITE)

//         posX += dayWidth
//     }
// }

// HalfHourOfWeek_HighLow :: proc(chart : Chart) -> HalfHourOfWeekHighLow
// {
//     week : HalfHourOfWeekHighLow

//     candleStartOffset := chart.candles[Timeframe.WEEK].offset + DAY * 7
//     weekStartIndex := int(CandleList_TimestampToIndex(chart.candles[Timeframe.WEEK], candleStartOffset))
//     dayCandles := chart.candles[Timeframe.DAY].candles

//     dayIndex := int(CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], candleStartOffset))

//     for weekIndex in weekStartIndex ..< len(chart.candles[Timeframe.WEEK].candles) - 1
//     {
//         highestIndex := 0
//         lowestIndex := 0
//         highestHigh := dayCandles[dayIndex].high
//         lowestLow := dayCandles[dayIndex].low

//         for day in 1 ..< 7
//         {
//             if dayCandles[dayIndex + day].high > highestHigh
//             {
//                 highestHigh = dayCandles[dayIndex + day].high
//                 highestIndex = day
//             }

//             if dayCandles[dayIndex + day].low < lowestLow
//             {
//                 lowestLow = dayCandles[dayIndex + day].low
//                 lowestIndex = day
//             }
//         }

//         if highestIndex == lowestIndex
//         {
//             week.numBoth[highestIndex] += 1

//             week.totalEntries += 1
//         }
//         else
//         {
//             week.numHighs[highestIndex] += 1
//             week.numLows[lowestIndex] += 1

//             week.totalEntries += 2
//         }

//         dayIndex += 7
//     }

//     week.highestTotalCount = week.numHighs[0][0] + week.numLows[0][0] + week.numBoth[0][0]

//     halfHr := 1

//     for day in 0 ..< 7
//     {
//         for halfHr <= 48
//         {
//             week.highestTotalCount = math.max(week.highestTotalCount, week.numHighs[day][halfHr] + week.numLows[day][halfHr] + week.numBoth[day][halfHr])

//             halfHr += 1
//         }

//         halfHr = 0
//     }

//     return week
// }


HalfHourOfWeek_BoxPlot_Draw :: proc(plot : HalfHourOfWeek_BoxPlot, posX : i32, posY : i32, width : i32, columnWidth : i32, height : i32)
{
    boxPlotStartX := posX + width - columnWidth * 336 - 1
    boxPlotHeight := height - 2

    asiaColor := rl.RED
    asiaColor.a = 63
    londonColor := rl.YELLOW
    londonColor.a = 63
    newYorkColor := rl.BLUE
    newYorkColor.a = 63
    
    asiaStart := boxPlotStartX
    londonStart := boxPlotStartX + columnWidth * 16
    newYorkStart := boxPlotStartX + columnWidth * 27

    asiaLength := columnWidth * 16
    londonLength := columnWidth * 17
    newYorkLength := columnWidth * 13

    range := plot.highestValue - plot.lowestValue

    // Adjust label increment to avoid labels overlapping
    labelIncrement := plot.labelIncrement
    labelCount := i32(range / labelIncrement)
    
    for labelCount * LABEL_FONT_SIZE > height
    {
        labelIncrement *= 2
        labelCount /= 2
    }
    
    labelValue := plot.lowestValue - math.mod(plot.lowestValue, labelIncrement)

    if labelValue < plot.lowestValue
    {
        labelValue += labelIncrement
    }

    // Draw labels
    textBuffer : [64]u8
    
    for labelValue < plot.highestValue
    {
        labelHeight := i32((labelValue - plot.lowestValue) / range * f32(height))
        fmt.bprintf(textBuffer[:], plot.labelFormat, labelValue)
        
        labelWidth := rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0).x
        rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), rl.Vector2{f32(boxPlotStartX) - labelWidth - 5, f32(posY + height - labelHeight - LABEL_FONT_SIZE / 2)}, LABEL_FONT_SIZE, 0, rl.WHITE)
        
        labelValue += labelIncrement
    }

    // Draw border
	rl.DrawRectangleLines(boxPlotStartX - 1, posY, columnWidth * 336 + 2, height, rl.Color{255, 255, 255, 127})

	// Draw sessions + bars
    for day in 0 ..< 7
    {
        rl.DrawRectangle(asiaStart, i32(posY), asiaLength, i32(boxPlotHeight), asiaColor)
        rl.DrawRectangle(londonStart, i32(posY), londonLength, i32(boxPlotHeight), londonColor)
        rl.DrawRectangle(newYorkStart, i32(posY), newYorkLength, i32(boxPlotHeight), newYorkColor)

        // Separating rectangle draw from line draws due to performance effects
        for data, i in plot.data
        {
            Q3Y := posY + i32((1 - ((data.Q3 - plot.lowestValue) / range)) * f32(boxPlotHeight))
            Q1Y := posY + i32((1 - ((data.Q1 - plot.lowestValue) / range)) * f32(boxPlotHeight))

            columnPosX := boxPlotStartX + i32(i) * columnWidth

            rl.DrawRectangle(columnPosX, Q3Y, columnWidth, Q1Y - Q3Y, rl.WHITE)
        }
        
        for data, i in plot.data
        {
            medianY := posY + i32((1 - ((data.median - plot.lowestValue) / range)) * f32(boxPlotHeight))
            meanY := posY + i32((1 - ((data.mean - plot.lowestValue) / range)) * f32(boxPlotHeight))

            columnPosX := boxPlotStartX + i32(i) * columnWidth

            rl.DrawLine(columnPosX, medianY, columnPosX + columnWidth, medianY, rl.BLUE)
            rl.DrawLine(columnPosX, meanY, columnPosX + columnWidth, meanY, rl.RED)
        }
        
        asiaStart += columnWidth * 48
        londonStart += columnWidth * 48
        newYorkStart += columnWidth * 48
    }
}
