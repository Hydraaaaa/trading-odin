package main

import "core:fmt"
import "core:math"

import "vendor:raylib"

VOLUME_PROFILE_BUY_COLOR :: raylib.Color{41, 98, 255, 255} // Matching TradingView
VOLUME_PROFILE_SELL_COLOR :: raylib.Color{251, 192, 45, 255} // Matching TradingView
POC_COLOR :: raylib.RED
VAL_COLOR :: raylib.SKYBLUE
VAH_COLOR :: raylib.SKYBLUE
TV_VAL_COLOR :: raylib.BLUE
TV_VAH_COLOR :: raylib.BLUE
VWAP_COLOR :: raylib.PURPLE

VolumeProfile_DrawFlag :: enum
{
	BODY,
	POC,
	VAL,
	VAH,
	TV_VAL,
	TV_VAH,
	VWAP,
}

VolumeProfile_DrawFlagSet :: bit_set[VolumeProfile_DrawFlag]

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
// Must be freed with VolumeProfile_Destroy
VolumeProfile_Create :: proc(startTimestamp : i32, endTimestamp : i32, chart : Chart, bucketSize : f32 = 5) -> VolumeProfile
{
    assert(bucketSize > 0, "VolumeProfile_Create called with invalid bucketSize")

    high, low := Chart_GetRangeHighAndLow(chart, startTimestamp, endTimestamp)

    // If bucketSize doesn't align with pool, revert to slower method
    if math.mod(bucketSize, f32(chart.hourVolumeProfilePool.bucketSize)) != 0
    {
        fmt.println("WARNING: VolumeProfile_Create bucketSize mismatch, will be very slow")

        trades : [dynamic]Trade
        reserve(&trades, 262_144)

        LoadTradesBetween(startTimestamp, endTimestamp, &trades)

        return VolumeProfile_CreateFromTrades(trades[:], high, low, bucketSize)
    }

    profile := VolumeProfile_CreateBuckets(startTimestamp, endTimestamp, high, low, chart, bucketSize)

    VolumeProfile_Finalize(&profile)

    return profile
}

@(private)
VolumeProfile_CreateBuckets :: proc(startTimestamp : i32, endTimestamp : i32, high : f32, low : f32, chart : Chart, bucketSize : f32) -> VolumeProfile
{
    profile : VolumeProfile

    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize

    topPrice := high - math.mod(high, bucketSize) + bucketSize

    profile.buckets = make([]VolumeProfileBucket, int((topPrice - profile.bottomPrice) / bucketSize))

    // (startTimestamp - 1) + 1 effectively makes the index round up instead of down
    // So a timestamp on an exact hour will match, but anything above that will point to the next hour
    startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.HOUR], startTimestamp - 1) + 1
    startIndex = math.clamp(startIndex, 0, i32(len(chart.candles[Timeframe.HOUR].candles) - 1))
    startIndexTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.HOUR], startIndex)

    endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.HOUR], endTimestamp)
    endIndex = math.clamp(endIndex, 0, i32(len(chart.candles[Timeframe.HOUR].candles) - 1))
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
            ((^[2]f32)(&profile.buckets[int((startTrades[i].price - profile.bottomPrice) / bucketSize)]))[int(startTrades[i].isBuy)] += startTrades[i].volume

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
                ((^[2]f32)(&profile.buckets[int((endTrades[i].price - profile.bottomPrice) / bucketSize)]))[int(endTrades[i].isBuy)] += endTrades[i].volume

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

    return profile
}

// Must be freed with VolumeProfile_Destroy
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

// Creates a volume profile using only the data available from the provided candles  
// Must be freed with VolumeProfile_Destroy
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

// Leverage an existing volume profile to avoid recalculating its range
VolumeProfile_Resize :: proc(profile : ^VolumeProfile, oldStartTimestamp : i32, oldEndTimestamp : i32, newStartTimestamp : i32, newEndTimestamp : i32, chart : Chart)
{
    // If the new region doesn't overlap the old region, regenerate
    // If the new region is less than half the size of the old region, regenerate (less work than shrinking)
    if newStartTimestamp > oldEndTimestamp ||
       newEndTimestamp < oldStartTimestamp ||
       newEndTimestamp - newStartTimestamp / 2 < oldEndTimestamp - oldStartTimestamp
    {
        delete(profile.buckets)
        profile^ = VolumeProfile_Create(newStartTimestamp, newEndTimestamp, chart, profile.bucketSize)
        return
    }

    oldHigh, oldLow := Chart_GetRangeHighAndLow(chart, oldStartTimestamp, oldEndTimestamp)
    newHigh, newLow := Chart_GetRangeHighAndLow(chart, newStartTimestamp, newEndTimestamp)

    newBottomPrice := newLow - math.mod(newLow, profile.bucketSize)
    newTopPrice := newHigh - math.mod(newHigh, profile.bucketSize) + profile.bucketSize

    newBuckets := make([]VolumeProfileBucket, int((newTopPrice - newBottomPrice) / profile.bucketSize))

    indexOffset := int((profile.bottomPrice - newBottomPrice) / profile.bucketSize)

    startIndex := math.max(indexOffset, 0)
    endIndex := math.min(indexOffset + len(profile.buckets), len(newBuckets))

    // Copy old data to new range
    for i in startIndex ..< endIndex
    {
        newBuckets[i] = profile.buckets[i - indexOffset]
    }

    // Add prepended data to profile
    if newStartTimestamp < oldStartTimestamp
    {
        beforeProfile := VolumeProfile_CreateBuckets(newStartTimestamp, oldStartTimestamp, newHigh, newLow, chart, profile.bucketSize)
        defer VolumeProfile_Destroy(beforeProfile)

        for bucket, i in beforeProfile.buckets
        {
            newBuckets[i].buyVolume += bucket.buyVolume
            newBuckets[i].sellVolume += bucket.sellVolume
        }
    }
    else if newStartTimestamp > oldStartTimestamp
    {
        // Shrink the profile by subtracting
        beforeProfile := VolumeProfile_CreateBuckets(oldStartTimestamp, newStartTimestamp, oldHigh, oldLow, chart, profile.bucketSize)
        defer VolumeProfile_Destroy(beforeProfile)

        indexOffset := int((beforeProfile.bottomPrice - newBottomPrice) / beforeProfile.bucketSize)

        startIndex := math.max(indexOffset, 0)
        endIndex := math.min(indexOffset + len(profile.buckets), len(newBuckets))

        // Copy old data to new range
        for i in startIndex ..< endIndex
        {
            newBuckets[i].buyVolume -= beforeProfile.buckets[i - indexOffset].buyVolume
            newBuckets[i].sellVolume -= beforeProfile.buckets[i - indexOffset].sellVolume
        }
    }

    // Add appended data to profile
    if newEndTimestamp > oldEndTimestamp
    {
        afterProfile := VolumeProfile_CreateBuckets(oldEndTimestamp, newEndTimestamp, newHigh, newLow, chart, profile.bucketSize)
        defer VolumeProfile_Destroy(afterProfile)

        for bucket, i in afterProfile.buckets
        {
            newBuckets[i].buyVolume += bucket.buyVolume
            newBuckets[i].sellVolume += bucket.sellVolume
        }
    }
    else if newEndTimestamp < oldEndTimestamp
    {
        // Shrink the profile by subtracting
        beforeProfile := VolumeProfile_CreateBuckets(newEndTimestamp, oldEndTimestamp, oldHigh, oldLow, chart, profile.bucketSize)
        defer VolumeProfile_Destroy(beforeProfile)

        indexOffset := int((beforeProfile.bottomPrice - newBottomPrice) / beforeProfile.bucketSize)

        startIndex := math.max(indexOffset, 0)
        endIndex := math.min(indexOffset + len(profile.buckets), len(newBuckets))

        // Copy old data to new range
        for i in startIndex ..< endIndex
        {
            newBuckets[i].buyVolume -= beforeProfile.buckets[i - indexOffset].buyVolume
            newBuckets[i].sellVolume -= beforeProfile.buckets[i - indexOffset].sellVolume
        }
    }

    delete(profile.buckets)
    profile.bottomPrice = newBottomPrice
    profile.buckets = newBuckets

    VolumeProfile_Finalize(profile)
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
    // Find the smallest area with a total volume no less than the required volume
    startIndex := 0
    numBuckets := 1
    requiredVolume := totalVolume * 0.682
    currentVolume = profile.buckets[0].buyVolume + profile.buckets[0].sellVolume

    // Determine the initial area size (number of buckets needed to reach the required volume starting from index 0)
    for currentVolume < requiredVolume
    {
        currentVolume += profile.buckets[numBuckets].buyVolume + profile.buckets[numBuckets].sellVolume
        numBuckets += 1
    }

    newVolume := currentVolume - profile.buckets[0].buyVolume - profile.buckets[0].sellVolume
    newStartIndex := startIndex + 1
    newNumBuckets := numBuckets

    // Loop through the profile, incrementing the starting index
    // Shrink the area whenever a smaller area still meets the required volume
    for newStartIndex + newNumBuckets < len(profile.buckets)
    {
        newVolume += profile.buckets[newStartIndex + newNumBuckets].buyVolume + profile.buckets[newStartIndex + newNumBuckets].sellVolume

        if newVolume > currentVolume
        {
            currentVolume = newVolume
            startIndex = newStartIndex
        }

        smallerAreaVolume := newVolume - profile.buckets[newStartIndex].buyVolume + profile.buckets[newStartIndex].sellVolume
        smallerAreaStartIndex := newStartIndex + 1
        smallerAreaNumBuckets := newNumBuckets - 1

        for smallerAreaVolume > requiredVolume &&
            smallerAreaNumBuckets > 0
        {
            currentVolume = smallerAreaVolume
            newVolume = smallerAreaVolume
            startIndex = smallerAreaStartIndex
            newStartIndex = smallerAreaStartIndex
            numBuckets = smallerAreaNumBuckets
            newNumBuckets = smallerAreaNumBuckets

            smallerAreaVolume -= profile.buckets[smallerAreaStartIndex].buyVolume + profile.buckets[smallerAreaStartIndex].sellVolume
            smallerAreaStartIndex += 1
            smallerAreaNumBuckets -= 1
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

    for currentVolume < requiredVolume
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

VolumeProfile_Draw :: proc(profile : VolumeProfile, \
                           posX : f32, \
                           width : f32, \
                           cameraPosY : f32, \
                           scaleData : ScaleData, \
                           alpha : u8 = 255, \
                           drawFlags : VolumeProfile_DrawFlagSet = {.BODY, .POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
{
    using raylib
    
    if .BODY in drawFlags
    {
        highestBucketVolume := profile.buckets[profile.pocIndex].buyVolume + profile.buckets[profile.pocIndex].sellVolume

        bucketIndex := math.max(0,                    VolumeProfile_PixelYToBucket(profile, cameraPosY + f32(GetScreenHeight()), scaleData))
        endIndex :=    math.min(len(profile.buckets), VolumeProfile_PixelYToBucket(profile, cameraPosY, scaleData) + 1)
        
        blueColor := VOLUME_PROFILE_BUY_COLOR
        blueColor.a = alpha
        orangeColor := VOLUME_PROFILE_SELL_COLOR
        orangeColor.a = alpha

        for bucketIndex < endIndex
        {
            buyVolume := profile.buckets[bucketIndex].buyVolume
            totalVolume := profile.buckets[bucketIndex].buyVolume + profile.buckets[bucketIndex].sellVolume

            bucketStartPixel := VolumeProfile_BucketToPixelY(profile, bucketIndex, scaleData, true) - cameraPosY
            bucketEndPixel := VolumeProfile_BucketToPixelY(profile, bucketIndex + 1, scaleData, true) - cameraPosY

            // If there are multiple buckets within one pixel, only draw the biggest
            for bucketStartPixel - bucketEndPixel < 1 &&
                bucketIndex < endIndex - 1
            {
                bucketIndex += 1

                buyVolume = math.max(buyVolume, profile.buckets[bucketIndex].buyVolume)
                totalVolume = math.max(totalVolume, profile.buckets[bucketIndex].buyVolume + profile.buckets[bucketIndex].sellVolume)

                bucketEndPixel = VolumeProfile_BucketToPixelY(profile, bucketIndex + 1, scaleData, true) - cameraPosY
            }

            bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

            buyPixels := buyVolume / highestBucketVolume * width
            sellPixels := (totalVolume - buyVolume) / highestBucketVolume * width

            DrawRectangleRec(Rectangle{posX, bucketEndPixel, buyPixels, bucketThickness}, blueColor)
            DrawRectangleRec(Rectangle{posX + buyPixels, bucketEndPixel, sellPixels, bucketThickness}, orangeColor)

            bucketIndex += 1
        }
    }
    
    if .POC in drawFlags
    {
        color := POC_COLOR
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.pocIndex, scaleData, true) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.pocIndex + 1, scaleData, true) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        DrawRectangleRec(Rectangle{posX, bucketEndPixel, width, bucketThickness}, color)
    }

    if .VAL in drawFlags
    {
        color := VAL_COLOR
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.valIndex, scaleData, true) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.valIndex + 1, scaleData, true) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        DrawRectangleRec(Rectangle{posX, bucketEndPixel, width, bucketThickness}, color)
    }

    if .VAH in drawFlags
    {
        color := VAH_COLOR
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.vahIndex, scaleData, true) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.vahIndex + 1, scaleData, true) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        DrawRectangleRec(Rectangle{posX, bucketEndPixel, width, bucketThickness}, color)
    }

    if .TV_VAL in drawFlags
    {
        color := TV_VAL_COLOR
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.tvValIndex, scaleData, true) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.tvValIndex + 1, scaleData, true) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        DrawRectangleRec(Rectangle{posX, bucketEndPixel, width, bucketThickness}, color)
    }

    if .TV_VAH in drawFlags
    {
        color := TV_VAH_COLOR
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.tvVahIndex, scaleData, true) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.tvVahIndex + 1, scaleData, true) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        DrawRectangleRec(Rectangle{posX, bucketEndPixel, width, bucketThickness}, color)
    }

    if .VWAP in drawFlags
    {
        pixelY := Price_ToPixelY(profile.vwap, scaleData) - cameraPosY

        color := VWAP_COLOR
        color.a = alpha

        DrawRectangleRec(Rectangle{posX, pixelY, width, 1}, color)
    }
}

VolumeProfile_BucketToPrice :: proc(profile : VolumeProfile, index : int, roundDown : bool = false) -> f32
{
    return profile.bottomPrice + f32(index) * profile.bucketSize + profile.bucketSize / 2 * f32(int(!roundDown))

    // Performant version of the below code
    //if roundDown
    //{
        //return profile.bottomPrice + f32(index) * profile.bucketSize
    //}
    //else
    //{
        //return profile.bottomPrice + f32(index) * profile.bucketSize + profile.bucketSize / 2
    //}
}

VolumeProfile_BucketToPixelY :: proc(profile : VolumeProfile, index : int, scaleData : ScaleData, roundDown : bool = false) -> f32
{
    return Price_ToPixelY(VolumeProfile_BucketToPrice(profile, index, roundDown), scaleData)
}

VolumeProfile_PriceToBucket :: proc(profile : VolumeProfile, price : f32) -> int
{
    return int((price - profile.bottomPrice) / profile.bucketSize)
}

VolumeProfile_PixelYToBucket :: proc(profile : VolumeProfile, pixelY : f32, scaleData : ScaleData) -> int
{
    return VolumeProfile_PriceToBucket(profile, Price_FromPixelY(pixelY, scaleData))
}
