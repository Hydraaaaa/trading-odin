package main

import "core:math"

ScaleData :: struct
{
	horizontalScale : f32,
	verticalScale : f32,
	zoom : f32,
	logScale : bool,
}

ToPixelX :: proc(scaleData : ScaleData, timestamp : i32) -> f32
{
	return f32(timestamp) / (scaleData.horizontalScale * scaleData.zoom)
}

ToTimestamp :: proc(scaleData : ScaleData, pixelX : f32) -> i32
{
	return i32(f32(pixelX) * (scaleData.horizontalScale * scaleData.zoom))
}

ToPixelY :: proc(scaleData : ScaleData, price : f32) -> f32
{
	if scaleData.logScale
	{
		return -(math.log10(price) / (scaleData.verticalScale * scaleData.zoom))
	}
	else
	{
		return -(price / (scaleData.verticalScale * scaleData.zoom))
	}
}

ToPrice :: proc(scaleData : ScaleData, pixelY : f32) -> f32
{
	if scaleData.logScale
	{
		return math.pow(10, -(f32(pixelY) * (scaleData.verticalScale * scaleData.zoom)))
	}
	else
	{
		return -(f32(pixelY) * (scaleData.verticalScale * scaleData.zoom))
	}
}
