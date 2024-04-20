package main

import "core:fmt"
import "vendor:raylib"

DrawVolumeProfile :: proc(posX : i32, width : i32, cameraPosY : i32, profile : VolumeProfile, scaleData : ScaleData)
{
    for bucket, index in profile.buckets
    {
        bucketStartPixel := Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(index), scaleData) - cameraPosY
        bucketEndPixel := Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(index + 1), scaleData) - cameraPosY
        
        bucketThickness := bucketStartPixel - bucketEndPixel
        
        if bucketThickness < 1
        {
            bucketThickness = 1
        }
        
        buyPixels := i32(bucket.buyVolume / profile.highestBucketVolume * f32(width))
        sellPixels := i32(bucket.sellVolume / profile.highestBucketVolume * f32(width))

        raylib.DrawRectangle(posX, bucketEndPixel, buyPixels, bucketThickness, raylib.BLUE)
        raylib.DrawRectangle(posX + buyPixels, bucketEndPixel, sellPixels, bucketThickness, raylib.ORANGE)
    }
}