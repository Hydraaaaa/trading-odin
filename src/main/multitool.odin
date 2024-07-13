package main

import "core:fmt"
import "core:math"

import "vendor:raylib"

LEVEL_CIRCLE_RADIUS :: 5
FIB_618_COLOR :: raylib.Color{255, 255, 127, 255}

Multitool :: struct
{
	startTimestamp : i32,
	endTimestamp : i32,
	high : f32,
	low  : f32,

    volumeProfile : VolumeProfile,

    drawPoc : bool,
    drawVal : bool,
    drawVah : bool,
    drawTvVal : bool,
    drawTvVah : bool,
    drawVwap : bool,
    draw618 : bool,
    
	isUpsideDown : bool,
}

MultitoolLevel :: enum
{
	NONE = -1,
	POC = 0,
	VAL = 1,
	VAH = 2,
	TV_VAL = 3,
	TV_VAH = 4,
	VWAP = 5,
	FIB_618 = 6,
}

Edge :: enum
{
	NONE = 0,
	TOPLEFT = 1,
	TOP = 2,
	TOPRIGHT = 3,
	LEFT = 4,
	RIGHT = 5,
	BOTTOMLEFT = 6,
	BOTTOM = 7,
	BOTTOMRIGHT = 8,
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
		bucketIndex < len(multitool.volumeProfile.buckets) - 1
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

	profileHigh := multitool.volumeProfile.bottomPrice + f32(len(multitool.volumeProfile.buckets)) * multitool.volumeProfile.bucketSize
	profileLow := multitool.volumeProfile.bottomPrice

	// TODO: Depends on if VolumeProfile is active
	return profileHigh >= low &&
	       profileLow <= high &&
	       multitool.startTimestamp <= endTimestamp &&
	       multitool.endTimestamp + (multitool.endTimestamp - multitool.startTimestamp) >= startTimestamp
}

Multitool_GetOverlappingEdge :: proc(multitool : Multitool, posX : i32, posY : i32, scaleData : ScaleData) -> Edge
{
	EDGE_THICKNESS :: 3

	leftPos := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	rightPos := Timestamp_ToPixelX(multitool.endTimestamp, scaleData)
	topPos := Price_ToPixelY(multitool.high, scaleData)
	bottomPos := Price_ToPixelY(multitool.low, scaleData)

	// Corners
	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= leftPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= topPos + EDGE_THICKNESS
	{
		return .TOPLEFT
	}

	if posX >= rightPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= topPos + EDGE_THICKNESS
	{
		return .TOPRIGHT
	}

	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= leftPos + EDGE_THICKNESS &&
	   posY >= bottomPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .BOTTOMLEFT
	}

	if posX >= rightPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= bottomPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .BOTTOMRIGHT
	}

	// Edges
	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= topPos + EDGE_THICKNESS
	{
		return .TOP
	}

	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= leftPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .LEFT
	}

	if posX >= rightPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .RIGHT
	}

	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= bottomPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .BOTTOM
	}

	return .NONE
}

Multitool_LevelAtPoint :: proc(multitool : Multitool, posX : i32, posY : i32, scaleData : ScaleData) -> MultitoolLevel 
{
	SQR_RADIUS :: LEVEL_CIRCLE_RADIUS * LEVEL_CIRCLE_RADIUS

	distX := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - posX
	targetSqrDistY := SQR_RADIUS - distX * distX
	
	levelY := Price_ToPixelY(multitool.volumeProfile.vwap, scaleData)
	distY := levelY - posY
	if distY * distY < targetSqrDistY { return .VWAP }

	levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.pocIndex), scaleData)
	distY = levelY - posY
	if distY * distY < targetSqrDistY { return .POC }

	levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.valIndex), scaleData)
	distY = levelY - posY
	if distY * distY < targetSqrDistY { return .VAL }

	levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.vahIndex), scaleData)
	distY = levelY - posY
	if distY * distY < targetSqrDistY { return .VAH }

	levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.tvValIndex), scaleData)
	distY = levelY - posY
	if distY * distY < targetSqrDistY { return .TV_VAL }

	levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.tvVahIndex), scaleData)
	distY = levelY - posY
	if distY * distY < targetSqrDistY { return .TV_VAH }

	priceRange := multitool.high - multitool.low

	if multitool.isUpsideDown
	{
		levelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData)
	}
	else
	{
		levelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData)
	}

	distY = levelY - posY
	if distY * distY < targetSqrDistY { return .FIB_618 }

	return .NONE
}

Multitool_Draw :: proc(multitool : Multitool, cameraPosX : i32, cameraPosY : i32, scaleData : ScaleData)
{
	startPixel := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	width := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - startPixel
	VolumeProfile_DrawBody(multitool.volumeProfile, startPixel - cameraPosX, width, cameraPosY, scaleData, 63)
	VolumeProfile_DrawLevels(multitool.volumeProfile, startPixel - cameraPosX + width, width, cameraPosY, scaleData, 191, multitool.drawPoc, multitool.drawVal, multitool.drawVah, multitool.drawTvVal, multitool.drawTvVah, multitool.drawVwap)

	priceRange := multitool.high - multitool.low

	fibStartPixel := startPixel + width - cameraPosX
	fibEndPixel := startPixel + width + width - cameraPosX

	if multitool.draw618
	{
		pixelY : i32 = ---

		if multitool.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData) - cameraPosY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData) - cameraPosY
		}

		raylib.DrawLine(fibStartPixel, pixelY, fibEndPixel, pixelY, FIB_618_COLOR)
	}
}
