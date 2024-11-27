package main

import "core:fmt"
import "core:math"

HighLow :: struct
{
	timestamp : i32,
	price : f32,
}

HighLow_Generate :: proc(candleList : CandleList, percentThreshold : f32 = 0.02) -> ([dynamic]HighLow, bool)
{
	highlows := make([dynamic]HighLow, 0, 1024)

	candles := candleList.candles

	tentativeHighLow := HighLow{candleList.offset, candles[0].low}
	tentativeIsHigh := false
	threshold := tentativeHighLow.price * percentThreshold

	for candle, candleIndex in candles
	{
		if tentativeIsHigh
		{
			if tentativeHighLow.price - candle.low > threshold
			{
				append(&highlows, tentativeHighLow)
				tentativeHighLow.timestamp = CandleList_IndexToTimestamp(candleList, i32(candleIndex))
				tentativeHighLow.price = candle.low
				tentativeIsHigh = !tentativeIsHigh
				threshold = tentativeHighLow.price * percentThreshold
			}
			else if candle.high > tentativeHighLow.price
			{
				tentativeHighLow.timestamp = CandleList_IndexToTimestamp(candleList, i32(candleIndex))
				tentativeHighLow.price = candle.high
			}
		}
		else 
		{
			if !tentativeIsHigh &&
		        candle.high - tentativeHighLow.price > threshold
		    {
		    	append(&highlows, tentativeHighLow)
				tentativeHighLow.timestamp = CandleList_IndexToTimestamp(candleList, i32(candleIndex))
				tentativeHighLow.price = candle.high
				tentativeIsHigh = !tentativeIsHigh
				threshold = tentativeHighLow.price * percentThreshold
			}
			else if candle.low < tentativeHighLow.price
			{
				tentativeHighLow.timestamp = CandleList_IndexToTimestamp(candleList, i32(candleIndex))
				tentativeHighLow.price = candle.low
			}
		}
	}

	append(&highlows, tentativeHighLow)

	return highlows, false
}
