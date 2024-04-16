package main

import "core:math"
import "core:fmt"

Price_ToPixelY :: proc(price : f32, scaleData : ScaleData) -> i32
{
	if scaleData.logScale
	{
		return -i32(f64(math.log10(price)) / (scaleData.verticalScale * scaleData.verticalZoom))
	}
	else
	{
		return -i32(f64(price) / (scaleData.verticalScale * scaleData.verticalZoom))
	}
}

Price_ToPixelY_f32 :: proc(price : f32, scaleData : ScaleData) -> f32
{
	if scaleData.logScale
	{
		return -f32(f64(math.log10(price)) / (scaleData.verticalScale * scaleData.verticalZoom))
	}
	else
	{
		return -f32(f64(price) / (scaleData.verticalScale * scaleData.verticalZoom))
	}
}

Price_FromPixelY :: proc(pixelY : i32, scaleData : ScaleData) -> f32
{
	if scaleData.logScale
	{
		return f32(math.pow(10, -f64(pixelY) * (scaleData.verticalScale * scaleData.verticalZoom)))
	}
	else
	{
		return f32(-f64(pixelY) * (scaleData.verticalScale * scaleData.verticalZoom))
	}
}

Price_FromPixelY_f32 :: proc(pixelY : f32, scaleData : ScaleData) -> f32
{
	if scaleData.logScale
	{
		return f32(math.pow(10, -f64(pixelY) * (scaleData.verticalScale * scaleData.verticalZoom)))
	}
	else
	{
		return f32(-f64(pixelY) * (scaleData.verticalScale * scaleData.verticalZoom))
	}
}