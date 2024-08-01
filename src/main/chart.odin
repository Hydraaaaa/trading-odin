package main

import "core:fmt"
import "core:math"

CANDLE_TIMEFRAME_INCREMENTS : [10]i32 : {60, 300, 900, 1800, 3600, 10_800, 21_600, 43_200, 86_400, 604_800}

TIMEFRAME_COUNT :: 11

Chart :: struct
{
    candles : [TIMEFRAME_COUNT]CandleList,
    hourVolumeProfilePool : VolumeProfilePool,
    dailyVolumeProfiles : [dynamic]VolumeProfile,
    weeklyVolumeProfiles : [dynamic]VolumeProfile,
    dateToDownload : DayMonthYear,
}

// Converts minute candles into candles of each higher timeframe
Chart_CreateHTFCandles :: proc(chart : ^Chart)
{
    candleTimeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

    prevTimeframe := Timeframe.MINUTE

    for timeframe in Timeframe.MINUTE_5 ..= Timeframe.WEEK
    {
        prevCandles := chart.candles[prevTimeframe].candles[:]
        prevDelta := chart.candles[prevTimeframe].cumulativeDelta[:]

        prevCandlesLen := len(prevCandles)

        timeframeDivisor := int(candleTimeframeIncrements[timeframe] / candleTimeframeIncrements[prevTimeframe])

        // + 1 accounts for a higher timeframe candle at the beginning with only partial data
        reserve(&chart.candles[timeframe].candles, prevCandlesLen / timeframeDivisor + 1)
        reserve(&chart.candles[timeframe].cumulativeDelta, prevCandlesLen / timeframeDivisor + 1)

        // Separately calculate the subcandles of the first candle to handle the case where the candle timestamps aren't aligned
        firstCandleComponentCount := timeframeDivisor - int((chart.candles[prevTimeframe].offset - chart.candles[timeframe].offset) / candleTimeframeIncrements[prevTimeframe])

        start := 0
        end := firstCandleComponentCount

        if end == 0
        {
            end += timeframeDivisor
        }

        for end <= prevCandlesLen
        {
            append(&chart.candles[timeframe].candles, Candle_Merge(..prevCandles[start:end]))
            append(&chart.candles[timeframe].cumulativeDelta, prevDelta[end - 1])

            start = end
            end += timeframeDivisor
        }

        // Create a final partial candle if applicable (like on weekly candles)
        if start < prevCandlesLen
        {
            append(&chart.candles[timeframe].candles, Candle_Merge(..prevCandles[start:prevCandlesLen]))
            append(&chart.candles[timeframe].cumulativeDelta, prevDelta[prevCandlesLen - 1])
        }

        prevTimeframe = timeframe
    }

    // Monthly candles
    // Find floored month offset + start index for the candle creation
    monthlyIncrements := MONTHLY_INCREMENTS

    fourYearTimestamp := chart.candles[prevTimeframe].offset % FOUR_YEARS

    fourYearIndex := 47

    for fourYearTimestamp < monthlyIncrements[fourYearIndex]
    {
        fourYearIndex -= 1
    }

    chart.candles[Timeframe.MONTH].offset = chart.candles[prevTimeframe].offset - fourYearTimestamp + monthlyIncrements[fourYearIndex]

    // Create candles
    dayCandles := chart.candles[Timeframe.DAY].candles[:]
    dayDelta := chart.candles[Timeframe.DAY].cumulativeDelta[:]

    daysPerMonth := DAYS_PER_MONTH

    start := 0

    offsetDate := Timestamp_ToDayMonthYear(chart.candles[Timeframe.MONTH].offset)

    offsetDate.month += 1

    if offsetDate.month > 12
    {
        offsetDate.month = 1
        offsetDate.year += 1
    }

    end := int(DayMonthYear_ToTimestamp(DayMonthYear{1, offsetDate.month, offsetDate.year}) - chart.candles[Timeframe.DAY].offset) / DAY

    dayCandlesLen := len(dayCandles)

    for end <= dayCandlesLen
    {
        append(&chart.candles[Timeframe.MONTH].candles, Candle_Merge(..dayCandles[start:end]))
        append(&chart.candles[Timeframe.MONTH].cumulativeDelta, dayDelta[end - 1])

        start = end

        fourYearIndex += 1

        if fourYearIndex > 47
        {
            fourYearIndex = 0
        }

        end += daysPerMonth[fourYearIndex]
    }

    // Create a final partial candle when applicable
    if start < dayCandlesLen
    {
        append(&chart.candles[Timeframe.MONTH].candles, Candle_Merge(..dayCandles[start:dayCandlesLen]))
        append(&chart.candles[Timeframe.MONTH].cumulativeDelta, dayDelta[dayCandlesLen - 1])
    }
}

// Does not consider month timeframes  
// (VolumeProfile_CreateBuckets is simplified as a result)
Chart_TimestampToTimeframe :: proc(chart : Chart, timestamp : i32) -> Timeframe
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS
    currentTimeframe := i32(Timeframe.WEEK)

    for (timestamp - chart.candles[currentTimeframe].offset) % timeframeIncrements[currentTimeframe] != 0 &&
        currentTimeframe > 0
    {
        currentTimeframe -= 1
    }

    return Timeframe(currentTimeframe)
}

Chart_GetRangeHighAndLow :: proc(chart : Chart, startTimestamp : i32, endTimestamp : i32) -> (f32, f32)
{
    timeframe := math.min(Chart_TimestampToTimeframe(chart, startTimestamp), Chart_TimestampToTimeframe(chart, endTimestamp))

    numCandles := i32(len(chart.candles[timeframe].candles))

    candlesStartIndex := math.clamp(CandleList_TimestampToIndex(chart.candles[timeframe], startTimestamp), 0, numCandles - 1)
    candlesEndIndex := math.clamp(CandleList_TimestampToIndex(chart.candles[timeframe], endTimestamp), 1, numCandles)

    capturedCandles := chart.candles[timeframe].candles[candlesStartIndex:candlesEndIndex]

    high := capturedCandles[0].high
    low := capturedCandles[0].low

    for candle in capturedCandles[1:]
    {
        high = math.max(high, candle.high)
        low = math.min(low, candle.low)
    }

    return high, low
}
