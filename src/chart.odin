package main

CANDLE_TIMEFRAME_INCREMENTS : [10]i32 : {60, 300, 900, 1800, 3600, 10_800, 21_600, 43_200, 86_400, 604_800}

TIMEFRAME_COUNT :: 11

Chart :: struct
{
    candles : [TIMEFRAME_COUNT]CandleList,
    hourVolumeProfilePool : VolumeProfilePool,
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

        prevCandlesLen := len(prevCandles)

        timeframeDivisor := int(candleTimeframeIncrements[timeframe] / candleTimeframeIncrements[prevTimeframe])
        
        // + 1 accounts for a higher timeframe candle at the beginning with only partial data
        reserve(&chart.candles[timeframe].candles, prevCandlesLen / timeframeDivisor + 1)
        
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
            
            start = end
            end += timeframeDivisor
        }
        
        // Create a final partial candle if applicable (like on weekly candles)
        if start < prevCandlesLen
        {
            append(&chart.candles[timeframe].candles, Candle_Merge(..prevCandles[start:prevCandlesLen]))
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
    }
}