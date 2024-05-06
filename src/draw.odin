package main

import "core:fmt"
import "core:math"
import "vendor:raylib"

DrawVolumeProfile :: proc(posX : i32, width : i32, cameraPosY : i32, profile : VolumeProfile, scaleData : ScaleData, drawValueArea : bool = true, drawVwap : bool = true)
{
    highestBucketVolume := profile.buckets[profile.pocIndex].buyVolume + profile.buckets[profile.pocIndex].sellVolume

    for bucket, index in profile.buckets
    {
        bucketStartPixel := Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(index), scaleData) - cameraPosY
        bucketEndPixel := Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(index + 1), scaleData) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        buyPixels := i32(bucket.buyVolume / highestBucketVolume * f32(width))
        sellPixels := i32(bucket.sellVolume / highestBucketVolume * f32(width))

        raylib.DrawRectangle(posX, bucketEndPixel, buyPixels, bucketThickness, raylib.BLUE)
        raylib.DrawRectangle(posX + buyPixels, bucketEndPixel, sellPixels, bucketThickness, raylib.ORANGE)
    }

    if drawValueArea
    {
        bucketStartPixel := Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(profile.pocIndex), scaleData) - cameraPosY
        bucketEndPixel := Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(profile.pocIndex + 1), scaleData) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        color := raylib.RED
        color.a = 191

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)

        color = raylib.SKYBLUE
        color.a = 191

        bucketStartPixel = Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(profile.newValIndex), scaleData) - cameraPosY
        bucketEndPixel = Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(profile.newValIndex + 1), scaleData) - cameraPosY

        bucketThickness = math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)

        bucketStartPixel = Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(profile.newVahIndex), scaleData) - cameraPosY
        bucketEndPixel = Price_ToPixelY(profile.bottomPrice + profile.bucketSize * f32(profile.newVahIndex + 1), scaleData) - cameraPosY

        bucketThickness = math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)
    }

    if drawVwap
    {
        pixelY := Price_ToPixelY(profile.vwap, scaleData) - cameraPosY

        color := raylib.PURPLE
        color.a = 191

        raylib.DrawRectangle(posX, pixelY, width, 1, color)
    }
}