package main

import "core:fmt"
import "core:math"

Candle :: struct
{
	open : f32,
	high : f32,
	low : f32,
	close : f32,
	volume : f32,
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

Candle_HighestClose :: proc(candles : []Candle) -> (Candle, i32)
{
	if len(candles) == 0
	{
		return {}, 0
	}

	highestCandle := candles[0]
	highestCandleIndex : i32 = 0

	for candle, i in candles[1:]
	{
		if candle.close > highestCandle.close
		{
			highestCandle = candle
			highestCandleIndex = i32(i) + 1
		}
	}

	return highestCandle, highestCandleIndex
}

Candle_LowestClose :: proc(candles : []Candle) -> (Candle, i32)
{
	if len(candles) == 0
	{
		return {}, 0
	}

	lowestCandle := candles[0]
	lowestCandleIndex : i32 = 0

	for candle, i in candles[1:]
	{
		if candle.close < lowestCandle.close
		{
			lowestCandle = candle
			lowestCandleIndex = i32(i) + 1
		}
	}

	return lowestCandle, lowestCandleIndex
}

Candle_FloorTimestamp :: proc(timestamp : i32, timeframe : Timeframe) -> i32
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	if timeframe == .MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS

		remainingTimestamp := timestamp % monthlyIncrements[47]

		remainingIndex := 47

		for remainingTimestamp < monthlyIncrements[remainingIndex]
		{
			remainingIndex -= 1
		}

		return timestamp - remainingTimestamp + monthlyIncrements[remainingIndex]
	}

	// Timestamp 0 (1/1/2010) is a Friday, offset the timestamps to produce increments on Mondays
	if timeframe == .WEEK
	{
		return timestamp - (timestamp + DAY * 4) % timeframeIncrements[timeframe]
	}

	// Everything below months is uniform, and can be mathed
	return timestamp - timestamp % timeframeIncrements[timeframe]
}

Candle_Merge :: proc(candles : ..Candle) -> Candle
{
	newCandle := candles[0]

	for candle in candles[1:]
	{
		newCandle.high = math.max(newCandle.high, candle.high)
		newCandle.low = math.min(newCandle.low, candle.low)
	}

	newCandle.close = candles[len(candles) - 1].close

	return newCandle
}