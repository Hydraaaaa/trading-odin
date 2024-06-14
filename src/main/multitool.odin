package main

import "core:fmt"
import "core:math"

Multitool :: struct
{
	startTimestamp : i32,
	endTimestamp : i32,

    volumeProfile : VolumeProfile,
	volumeProfileHigh : f32,
	volumeProfileLow : f32,

	fibHigh : f32,
	fibLow : f32,
}

Multitool_Destroy :: proc(multitool : Multitool)
{
    VolumeProfile_Destroy(multitool.volumeProfile)
}

Multitool_IsOverlapping :: proc{Multitool_IsOverlappingPoint, Multitool_IsOverlappingRect}

// Precise, used for cursor
Multitool_IsOverlappingPoint :: proc(multitool : Multitool, posX : i32, posY : i32, scaleData : ScaleData) -> bool
{
	if !Multitool_IsOverlappingRect(multitool, posX, posY, 0, 0, scaleData)
	{
		return false
	}

	multitoolStartPosX := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	multitoolEndPosX := Timestamp_ToPixelX(multitool.endTimestamp, scaleData)

	// If hovering the right side of the profile, compare against value area lines etc
	if posX > multitoolEndPosX
	{
		bucketIndices := []int{multitool.volumeProfile.pocIndex, multitool.volumeProfile.vahIndex, multitool.volumeProfile.valIndex, multitool.volumeProfile.tvVahIndex, multitool.volumeProfile.tvValIndex }

		for index in bucketIndices
		{
			bucketStartPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, index, scaleData)
			bucketEndPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, index + 1, scaleData)

			bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

			if posY >= bucketEndPixel && posY < bucketEndPixel + bucketThickness ||
			   bucketThickness == 1 && math.abs(posY - bucketStartPixel) < 3
			{
				return true
			}
		}

		// Check overlap with VWAP
		return math.abs(posY - Price_ToPixelY(multitool.volumeProfile.vwap, scaleData)) < 3
	}

	// Compare against the profile itself

	width := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - Timestamp_ToPixelX(multitool.startTimestamp, scaleData)

	bucketIndex := VolumeProfile_PixelYToBucket(multitool.volumeProfile, posY, scaleData)

	volume := multitool.volumeProfile.buckets[bucketIndex].buyVolume + multitool.volumeProfile.buckets[bucketIndex].sellVolume

	startBucketPixel := posY
	currentBucketPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, bucketIndex + 1, scaleData)

	// If there are multiple buckets within one pixel, only draw the biggest
	for currentBucketPixel == startBucketPixel &&
		bucketIndex < len(multitool.volumeProfile.buckets)
	{
		bucketIndex += 1

		volume = math.max(volume, multitool.volumeProfile.buckets[bucketIndex].buyVolume + multitool.volumeProfile.buckets[bucketIndex].sellVolume)

		currentBucketPixel = VolumeProfile_BucketToPixelY(multitool.volumeProfile, bucketIndex + 1, scaleData)
	}

	highestBucketVolume := multitool.volumeProfile.buckets[multitool.volumeProfile.pocIndex].buyVolume + multitool.volumeProfile.buckets[multitool.volumeProfile.pocIndex].sellVolume

	return posX <= multitoolStartPosX + i32(f32(width) * (volume / highestBucketVolume))
}

// Approximate, used for culling
Multitool_IsOverlappingRect :: proc(multitool : Multitool, posX : i32, posY : i32, width : i32, height : i32, scaleData : ScaleData) -> bool
{
	startTimestamp := Timestamp_FromPixelX(posX, scaleData)
	endTimestamp := Timestamp_FromPixelX(posX + width, scaleData)
	high := Price_FromPixelY(posY, scaleData)
	low := Price_FromPixelY(posY + height, scaleData)

	// TODO: Depends on if VolumeProfile is active
	return multitool.volumeProfileHigh >= low &&
	       multitool.volumeProfileLow <= high &&
	       multitool.startTimestamp <= endTimestamp &&
	       multitool.endTimestamp + (multitool.endTimestamp - multitool.startTimestamp) >= startTimestamp
}