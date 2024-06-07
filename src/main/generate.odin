package main

// This file exists as a means of recreating data from the trades stored on disk
// Useful in the event that the existing data is found to have issues
// Will eventually become obsolete as the data gets battle tested

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"

// This may take a minute or two
GenerateMinuteCandles :: proc()
{
    bytes, ok := os.read_entire_file_from_filename(TRADES_FILE)
    defer delete(bytes)

    trades := slice.reinterpret([]Trade, bytes[size_of(DayMonthYear):])

    candles : [dynamic]Candle
    reserve(&candles, 4_194_304)

    currentCandleTimestamp : i32 = BYBIT_ORIGIN_MINUTE_TIMESTAMP

	candle : Candle
	candle.open = trades[0].price
	candle.high = trades[0].price
	candle.low = trades[0].price
	candle.close = trades[0].price

	for trade, i in trades[1:]
	{
		// This is a for instead of an if to handle cases where the next trade is more than a minute after the last trade
		// Keep adding empty minutes until we're up to the minute of the trade
		for trade.timestamp >= currentCandleTimestamp + 60
		{
			currentCandleTimestamp += 60
			append(&candles, candle)

			candle.open = candle.close
			candle.high = candle.close
			candle.low = candle.close
			candle.volume = 0
		}

		candle.high = math.max(candle.high, trade.price)
		candle.low = math.min(candle.low, trade.price)

		candle.close = trade.price

		candle.volume += trade.volume
	}

    append(&candles, candle)

	os.write_entire_file(MINUTE_CANDLES_FILE, slice.to_bytes(candles[:]))
}

GenerateMinuteDelta :: proc()
{
    bytes, ok := os.read_entire_file_from_filename(TRADES_FILE)
    defer delete(bytes)

    trades := slice.reinterpret([]Trade, bytes[size_of(DayMonthYear):])

    deltas : [dynamic]f64
    reserve(&deltas, 4_194_304)

    currentCandleTimestamp : i32 = BYBIT_ORIGIN_MINUTE_TIMESTAMP

	delta : f64 = 0

	for trade, i in trades[1:]
	{
		// This is a for instead of an if to handle cases where the next trade is more than a minute after the last trade
		// Keep adding empty minutes until we're up to the minute of the trade
		for trade.timestamp >= currentCandleTimestamp + 60
		{
			currentCandleTimestamp += 60
			append(&deltas, delta)
		}

		delta += f64(trade.volume) * f64(int(trade.isBuy)) - f64(trade.volume) * f64(int(!trade.isBuy))
	}

    append(&deltas, delta)

	os.write_entire_file(MINUTE_DELTA_FILE, slice.to_bytes(deltas[:]))
}

GenerateHourVolumeProfiles :: proc(hourlyCandles : CandleList)
{
	headerFile, err := os.open(HOUR_VOLUME_PROFILE_HEADER_FILE, os.O_CREATE); assert(err == 0, "os.open error")
	defer os.close(headerFile)

	bucketFile : os.Handle
	bucketFile, err = os.open(HOUR_VOLUME_PROFILE_BUCKET_FILE, os.O_CREATE); assert(err == 0, "os.open error")
	defer os.close(bucketFile)

	trades : [dynamic]Trade
	reserve(&trades, 262_144)

	poolIndex : i32 = 0

	_, err = os.write(headerFile, mem.any_to_bytes(i32(len(hourlyCandles.candles)))); assert(err == 0, "os.write error")

	for i in 0 ..< len(hourlyCandles.candles)
	{
		candle := hourlyCandles.candles[i]
		timestamp := CandleList_IndexToTimestamp(hourlyCandles, i32(i))
		LoadTradesBetween(timestamp, timestamp + 3600, &trades)

		profile := VolumeProfile_CreateFromTrades(trades[:], candle.high, candle.low, 5)
		defer VolumeProfile_Destroy(profile)

		relativeIndexOffset := i32(i32(candle.low) - i32(candle.low) % HOUR_BUCKET_SIZE) / HOUR_BUCKET_SIZE
		header : VolumeProfileHeader = {poolIndex, i32(len(profile.buckets)), relativeIndexOffset}
		os.write(headerFile, mem.any_to_bytes(header))
		os.write(bucketFile, slice.reinterpret([]u8, profile.buckets[:]))

		poolIndex += header.bucketCount

		clear(&trades)
	}
}