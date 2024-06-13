package main

import "core:fmt"
import "core:math"
import "vendor:raylib"

DrawVolumeProfile :: proc(posX : i32, width : i32, cameraPosY : i32, profile : VolumeProfile, scaleData : ScaleData, alpha : u8 = 255, drawBody : bool = true, drawPoc : bool = true, drawVa : bool = true, drawTvVa : bool = true, drawVwap : bool = true)
{
    if drawBody
    {
        highestBucketVolume := profile.buckets[profile.pocIndex].buyVolume + profile.buckets[profile.pocIndex].sellVolume

        for bucket, index in profile.buckets
        {
            bucketStartPixel := VolumeProfile_BucketToPixelY(profile, index, scaleData) - cameraPosY
            bucketEndPixel := VolumeProfile_BucketToPixelY(profile, index + 1, scaleData) - cameraPosY

            bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

            buyPixels := i32(bucket.buyVolume / highestBucketVolume * f32(width))
            sellPixels := i32(bucket.sellVolume / highestBucketVolume * f32(width))

            blueColor := raylib.BLUE
            blueColor.a = alpha
            orangeColor := raylib.ORANGE
            orangeColor.a = alpha

            raylib.DrawRectangle(posX, bucketEndPixel, buyPixels, bucketThickness, blueColor)
            raylib.DrawRectangle(posX + buyPixels, bucketEndPixel, sellPixels, bucketThickness, orangeColor)
        }
    }

    if drawPoc
    {
        color := raylib.RED
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.pocIndex, scaleData) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.pocIndex + 1, scaleData) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)
    }

    if drawVa
    {
        color := raylib.SKYBLUE
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.valIndex, scaleData) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.valIndex + 1, scaleData) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)

        bucketStartPixel = VolumeProfile_BucketToPixelY(profile, profile.vahIndex, scaleData) - cameraPosY
        bucketEndPixel = VolumeProfile_BucketToPixelY(profile, profile.vahIndex + 1, scaleData) - cameraPosY

        bucketThickness = math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)
    }

    if drawTvVa
    {
        color := raylib.BLUE
        color.a = alpha

        bucketStartPixel := VolumeProfile_BucketToPixelY(profile, profile.tvValIndex, scaleData) - cameraPosY
        bucketEndPixel := VolumeProfile_BucketToPixelY(profile, profile.tvValIndex + 1, scaleData) - cameraPosY

        bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)

        bucketStartPixel = VolumeProfile_BucketToPixelY(profile, profile.tvVahIndex, scaleData) - cameraPosY
        bucketEndPixel = VolumeProfile_BucketToPixelY(profile, profile.tvVahIndex + 1, scaleData) - cameraPosY

        bucketThickness = math.max(bucketStartPixel - bucketEndPixel, 1)

        raylib.DrawRectangle(posX, bucketEndPixel, width, bucketThickness, color)
    }

    if drawVwap
    {
        pixelY := Price_ToPixelY(profile.vwap, scaleData) - cameraPosY

        color := raylib.PURPLE
        color.a = alpha

        raylib.DrawRectangle(posX, pixelY, width, 1, color)
    }
}