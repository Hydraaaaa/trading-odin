package main

import "core:fmt"
import "core:math"

VolumeProfile :: struct
{
    bottomPrice : f32,
    bucketSize : f32,
    buckets : [dynamic]f32,
}

VolumeProfile_Create :: proc{VolumeProfile_CreateFromTrades, VolumeProfile_CreateFromCandles}

VolumeProfile_CreateFromTrades :: proc(trades : []Trade, high : f32, low : f32, bucketSize : f32 = 10) -> VolumeProfile
{
    profile : VolumeProfile
    
    profile.bottomPrice = low - math.mod(low, bucketSize)
    profile.bucketSize = bucketSize
    
    topPrice := high - math.mod(high, bucketSize) + bucketSize
    
    resize(&profile.buckets, int((topPrice - profile.bottomPrice) / bucketSize))
    
    for trade in trades
    {
        profile.buckets[int((trade.price - profile.bottomPrice) / bucketSize)] += trade.volume
    }
    
    return profile
}

VolumeProfile_CreateFromCandles :: proc(candles : []Candle, bucketSize : f32 = 10) -> VolumeProfile
{
    fmt.println("VolumeProfile_CreateFromCandles is not yet implemented")
    return VolumeProfile{}
}