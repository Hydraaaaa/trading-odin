package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:strconv"
import "vendor:raylib"

// 00:00:00
// 1 August 2017
BINANCE_ORIGIN_TIMESTAMP :: 1_501_545_600

Candle :: struct
{
	timestamp : i32,
	scale : i32, // Determines the width of the candle, necessary because months don't have a fixed size
	open : f32,
	high : f32,
	low : f32,
	close : f32,
}

// TODO: Pending Deletion
LoadCandles :: proc(fileName : string) -> []Candle
{
	data, ok := os.read_entire_file(fileName, context.allocator)

	if !ok
	{
		// could not read file
		fmt.println("Opening file failed!")
		return nil
	}

	defer delete(data, context.allocator)

	text := string(data)

	candleIndex := 0

	lines := strings.split_lines(text)

	candles := make([]Candle, len(lines) - 1)

	for i in 0 ..< len(candles)
	{
		sectionIndex := 0

		candle := &candles[candleIndex]

		for section in strings.split_iterator(&lines[i], ",")
		{
			switch sectionIndex 
			{
				case 0:
				timestamp, ok := strconv.parse_u64(section)

				if !ok
				{
					fmt.println("NOT OK")
				}

				candle.timestamp = i32(timestamp / 1000 - BINANCE_ORIGIN_TIMESTAMP)

				case 1: candle.open = f32(strconv.atof(section))
				case 2: candle.high = f32(strconv.atof(section))
				case 3: candle.low = f32(strconv.atof(section))
				case 4: candle.close = f32(strconv.atof(section))
				case 6:
				timestamp, ok := strconv.parse_u64(section)

				timestamp = (timestamp + 1) / 1000

				if !ok
				{
					fmt.println("NOT OK")
				}

				candle.scale = i32(timestamp - BINANCE_ORIGIN_TIMESTAMP) - candle.timestamp
			}

			sectionIndex += 1
		}

		candleIndex += 1
	}

	return candles
}

UnloadCandles :: proc(candles : []Candle)
{
	delete(candles)
}

// timestampOffset refers to the time between 2010 and the timestamp of the first candle
Candle_TimestampToIndex :: proc(timestamp : i32, candles : []Candle, timeframe : CandleTimeframe, timestampOffset : i32) -> i32
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	lastCandleIndex := i32(len(candles)) - 1

	if timeframe == CandleTimeframe.MONTH
	{
		// TODO: Fresh mind, is there a problem with the simple approach of subtracting indices?
		monthlyIncrements := MONTHLY_INCREMENTS
		
		offsetIndex := timestampOffset / monthlyIncrements[47] * 48
		remainingOffsetTimestamp := timestampOffset % monthlyIncrements[47]
		
		remainingOffsetIndex : i32 = 0

		for remainingOffsetTimestamp > monthlyIncrements[remainingOffsetIndex]
		{
			remainingOffsetIndex += 1
		}

		index := timestamp / monthlyIncrements[47] * 48 - offsetIndex
		remainingTimestamp := timestamp % monthlyIncrements[47]

		remainingIndex : i32 = 0
		
		for remainingTimestamp > monthlyIncrements[remainingIndex]
		{
			remainingIndex += 1
		}
		
		index += remainingIndex - remainingOffsetIndex

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
	
	// Everything below months is uniform, and can be mathed
	increment := timeframeIncrements[int(timeframe)]

	index := (timestamp - timestampOffset) / increment
	
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
	if timeframe == CandleTimeframe.MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS
		
		fourYearSpans := index / 48
		remainder := index % 48
		
		return monthlyIncrements[47] * fourYearSpans + monthlyIncrements[remainder] + timestampOffset
	}

	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS
	
	return timeframeIncrements[timeframe] * index + timestampOffset
}

Candle_IndexToPixelX :: proc(index : i32, timeframe : CandleTimeframe, timestampOffset : i32, scaleData : ScaleData) -> i32
{
	return Timestamp_ToPixelX(Candle_IndexToTimestamp(index, timeframe, timestampOffset), scaleData)
}

Candle_IndexToDuration :: proc(index : i32, timeframe : CandleTimeframe) -> i32
{
	if timeframe != CandleTimeframe.MONTH
	{
		timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS
		
		return timeframeIncrements[timeframe]
	}

	monthlyIncrements := MONTHLY_INCREMENTS
	
	normalisedIndex := index % 48
	
	if normalisedIndex != 0
	{
		return monthlyIncrements[normalisedIndex] - monthlyIncrements[normalisedIndex - 1]
	}
	
	return monthlyIncrements[normalisedIndex]
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

	if timeframe == CandleTimeframe.MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS
		
		remainingTimestamp := timestamp % monthlyIncrements[47]

		remainingIndex := 0
		
		for remainingTimestamp > monthlyIncrements[remainingIndex]
		{
			remainingIndex += 1
		}

		return timestamp - remainingTimestamp + monthlyIncrements[remainingIndex]
	}
	
	// Everything below months is uniform, and can be mathed
	return timestamp - timestamp % timeframeIncrements[timeframe]
}