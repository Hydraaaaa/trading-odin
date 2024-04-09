package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:strconv"
import "vendor:raylib"

Candle :: struct
{
	open : f32,
	high : f32,
	low : f32,
	close : f32,
	volume : f32,
}

CandleTimeframe :: enum
{
	MINUTE,
	MINUTE_5,
	MINUTE_15,
	MINUTE_30,
	HOUR,
	HOUR_3,
	HOUR_6,
	HOUR_12,
	DAY,
	//WEEK,
	//MONTH,
	//QTR,
	//YEAR,
}

CandleTimeframeData :: struct
{
	candles : [dynamic]Candle,
	offset : i32,
}

// timestampOffset refers to the time between 2010 and the timestamp of the first candle
Candle_TimestampToIndex :: proc(timestamp : i32, candleData : CandleTimeframeData, timeframe : CandleTimeframe) -> i32
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	lastCandleIndex := i32(len(candleData.candles)) - 1

	//if timeframe == CandleTimeframe.MONTH
	//{
	//	// TODO: Fresh mind, is there a problem with the simple approach of subtracting indices?
	//	monthlyIncrements := MONTHLY_INCREMENTS
	//	
	//	offsetIndex := candleData.offset / monthlyIncrements[47] * 48
	//	remainingOffsetTimestamp := candleData.offset % monthlyIncrements[47]
	//	
	//	remainingOffsetIndex : i32 = 0

	//	for remainingOffsetTimestamp > monthlyIncrements[remainingOffsetIndex]
	//	{
	//		remainingOffsetIndex += 1
	//	}

	//	index := timestamp / monthlyIncrements[47] * 48 - offsetIndex
	//	remainingTimestamp := timestamp % monthlyIncrements[47]

	//	remainingIndex : i32 = 0
	//	
	//	for remainingTimestamp > monthlyIncrements[remainingIndex]
	//	{
	//		remainingIndex += 1
	//	}
	//	
	//	index += remainingIndex - remainingOffsetIndex

	//	if index < 0
	//	{
	//		index = 0
	//	}
	//	else if index > lastCandleIndex
	//	{
	//		index = lastCandleIndex		
	//	}
	//	
	//	return index
	//}
	
	// Everything below months is uniform, and can be mathed
	increment := timeframeIncrements[int(timeframe)]

	index := (timestamp - candleData.offset) / increment
	
	if index < 0
	{
		index = 0
	}
	else if index > lastCandleIndex
	{
		index = lastCandleIndex
	}

	return index
}

// timestampOffset refers to the time between 2010 and the timestamp of the first candle
Candle_IndexToTimestamp :: proc(index : i32, timeframe : CandleTimeframe, timestampOffset : i32) -> i32
{
	//if timeframe == CandleTimeframe.MONTH
	//{
	//	monthlyIncrements := MONTHLY_INCREMENTS
	//	
	//	fourYearSpans := index / 48
	//	remainder := index % 48
	//	
	//	return monthlyIncrements[47] * fourYearSpans + monthlyIncrements[remainder] + timestampOffset
	//}

	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS
	
	return timeframeIncrements[timeframe] * index + timestampOffset
}

Candle_IndexToPixelX :: proc(index : i32, timeframe : CandleTimeframe, timestampOffset : i32, scaleData : ScaleData) -> i32
{
	return Timestamp_ToPixelX(Candle_IndexToTimestamp(index, timeframe, timestampOffset), scaleData)
}

Candle_IndexToDuration :: proc(index : i32, timeframe : CandleTimeframe) -> i32
{
	//if timeframe == CandleTimeframe.MONTH
	//{
	//	monthlyIncrements := MONTHLY_INCREMENTS
	//	
	//	normalisedIndex := index % 48
	//	
	//	if normalisedIndex != 0
	//	{
	//		return monthlyIncrements[normalisedIndex] - monthlyIncrements[normalisedIndex - 1]
	//	}
	//	
	//	return monthlyIncrements[normalisedIndex]
	//}

	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS
	
	return timeframeIncrements[timeframe]
}

Candle_HighestHigh :: proc(candles : []Candle) -> (Candle, i32)
{
	if len(candles) == 0
	{
		return {}, 0
	}

	highestCandle := candles[0]
	highestCandleIndex : i32 = 0

	for candle, i in candles[1:]
	{
		if candle.high > highestCandle.high
		{
			highestCandle = candle
			highestCandleIndex = i32(i) + 1
		}
	}

	return highestCandle, highestCandleIndex
}

Candle_LowestLow :: proc(candles : []Candle) -> (Candle, i32)
{
	if len(candles) == 0
	{
		return {}, 0
	}

	lowestCandle := candles[0]
	lowestCandleIndex : i32 = 0

	for candle, i in candles[1:]
	{
		if candle.low < lowestCandle.low
		{
			lowestCandle = candle
			lowestCandleIndex = i32(i) + 1
		}
	}

	return lowestCandle, lowestCandleIndex
}

Candle_FloorTimestamp :: proc(timestamp : i32, timeframe : CandleTimeframe) -> i32
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	//if timeframe == CandleTimeframe.MONTH
	//{
	//	monthlyIncrements := MONTHLY_INCREMENTS
	//	
	//	remainingTimestamp := timestamp % monthlyIncrements[47]

	//	remainingIndex := 0
	//	
	//	for remainingTimestamp > monthlyIncrements[remainingIndex]
	//	{
	//		remainingIndex += 1
	//	}

	//	return timestamp - remainingTimestamp + monthlyIncrements[remainingIndex]
	//}
	
	// Everything below months is uniform, and can be mathed
	return timestamp - timestamp % timeframeIncrements[timeframe]
}