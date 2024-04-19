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
    buyVolume : f32,
    sellVolume : f32,
}

VolumeProfile_Create :: proc{VolumeProfile_CreateFromTrades, VolumeProfile_CreateFromCandles}

VolumeProfile_CreateFromTrades :: proc(trades : []Trade, high : f32, low : f32, bucketSize : f32 = 50) -> VolumeProfile
{
    profile : VolumeProfile
    
    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize
    
    topPrice := high - math.mod(high, bucketSize) + bucketSize
    
    resize(&profile.buckets, int((topPrice - profile.bottomPrice) / bucketSize))
    
    for trade in trades
    {
        if trade.isBuy
        {
            profile.buckets[int((trade.price - profile.bottomPrice) / bucketSize)].buyVolume += trade.volume
        }
        else
        {
            profile.buckets[int((trade.price - profile.bottomPrice) / bucketSize)].sellVolume += trade.volume
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
    fmt.println("VolumeProfile_CreateFromCandles is not yet implemented")
    return VolumeProfile{}
}