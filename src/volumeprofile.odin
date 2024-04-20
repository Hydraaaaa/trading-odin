package main

import "core:fmt"
import "core:math"

VolumeProfile :: struct
{
    bottomPrice : f32,
    bucketSize : f32,
    buckets : [dynamic]VolumeProfileBucket,
    highestBucketVolume : f32
}

VolumeProfileBucket :: struct
{
    sellVolume : f32,
    buyVolume : f32,
}

VolumeProfile_Create :: proc{VolumeProfile_CreateFromTrades, VolumeProfile_CreateFromCandles}

VolumeProfile_CreateFromTrades :: proc(trades : []Trade, high : f32, low : f32, bucketSize : f32 = 50) -> VolumeProfile
{
    profile : VolumeProfile
    
    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize
    
    topPrice := high - math.mod(high, bucketSize) + bucketSize
    
    resize(&profile.buckets, int((topPrice - profile.bottomPrice) / bucketSize))
    
    #no_bounds_check \
    {
        lenTrades := len(trades)
        for i in 0 ..< lenTrades
        {
            // Cast a VolumeProfileBucket to [2]f32, and if isBuy is true, its value will be 1, which allows me to index buyVolume instead of sellVolume
            // This line of code is a performant alternative to the commented code below
            (transmute(^[2]f32)&profile.buckets[int((trades[i].price - profile.bottomPrice) / bucketSize)])[int(trades[i].isBuy)] += trades[i].volume

            //if trade.isBuy
            //{
            //    profile.buckets[int((trade.price - profile.bottomPrice) / bucketSize)].buyVolume += trade.volume
            //}
            //else
            //{
            //    profile.buckets[int((trade.price - profile.bottomPrice) / bucketSize)].sellVolume += trade.volume
            //}
        }
    }
    
    for bucket in profile.buckets
    {
        if bucket.buyVolume + bucket.sellVolume > profile.highestBucketVolume
        {
            profile.highestBucketVolume = bucket.buyVolume + bucket.sellVolume
        }
    }
    
    return profile
}

VolumeProfile_CreateFromCandles :: proc(candles : []Candle, high : f32, low : f32, bucketSize : f32 = 10) -> VolumeProfile
{
    profile : VolumeProfile
    
    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize
    
    topPrice := high - math.mod(high, bucketSize) + bucketSize
    
    resize(&profile.buckets, int((topPrice - profile.bottomPrice) / bucketSize))
    
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
    
    for bucket in profile.buckets
    {
        if bucket.buyVolume + bucket.sellVolume > profile.highestBucketVolume
        {
            profile.highestBucketVolume = bucket.buyVolume + bucket.sellVolume
        }
    }
    
    return profile
}