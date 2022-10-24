package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:strconv"
import "vendor:raylib"

ORIGIN_TIMESTAMP : u64 : 1_501_545_600

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

CandleData :: struct
{
	candles : []Candle,
	candleCount : int,
	closeLevels : []CandleCloseLevel,
	closeLevelCount : int,

	closeLevelColor : raylib.Color,
}


LoadCandleData :: proc(candleData : ^CandleData, fileName : string)
{
	data, ok := os.read_entire_file(fileName, context.allocator)

	if !ok
	{
		// could not read file
		fmt.println("Opening file failed!")
		return
	}

	defer delete(data, context.allocator)

	text := string(data)

	candleIndex := 0

	lines := strings.split_lines(text)

	candleData.candleCount = len(lines) - 1
	candleData.candles = make([]Candle, candleData.candleCount)

	for i := 0; i < candleData.candleCount; i += 1
	{
		sectionIndex := 0

		candle := &candleData.candles[candleIndex]

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

				candle.timestamp = i32(timestamp / 1000 - ORIGIN_TIMESTAMP)
				case 1:
				candle.open = f32(strconv.atof(section))
				case 2:
				candle.high = f32(strconv.atof(section))
				case 3:
				candle.low = f32(strconv.atof(section))
				case 4:
				candle.close = f32(strconv.atof(section))

				case 6:
				timestamp, ok := strconv.parse_u64(section)

				timestamp = (timestamp + 1) / 1000

				if !ok
				{
					fmt.println("NOT OK")
				}

				candle.scale = i32(timestamp - ORIGIN_TIMESTAMP) - candle.timestamp
			}

			sectionIndex += 1
		}

		candleIndex += 1
	}
}

CreateCloseLevels :: proc(candleData : ^CandleData, color : raylib.Color)
{
	candleData.closeLevelColor = color

	candleData.closeLevels = make([]CandleCloseLevel, candleData.candleCount)

	candleData.closeLevelCount = 0

	for i := 0; i < candleData.candleCount - 1; i += 1
	{
		candle : ^Candle = &candleData.candles[i]
		nextCandle : ^Candle = &candleData.candles[i + 1]

		closeLevel : ^CandleCloseLevel = &candleData.closeLevels[candleData.closeLevelCount]

		// If red candle
		if candle.close <= candle.open
		{
			if nextCandle.close > nextCandle.open
			{
				closeLevel.startTimestamp = nextCandle.timestamp + nextCandle.scale
				closeLevel.endTimestamp = -1 // -1 meaning the level is still active
				closeLevel.price = candle.close

				// Find end point for level
				for j := i + 2; j < candleData.candleCount - 1; j += 1
				{
					candle2 : ^Candle = &candleData.candles[j]

					if candle2.close < candle.close
					{
						closeLevel.endTimestamp = candle2.timestamp + candle2.scale
						break
					}
				}

				if closeLevel.startTimestamp != closeLevel.endTimestamp
				{
					candleData.closeLevelCount += 1
				}
			}
		}
		else
		{
			// If green candle
			if nextCandle.close < nextCandle.open
			{
				closeLevel.startTimestamp = nextCandle.timestamp + nextCandle.scale
				closeLevel.endTimestamp = -1 // -1 meaning the level is still active
				closeLevel.price = candle.close

				// Find end point for level
				for j := i + 2; j < candleData.candleCount - 1; j += 1
				{
					candle2 : ^Candle = &candleData.candles[j]

					if candle2.close > candle.close
					{
						closeLevel.endTimestamp = candle2.timestamp
						break
					}
				}

				if closeLevel.startTimestamp != closeLevel.endTimestamp
				{
					candleData.closeLevelCount += 1
				}
			}
		}
	}
}

DestroyCloseLevels :: proc(candleData : ^CandleData)
{
	delete(candleData.closeLevels)
}

UnloadCandleData :: proc(candleData : ^CandleData)
{
	delete(candleData.candles)
}
