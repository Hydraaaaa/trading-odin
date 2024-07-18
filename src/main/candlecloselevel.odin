package main

import "core:fmt"
import "vendor:raylib"

CandleCloseLevels :: struct
{
	levels : [dynamic]CandleCloseLevel,
	color : raylib.Color,
}

CandleCloseLevel :: struct
{
	startTimestamp : i32,
	endTimestamp : i32, // Value of -1 means that the level is still active
	price : f32,
}

CandleCloseLevels_Create :: proc(candleList : CandleList, color : raylib.Color) -> CandleCloseLevels
{
	candles := candleList.candles
	closeLevels : CandleCloseLevels

	closeLevels.color = color

	closeLevels.levels = make([dynamic]CandleCloseLevel, 0, len(candles) / 2)

	for startIndex in 0 ..< len(candles) - 1
	{
		startCandle : Candle = candles[startIndex]

		// If red candle
		if startCandle.close <= startCandle.open
		{
			// If next candle is green
			if candles[startIndex + 1].close > startCandle.close
			{
				closeLevel := CandleCloseLevel{startTimestamp = CandleList_IndexToTimestamp(candleList, i32(startIndex) + 2), endTimestamp = -1, price = startCandle.close}

				// Find end point for level
				for endIndex in startIndex + 2 ..< len(candles) - 1
				{
					if candles[endIndex].close < startCandle.close
					{
						closeLevel.endTimestamp = CandleList_IndexToTimestamp(candleList, i32(endIndex) + 1)
						break
					}
				}

				if closeLevel.startTimestamp != closeLevel.endTimestamp
				{
					append(&closeLevels.levels, closeLevel)
				}
			}
		}
		else // If green candle
		{
			// If next candle is red
			if candles[startIndex + 1].close < startCandle.close
			{
				closeLevel := CandleCloseLevel{startTimestamp = CandleList_IndexToTimestamp(candleList, i32(startIndex) + 2), endTimestamp = -1, price = startCandle.close}

				// Find end point for level
				for endIndex in startIndex + 2 ..< len(candles) - 1
				{
					if candles[endIndex].close > startCandle.close
					{
						closeLevel.endTimestamp = CandleList_IndexToTimestamp(candleList, i32(endIndex) + 1)
						break
					}
				}

				if closeLevel.startTimestamp != closeLevel.endTimestamp
				{
					append(&closeLevels.levels, closeLevel)
				}
			}
		}
	}

	return closeLevels
}

CandleCloseLevels_Destroy :: proc(candleCloseLevels : CandleCloseLevels)
{
	delete(candleCloseLevels.levels)
}
