package main

import "core:fmt"
import "core:math"

VolumeProfilePool :: struct
{
    bucketSize : i32,
    headers : [dynamic]VolumeProfileHeader,
    buckets : [dynamic]VolumeProfileBucket,
}

VolumeProfileHeader :: struct
{
    bucketPoolIndex : i32,
    bucketCount : i32,
    relativeIndexOffset : i32, // When merging profiles, their bucket indices will align based on their offsets
}

VolumeProfile :: struct
{
    bucketSize : f32,
    bottomPrice : f32,
    buckets : []VolumeProfileBucket,

    pocIndex : int, // Point of Control
    valIndex : int, // Value Area Low
    vahIndex : int, // Value Area High

    tvValIndex : int, // TradingView Value Area Low
    tvVahIndex : int, // TradingView Value Area High

    vwap : f32,
}

VolumeProfileBucket :: struct
{
    sellVolume : f32,
    buyVolume : f32,
}

// Around 1000x faster if bucketSize is a multiple of provided pool's bucketSize
VolumeProfile_Create :: proc(startTimestamp : i32, endTimestamp : i32, high : f32, low : f32, chart : Chart, bucketSize : f32 = 5) -> VolumeProfile
{
    if bucketSize <= 0
    {
        fmt.println("ERROR: VolumeProfile_Create called with invalid bucketSize")
        return VolumeProfile{}
    }

    // If bucketSize doesn't align with pool, revert to slower method
    if math.mod(bucketSize, f32(chart.hourVolumeProfilePool.bucketSize)) != 0
    {
        fmt.println("WARNING: VolumeProfile_Create bucketSize mismatch, will be very slow")

        trades : [dynamic]Trade
        reserve(&trades, 262_144)

        LoadTradesBetween(startTimestamp, endTimestamp, &trades)

        return VolumeProfile_CreateFromTrades(trades[:], high, low, bucketSize)
    }

    profile : VolumeProfile

    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize

    topPrice := high - math.mod(high, bucketSize) + bucketSize

    profile.buckets = make([]VolumeProfileBucket, int((topPrice - profile.bottomPrice) / bucketSize))

    // (startTimestamp - 1) + 1 effectively makes the index round up instead of down
    // So a timestamp on an exact hour will match, but anything above that will point to the next hour
    startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.HOUR], startTimestamp - 1) + 1
    startIndex = math.max(startIndex, 0)
    startIndex = math.min(startIndex, i32(len(chart.candles[Timeframe.HOUR].candles) - 1))
    startIndexTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.HOUR], startIndex)

    endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.HOUR], endTimestamp)
    endIndex = math.max(endIndex, 0)
    endIndex = math.min(endIndex, i32(len(chart.candles[Timeframe.HOUR].candles) - 1))
    endIndexTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.HOUR], endIndex)

    tradesStartTimestamp := startTimestamp
    tradesEndTimestamp := startIndexTimestamp

    // If the entire timespan happens within a single hour candle, adjust bounds accordingly
    if startIndex >= endIndex
    {
        tradesEndTimestamp = endTimestamp
    }

    // Load any trades before the beginning of the first hour profile
    if tradesStartTimestamp < tradesEndTimestamp
    {
        startTrades : [dynamic]Trade
        LoadTradesBetween(tradesStartTimestamp, tradesEndTimestamp, &startTrades)

        lenTrades := len(startTrades)
        for i in 0 ..< lenTrades
        {
            // Cast a VolumeProfileBucket to [2]f32, and if isBuy is true, its value will be 1, which allows me to index buyVolume instead of sellVolume
            // This line of code is a performant alternative to the commented code below
            (transmute(^[2]f32)&profile.buckets[int((startTrades[i].price - profile.bottomPrice) / bucketSize)])[int(startTrades[i].isBuy)] += startTrades[i].volume

            //if startTrades[i].isBuy
            //{
            //    profile.buckets[int((startTrades[i].price - profile.bottomPrice) / bucketSize)].buyVolume += startTrades[i].volume
            //}
            //else
            //{
            //    profile.buckets[int((startTrades[i].price - profile.bottomPrice) / bucketSize)].sellVolume += startTrades[i].volume
            //}
        }
    }

    // If timespan extends beyond a single hour candle
    if startIndex < endIndex
    {
        tradesStartTimestamp = endIndexTimestamp
        tradesEndTimestamp = endTimestamp

        // Load any trades after the last whole hour profile
        if tradesStartTimestamp < tradesEndTimestamp
        {
            endTrades : [dynamic]Trade
            LoadTradesBetween(tradesStartTimestamp, tradesEndTimestamp, &endTrades)

            lenTrades := len(endTrades)
            for i in 0 ..< lenTrades
            {
                // Cast a VolumeProfileBucket to [2]f32, and if isBuy is true, its value will be 1, which allows me to index buyVolume instead of sellVolume
                // This line of code is a performant alternative to the commented code below
                (transmute(^[2]f32)&profile.buckets[int((endTrades[i].price - profile.bottomPrice) / bucketSize)])[int(endTrades[i].isBuy)] += endTrades[i].volume

                //if endTrades[i].isBuy
                //{
                //    profile.buckets[int((endTrades[i].price - profile.bottomPrice) / bucketSize)].buyVolume += endTrades[i].volume
                //}
                //else
                //{
                //    profile.buckets[int((endTrades[i].price - profile.bottomPrice) / bucketSize)].sellVolume += endTrades[i].volume
                //}
            }
        }
    }

    // Load hourly profiles
    profileIndexOffset := i32(low / bucketSize)

    if startIndex < endIndex
    {
        for profileHeader in chart.hourVolumeProfilePool.headers[startIndex:endIndex]
        {
            for bucket, i in chart.hourVolumeProfilePool.buckets[profileHeader.bucketPoolIndex:profileHeader.bucketPoolIndex + profileHeader.bucketCount]
            {
                profile.buckets[((profileHeader.relativeIndexOffset + i32(i)) * chart.hourVolumeProfilePool.bucketSize / i32(bucketSize)) - profileIndexOffset].buyVolume += bucket.buyVolume
                profile.buckets[((profileHeader.relativeIndexOffset + i32(i)) * chart.hourVolumeProfilePool.bucketSize / i32(bucketSize)) - profileIndexOffset].sellVolume += bucket.sellVolume
            }
        }
    }

    VolumeProfile_Finalize(&profile)

    return profile
}

VolumeProfile_CreateFromTrades :: proc(trades : []Trade, high : f32, low : f32, bucketSize : f32 = 5) -> VolumeProfile
{
    profile : VolumeProfile

    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize

    topPrice := high - math.mod(high, bucketSize) + bucketSize

    profile.buckets = make([]VolumeProfileBucket, int((topPrice - profile.bottomPrice) / bucketSize))

    lenTrades := len(trades)
    for i in 0 ..< lenTrades
    {
        // Cast a VolumeProfileBucket to [2]f32, and if isBuy is true, its value will be 1, which allows me to index buyVolume instead of sellVolume
        // This line of code is a performant alternative to the commented code below
        (transmute(^[2]f32)&profile.buckets[int((trades[i].price - profile.bottomPrice) / bucketSize)])[int(trades[i].isBuy)] += trades[i].volume

        //if trades[i].isBuy
        //{
        //    profile.buckets[int((trades[i].price - profile.bottomPrice) / bucketSize)].buyVolume += trades[i].volume
        //}
        //else
        //{
        //    profile.buckets[int((trades[i].price - profile.bottomPrice) / bucketSize)].sellVolume += trades[i].volume
        //}
    }

    VolumeProfile_Finalize(&profile)

    return profile
}

VolumeProfile_CreateFromCandles :: proc(candles : []Candle, high : f32, low : f32, bucketSize : f32 = 5) -> VolumeProfile
{
    profile : VolumeProfile

    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize

    topPrice := high - math.mod(high, bucketSize) + bucketSize

    profile.buckets = make([]VolumeProfileBucket, int((topPrice - profile.bottomPrice) / bucketSize))

    for candle in candles
    {
        totalBucketCoverage := (candle.high - candle.low) / bucketSize

        topBucketCoverage := math.mod(candle.high, bucketSize) / bucketSize
        bottomBucketCoverage := 1 - (math.mod(candle.low, bucketSize) / bucketSize)

        perBucketVolume := candle.volume / totalBucketCoverage

        startBucket := int((candle.low - profile.bottomPrice) / bucketSize)
        endBucket := startBucket + int(totalBucketCoverage - topBucketCoverage - bottomBucketCoverage) + 2

        if candle.open > candle.close
        {
            profile.buckets[startBucket].sellVolume += perBucketVolume * bottomBucketCoverage

            for i in startBucket + 1 ..< endBucket - 1
            {
                profile.buckets[i].sellVolume += perBucketVolume
            }

            profile.buckets[endBucket - 1].sellVolume += perBucketVolume * topBucketCoverage
        }
        else
        {
            profile.buckets[startBucket].buyVolume += perBucketVolume * bottomBucketCoverage

            for i in startBucket + 1 ..< endBucket - 1
            {
                profile.buckets[i].buyVolume += perBucketVolume
            }

            profile.buckets[endBucket - 1].buyVolume += perBucketVolume * topBucketCoverage
        }
    }

    VolumeProfile_Finalize(&profile)

    return profile
}

@(private)
VolumeProfile_Finalize :: proc(profile : ^VolumeProfile)
{
    // Calculate Point of Control + Total Volume
    highestBucketVolume := profile.buckets[0].buyVolume + profile.buckets[0].sellVolume
    totalVolume : f32 = highestBucketVolume

    for bucket, i in profile.buckets[1:]
    {
        if bucket.buyVolume + bucket.sellVolume > highestBucketVolume
        {
            highestBucketVolume = bucket.buyVolume + bucket.sellVolume
            profile.pocIndex = i + 1
        }

        totalVolume += bucket.buyVolume + bucket.sellVolume
    }

    // Calculate Volume Weighted Average Price
    vwapVolume := totalVolume / 2

    currentVolume : f32 = 0

    for bucket, i in profile.buckets
    {
        if currentVolume + bucket.buyVolume + bucket.sellVolume < vwapVolume
        {
            currentVolume += bucket.buyVolume + bucket.sellVolume
        }
        else
        {
            increment := vwapVolume - currentVolume

            // Get partial index based on the percentage of the bucket that gets counted before currentVolume == vwapVolume
            index := f32(i - 1) + (increment / (bucket.buyVolume + bucket.sellVolume))

            profile.vwap = profile.bottomPrice + index * profile.bucketSize
            break
        }
    }

    // Calculate Value Area
    startIndex := 0
    numBuckets := 1
    volumeThreshold := totalVolume * 0.682
    currentVolume = profile.buckets[0].buyVolume + profile.buckets[0].sellVolume

    for currentVolume < volumeThreshold
    {
        currentVolume += profile.buckets[numBuckets].buyVolume + profile.buckets[numBuckets].sellVolume
        numBuckets += 1
    }

    newVolume := currentVolume - profile.buckets[0].buyVolume - profile.buckets[0].sellVolume
    newStartIndex := startIndex + 1
    newNumBuckets := numBuckets

    for newStartIndex + newNumBuckets < len(profile.buckets)
    {
        newVolume += profile.buckets[newStartIndex + newNumBuckets].buyVolume + profile.buckets[newStartIndex + newNumBuckets].sellVolume

        if newVolume > currentVolume
        {
            currentVolume = newVolume
            startIndex = newStartIndex
        }

        smallerVolume := newVolume - profile.buckets[newStartIndex].buyVolume + profile.buckets[newStartIndex].sellVolume
        smallerStartIndex := newStartIndex + 1
        smallerNumBuckets := newNumBuckets - 1

        for smallerVolume > volumeThreshold
        {
            currentVolume = smallerVolume
            newVolume = smallerVolume
            startIndex = smallerStartIndex
            newStartIndex = smallerStartIndex
            numBuckets = smallerNumBuckets
            numBuckets = smallerNumBuckets

            smallerVolume -= profile.buckets[smallerStartIndex].buyVolume + profile.buckets[smallerStartIndex].sellVolume
            smallerStartIndex += 1
            smallerNumBuckets -= 1
        }

        newVolume -= profile.buckets[newStartIndex].buyVolume + profile.buckets[newStartIndex].sellVolume
        newStartIndex += 1
    }

    profile.valIndex = startIndex
    profile.vahIndex = startIndex + numBuckets

    // Calculate TradingView Value Area
    valIndex := profile.pocIndex
    vahIndex := profile.pocIndex
    currentVolume = highestBucketVolume

    for currentVolume < volumeThreshold
    {
        upperVolume := profile.buckets[math.min(vahIndex + 1, len(profile.buckets) - 1)].buyVolume + \
                       profile.buckets[math.min(vahIndex + 1, len(profile.buckets) - 1)].sellVolume + \
                       profile.buckets[math.min(vahIndex + 2, len(profile.buckets) - 1)].buyVolume + \
                       profile.buckets[math.min(vahIndex + 2, len(profile.buckets) - 1)].sellVolume

        lowerVolume := profile.buckets[math.max(valIndex - 1, 0)].buyVolume + \
                       profile.buckets[math.max(valIndex - 1, 0)].sellVolume + \
                       profile.buckets[math.max(valIndex - 2, 0)].buyVolume + \
                       profile.buckets[math.max(valIndex - 2, 0)].sellVolume

        if upperVolume > lowerVolume && vahIndex != len(profile.buckets) || valIndex == 0
        {
            currentVolume += upperVolume
            vahIndex = math.min(vahIndex + 2, len(profile.buckets) - 1)
        }
        else
        {
            currentVolume += lowerVolume
            valIndex = math.max(valIndex - 2, 0)
        }
    }

    profile.tvValIndex = valIndex
    profile.tvVahIndex = vahIndex
}

VolumeProfile_Destroy :: proc(profile : VolumeProfile)
{
    if profile.bucketSize != 0
    {
        delete(profile.buckets)
    }
}