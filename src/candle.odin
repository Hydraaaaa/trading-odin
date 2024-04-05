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

CreateCloseLevels :: proc(candles : []Candle, color : raylib.Color) -> CandleCloseLevels
{
	closeLevels : CandleCloseLevels
	
	closeLevels.color = color

	// Could this upper limit be reduced?
	closeLevels.closeLevels = make([]CandleCloseLevel, len(candles))

	closeLevels.closeLevelCount = 0

	for i in 0 ..< len(candles) - 1
	{
		candle : ^Candle = &candles[i]
		nextCandle : ^Candle = &candles[i + 1]

		closeLevel : ^CandleCloseLevel = &closeLevels.closeLevels[closeLevels.closeLevelCount]

		// If red candle
		if candle.close <= candle.open
		{
			// If next candle is green
			if nextCandle.close > nextCandle.open
			{
				closeLevel.startTimestamp = nextCandle.timestamp + nextCandle.scale
				closeLevel.endTimestamp = -1 // -1 meaning the level is still active
				closeLevel.price = candle.close

				// Find end point for level
				for j in i + 2 ..< len(candles) - 1
				{
					candle2 : ^Candle = &candles[j]

					if candle2.close < candle.close
					{
						closeLevel.endTimestamp = candle2.timestamp + candle2.scale
						break
					}
				}

				if closeLevel.startTimestamp != closeLevel.endTimestamp
				{
					closeLevels.closeLevelCount += 1
				}
			}
		}
		else // If green candle
		{
			// If next candle is red
			if nextCandle.close < nextCandle.open
			{
				closeLevel.startTimestamp = nextCandle.timestamp + nextCandle.scale
				closeLevel.endTimestamp = -1 // -1 meaning the level is still active
				closeLevel.price = candle.close

				// Find end point for level
				for j in i + 2 ..< len(candles) - 1
				{
					candle2 : ^Candle = &candles[j]

					if candle2.close > candle.close
					{
						closeLevel.endTimestamp = candle2.timestamp
						break
					}
				}

				if closeLevel.startTimestamp != closeLevel.endTimestamp
				{
					closeLevels.closeLevelCount += 1
				}
			}
		}
	}

	return closeLevels
}

DestroyCloseLevels :: proc(candleCloseLevels : CandleCloseLevels)
{
	delete(candleCloseLevels.closeLevels)
}

UnloadCandles :: proc(candles : []Candle)
{
	delete(candles)
}
