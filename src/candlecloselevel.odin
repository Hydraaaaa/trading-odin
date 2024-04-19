package main

import "core:fmt"
import "vendor:raylib"

CandleCloseLevel :: struct
{
	startTimestamp : i32,
	endTimestamp : i32,
	price : f32,
}

CandleCloseLevels :: struct
{
	closeLevels : []CandleCloseLevel,
	closeLevelCount : int,

	color : raylib.Color,
}

//CreateCloseLevels :: proc(candles : []Candle, color : raylib.Color) -> CandleCloseLevels
//{
//	closeLevels : CandleCloseLevels
//	
//	closeLevels.color = color
//
//	// Could this upper limit be reduced?
//	closeLevels.closeLevels = make([]CandleCloseLevel, len(candles))
//
//	closeLevels.closeLevelCount = 0
//
//	for i in 0 ..< len(candles) - 1
//	{
//		candle : ^Candle = &candles[i]
//		nextCandle : ^Candle = &candles[i + 1]
//
//		closeLevel : ^CandleCloseLevel = &closeLevels.closeLevels[closeLevels.closeLevelCount]
//
//		// If red candle
//		if candle.close <= candle.open
//		{
//			// If next candle is green
//			if nextCandle.close > nextCandle.open
//			{
//				closeLevel.startTimestamp = nextCandle.timestamp + nextCandle.scale
//				closeLevel.endTimestamp = -1 // -1 meaning the level is still active
//				closeLevel.price = candle.close
//
//				// Find end point for level
//				for j in i + 2 ..< len(candles) - 1
//				{
//					candle2 : ^Candle = &candles[j]
//
//					if candle2.close < candle.close
//					{
//						closeLevel.endTimestamp = candle2.timestamp + candle2.scale
//						break
//					}
//				}
//
//				if closeLevel.startTimestamp != closeLevel.endTimestamp
//				{
//					closeLevels.closeLevelCount += 1
//				}
//			}
//		}
//		else // If green candle
//		{
//			// If next candle is red
//			if nextCandle.close < nextCandle.open
//			{
//				closeLevel.startTimestamp = nextCandle.timestamp + nextCandle.scale
//				closeLevel.endTimestamp = -1 // -1 meaning the level is still active
//				closeLevel.price = candle.close
//
//				// Find end point for level
//				for j in i + 2 ..< len(candles) - 1
//				{
//					candle2 : ^Candle = &candles[j]
//
//					if candle2.close > candle.close
//					{
//						closeLevel.endTimestamp = candle2.timestamp
//						break
//					}
//				}
//
//				if closeLevel.startTimestamp != closeLevel.endTimestamp
//				{
//					closeLevels.closeLevelCount += 1
//				}
//			}
//		}
//	}
//
//	return closeLevels
//}
//
//DestroyCloseLevels :: proc(candleCloseLevels : CandleCloseLevels)
//{
//	delete(candleCloseLevels.closeLevels)
//}
