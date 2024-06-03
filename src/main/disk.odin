package main

import "core:fmt"
import "core:slice"
import "core:os"
import "core:mem"
import "core:math"

TRADES_FILE :: "data/trades.bin"
MINUTE_CANDLES_FILE :: "data/minutecandles.bin"
HOUR_VOLUME_PROFILE_HEADER_FILE :: "data/hourvolumeprofileheaders.bin"
HOUR_VOLUME_PROFILE_BUCKET_FILE :: "data/hourvolumeprofilebuckets.bin"
HOUR_BUCKET_SIZE :: 5

LoadDateToDownload :: proc() -> DayMonthYear
{
	tradesFile : os.Handle
	err : os.Errno

	if !os.is_file(TRADES_FILE)
	{
		tradesFile, err = os.open(TRADES_FILE, os.O_CREATE); assert(err == 0, "os.open error")
		defer os.close(tradesFile)

		_, err = os.write(tradesFile, mem.any_to_bytes(BYBIT_ORIGIN_DATE)); assert(err == 0, "os.write error")

		return BYBIT_ORIGIN_DATE
	}
	else
	{
		tradesFile, err = os.open(TRADES_FILE, os.O_RDWR); assert(err == 0, "os.open error")
		defer os.close(tradesFile)

		dateBytes : [size_of(DayMonthYear)]byte
		_, err = os.read(tradesFile, dateBytes[:]); assert(err == 0, "os.read error")

		return transmute(DayMonthYear)dateBytes
	}
}

// Allocates candles
LoadMinuteCandles :: proc() -> [dynamic]Candle
{
	if !os.is_file(MINUTE_CANDLES_FILE)
	{
		candlesFile, err := os.open(MINUTE_CANDLES_FILE, os.O_CREATE); assert(err == 0, "os.open error")
		os.close(candlesFile)

		return make([dynamic]Candle, 0, 1440)
	}
	else
	{
		bytes, success := os.read_entire_file_from_filename(MINUTE_CANDLES_FILE); assert(success, "os.read_entire_file_from_filename error")

		fileCandles := slice.reinterpret([]Candle, bytes)

		candles := make([dynamic]Candle, 0, len(fileCandles) + 1440)

		for candle in fileCandles
		{
			append(&candles, candle)
		}

		return candles
	}
}

// Appends new day's trades both in memory, and on disk
// Deletes trades upon completion
// Increments date
AppendDay :: proc(trades : ^[]Trade, chart : ^Chart)
{
	// Append to trades file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	firstTrade : Trade
	previousDayLastTrade : Trade

	tradesFile, err := os.open(TRADES_FILE, os.O_RDWR); assert(err == 0, "os.open error");

	tradeBuffer : [size_of(Trade)]u8
	_, err = os.read_at(tradesFile, tradeBuffer[:], size_of(DayMonthYear)); assert(err == 0, "os.read_at error")

	firstTrade = (^Trade)(&tradeBuffer[0])^

	_, err = os.seek(tradesFile, -size_of(Trade), os.SEEK_END); assert(err == 0, "os.seek error")
	_, err = os.read(tradesFile, tradeBuffer[:]); assert(err == 0, "os.read error")

	previousDayLastTrade = (^Trade)(&tradeBuffer[0])^

	if chart.dateToDownload == BYBIT_ORIGIN_DATE
	{
		firstTrade = trades[0]
	}

	fmt.println("Appending", len(trades), "trades")

	_, err = os.write(tradesFile, slice.to_bytes(trades[:])); assert(err == 0, "os.write error")

	// File stores the next date to be downloaded in future
	nextDate := DayMonthYear_AddDays(chart.dateToDownload, 1)

	_, err = os.write_at(tradesFile, mem.any_to_bytes(nextDate), 0); assert(err == 0, "write_at error")

	os.close(tradesFile)

	// Convert trades to minute candles ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	currentCandleTimestamp : i32 = ---

	// Values for use in the hourly profiles section
	hourEndIndices : [24]int
	hourHighs : [24]f32
	hourLows : [24]f32
	startHour : int = ---

	if chart.dateToDownload == BYBIT_ORIGIN_DATE
	{
		// On the first day, the first trade happens later than 00:00:00 UTC, and so the first candle does as well
		currentCandleTimestamp = BYBIT_ORIGIN_MINUTE_TIMESTAMP
		startHour = BYBIT_ORIGIN_HOUR_OF_DAY

		// In the event of this being the first day of data, there is no previous day last trade, so use the first trade instead
		previousDayLastTrade = trades[0]
	}
	else
	{
		currentCandleTimestamp = DayMonthYear_ToTimestamp(chart.dateToDownload)
		startHour = 0
	}

	candle : Candle

	nextDayTimestamp := DayMonthYear_ToTimestamp(nextDate)

	// First candle will open at the close of the previous candle
	candle.open = previousDayLastTrade.price
	candle.high = previousDayLastTrade.price
	candle.low = previousDayLastTrade.price
	candle.close = previousDayLastTrade.price

	candlesAdded := 0

	hourLows[startHour] = trades[0].price
	hourHighs[startHour] = trades[0].price

	currentHour := startHour

	candlesToAdd := int(nextDayTimestamp - currentCandleTimestamp) / 60
	candleStartIndex := len(chart.candles[Timeframe.MINUTE].candles)

	non_zero_resize(&chart.candles[Timeframe.MINUTE].candles, len(chart.candles[Timeframe.MINUTE].candles) + candlesToAdd)

	for trade, i in trades
	{
		// This is a for instead of an if to handle cases where the next trade is more than a minute after the last trade
		// Keep adding empty minutes until we're up to the minute of the trade
		for trade.timestamp >= currentCandleTimestamp + 60
		{
			currentCandleTimestamp += 60
			chart.candles[Timeframe.MINUTE].candles[candleStartIndex + candlesAdded] = candle
			candlesAdded += 1

			for candlesAdded / 60 + startHour > currentHour
			{
				hourEndIndices[currentHour] = i-1
				currentHour += 1
				hourHighs[currentHour] = candle.close
				hourLows[currentHour] = candle.close
			}

			candle.open = candle.close
			candle.high = candle.close
			candle.low = candle.close
			candle.volume = 0
		}

		candle.high = math.max(candle.high, trade.price)
		candle.low = math.min(candle.low, trade.price)

		hourHighs[currentHour] = math.max(candle.high, hourHighs[currentHour])
		hourLows[currentHour] = math.min(candle.low, hourLows[currentHour])

		candle.close = trade.price

		candle.volume += trade.volume
	}

	// Close final candle
	// This for is to handle the case where no new trades have been made during the final minute(s) of the day
	// Will create empty candles up until the new day
	for currentCandleTimestamp < nextDayTimestamp
	{
		currentCandleTimestamp += 60
		chart.candles[Timeframe.MINUTE].candles[candleStartIndex + candlesAdded] = candle
		candlesAdded += 1

		for candlesAdded / 60 + startHour > currentHour
		{
			hourEndIndices[currentHour] = len(trades) - 1
			currentHour += 1
		}

		candle.open = candle.close
		candle.high = candle.close
		candle.low = candle.close
		candle.volume = 0
	}

	// Close final hour profile
	if currentHour < 24
	{
		hourEndIndices[currentHour] = len(trades) - 1
	}

	// Append to minute candles file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	if candlesAdded != candlesToAdd
	{
		// This isn't necessarily a problem for the first day of data, given that trades didn't begin at 00:00:00 on that day
		fmt.println("PROBLEM!!! Added", candlesAdded, "candles to file, should be 1440 - candlesToAdd:", candlesToAdd)
	}

	candlesFile : os.Handle
	candlesFile, err = os.open(MINUTE_CANDLES_FILE, os.O_RDWR); assert(err == 0, "os.open error")

	_, err = os.seek(candlesFile, 0, os.SEEK_END); assert(err == 0, "os.seek error")
	_, err = os.write(candlesFile, slice.to_bytes(chart.candles[Timeframe.MINUTE].candles[candleStartIndex:])); assert(err == 0, "os.write error")

	os.close(candlesFile)

	// Append to hour volume profiles file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	profileHeaderFile : os.Handle
	profileBucketFile : os.Handle
	profileCount : i32

	if os.exists(HOUR_VOLUME_PROFILE_HEADER_FILE)
	{
		profileHeaderFile, err = os.open(HOUR_VOLUME_PROFILE_HEADER_FILE, os.O_RDWR); assert(err == 0, "os.open error")
		profileBucketFile, err = os.open(HOUR_VOLUME_PROFILE_BUCKET_FILE, os.O_RDWR); assert(err == 0, "os.open error")

		profileCountBytes : [size_of(i32)]byte
		_, err = os.read(profileHeaderFile, profileCountBytes[:]); assert(err == 0, "os.read error")
		profileCount = transmute(i32)profileCountBytes

		os.seek(profileBucketFile, 0, os.SEEK_END)
	}
	else
	{
		profileHeaderFile, err = os.open(HOUR_VOLUME_PROFILE_HEADER_FILE, os.O_CREATE); assert(err == 0, "os.open error")
		profileBucketFile, err = os.open(HOUR_VOLUME_PROFILE_BUCKET_FILE, os.O_CREATE); assert(err == 0, "os.open error")

		profileCount = 0
	}

	defer os.close(profileHeaderFile)
	defer os.close(profileBucketFile)

	poolIndex : i32 = i32(len(chart.hourVolumeProfilePool.buckets))

	os.write_at(profileHeaderFile, mem.any_to_bytes(profileCount + i32(24 - startHour)), 0); assert(err == 0, "os.write_at error")
	os.seek(profileHeaderFile, 0, os.SEEK_END)

	profileStartIndex := 0

	for i in startHour ..< 24
	{
		profile := VolumeProfile_CreateFromTrades(trades[profileStartIndex:hourEndIndices[i]], hourHighs[i], hourLows[i], 5)
		defer VolumeProfile_Destroy(profile)

		bucketOffset := i32(i32(hourLows[i]) - i32(hourLows[i]) % HOUR_BUCKET_SIZE) / HOUR_BUCKET_SIZE

		header : VolumeProfileHeader = {poolIndex, i32(len(profile.buckets)), bucketOffset}
		append(&chart.hourVolumeProfilePool.headers, header)

		existingLen := len(chart.hourVolumeProfilePool.buckets)
		addedLen := len(profile.buckets)

		non_zero_resize(&chart.hourVolumeProfilePool.buckets, existingLen + addedLen)

		for i in 0 ..< addedLen
		{
			chart.hourVolumeProfilePool.buckets[existingLen + i] = profile.buckets[i]
		}

		os.write(profileHeaderFile, mem.any_to_bytes(header))
		os.write(profileBucketFile, slice.reinterpret([]u8, profile.buckets[:]))

		profileStartIndex = hourEndIndices[i]
		poolIndex += header.bucketCount
	}

	// Create higher timeframe candles <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	prevTimeframe := Timeframe.MINUTE

	candleTimeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	prevTimeframeCandles := chart.candles[Timeframe.MINUTE].candles[candleStartIndex:]

	for timeframe in Timeframe.MINUTE_5 ..= Timeframe.DAY
	{
		prevTimeframeCandlesLen := len(prevTimeframeCandles)

		startingCandlesLen := len(chart.candles[timeframe].candles)

		timeframeDivisor := int(candleTimeframeIncrements[timeframe] / candleTimeframeIncrements[prevTimeframe])

		start := 0
		end : int = ---

		if chart.dateToDownload == BYBIT_ORIGIN_DATE
		{
			// Separately calculate the subcandles of the first candle to handle the case where the candle timestamps aren't aligned
			firstCandleComponentCount := timeframeDivisor - int((chart.candles[prevTimeframe].offset - chart.candles[timeframe].offset) / candleTimeframeIncrements[prevTimeframe])

			end = firstCandleComponentCount

			if end == 0
			{
				end += timeframeDivisor
			}
		}
		else
		{
			end = timeframeDivisor
		}


		for end <= prevTimeframeCandlesLen
		{
			append(&chart.candles[timeframe].candles, Candle_Merge(..prevTimeframeCandles[start:end]))

			start = end
			end += timeframeDivisor
		}

		prevTimeframe = timeframe
		prevTimeframeCandles = chart.candles[timeframe].candles[startingCandlesLen:]
	}

	newDayCandle := slice.last(chart.candles[Timeframe.DAY].candles[:])

	if Timestamp_ToDayOfWeek(DayMonthYear_ToTimestamp(chart.dateToDownload)) == .MONDAY ||
	   len(chart.candles[Timeframe.WEEK].candles) == 0
	{
		append(&chart.candles[Timeframe.WEEK].candles, newDayCandle)
		append(&chart.weeklyVolumeProfiles, VolumeProfile{})
	}
	else
	{
		weekCandleIndex := len(chart.candles[Timeframe.WEEK].candles) - 1
		chart.candles[Timeframe.WEEK].candles[weekCandleIndex] = Candle_Merge(chart.candles[Timeframe.WEEK].candles[weekCandleIndex], newDayCandle)
	}

	if chart.dateToDownload.day == 1 ||
	   len(chart.candles[Timeframe.MONTH].candles) == 0
	{
		append(&chart.candles[Timeframe.MONTH].candles, newDayCandle)
	}
	else
	{
		monthCandleIndex := len(chart.candles[Timeframe.MONTH].candles) - 1
		chart.candles[Timeframe.MONTH].candles[monthCandleIndex] = Candle_Merge(chart.candles[Timeframe.MONTH].candles[monthCandleIndex], newDayCandle)
	}

	delete(trades^)
	chart.dateToDownload = nextDate
	append(&chart.dailyVolumeProfiles, VolumeProfile{})
}

LoadTradesBetween :: proc(start : i32, end : i32, buffer : ^[dynamic]Trade)
{
	file, err := os.open(TRADES_FILE, os.O_RDWR); assert(err == 0, "os.open error")
	defer os.close(file)

	fileSize : i64
	fileSize, err = os.file_size(file); assert(err == 0, "os.file_size error")

	DATE_SIZE :: size_of(DayMonthYear)

	min : i32 = 0
	max : i32 = i32((fileSize - DATE_SIZE) / size_of(Trade))

	start := start
	end := end

	startIndex : i32 = ---
	endIndex : i32 = ---

	timestampBytes : [size_of(i32)]u8 = ---
	_, err = os.read_at(file, timestampBytes[:], fileSize - size_of(Trade)); assert(err == 0, "os.read_at error")
	lastTimestamp := transmute(i32)timestampBytes

	if end > lastTimestamp
	{
		end = lastTimestamp
		endIndex = max
	}
	else
	{
		// Binary search for end
		for
		{
			mid := (max - min) / 2 + min

			_, err = os.read_at(file, timestampBytes[:], i64(mid) * size_of(Trade) + DATE_SIZE); assert(err == 0, "os.read_at error")

			midTimestamp := transmute(i32)timestampBytes

			if midTimestamp < end
			{
				min = mid + 1
			}
			else
			{
				max = mid
			}

			if min == max
			{
				break
			}
		}

		endIndex = min
	}

	_, err = os.read_at(file, timestampBytes[:], DATE_SIZE); assert(err == 0, "os.read_at error")

	firstTimestamp := transmute(i32)timestampBytes

	if start < firstTimestamp
	{
		start = firstTimestamp
		startIndex = 0
	}
	else
	{
		// Binary search for start
		min = 0
		max = endIndex

		for
		{
			mid := (max - min) / 2 + min

			_, err = os.read_at(file, timestampBytes[:], i64(mid) * size_of(Trade) + DATE_SIZE); assert(err == 0, "os.read_at error")

			midTimestamp := transmute(i32)timestampBytes

			if midTimestamp < start
			{
				min = mid + 1
			}
			else
			{
				max = mid
			}

			if min == max
			{
				break
			}
		}

		startIndex = min
	}

	non_zero_resize(buffer, int(endIndex - startIndex))

	_, err = os.read_at(file, slice.reinterpret([]u8, buffer[:]), i64(startIndex) * size_of(Trade) + DATE_SIZE); assert(err == 0, "os.read_at error")
}

LoadHourVolumeProfiles :: proc() -> VolumeProfilePool
{
	if !os.exists(HOUR_VOLUME_PROFILE_HEADER_FILE)
	{
		return VolumeProfilePool{bucketSize = 5}
	}

	headerFile, err := os.open(HOUR_VOLUME_PROFILE_HEADER_FILE, os.O_RDONLY); assert(err == 0, "os.open error")
	defer os.close(headerFile)

	countBuffer : [4]u8
	os.read(headerFile, countBuffer[:])

	headerCount := transmute(i32)countBuffer

	readIndex : i64 = 0

	profilePool : VolumeProfilePool
	profilePool.bucketSize = HOUR_BUCKET_SIZE

	non_zero_resize(&profilePool.headers, int(headerCount))

	os.read(headerFile, slice.reinterpret([]u8, profilePool.headers[:]))

	lastHeader := slice.last(profilePool.headers[:])
	bucketCount := int(lastHeader.bucketPoolIndex + lastHeader.bucketCount)

	non_zero_resize(&profilePool.buckets, bucketCount)

	bucketFile : os.Handle
	bucketFile, err = os.open(HOUR_VOLUME_PROFILE_BUCKET_FILE, os.O_RDONLY); assert(err == 0, "os.open error")
	defer os.close(headerFile)

	os.read(bucketFile, slice.reinterpret([]u8, profilePool.buckets[:]))

	assert(len(profilePool.headers) != 0, "Header count is 0")
	assert(bucketCount != 0, "Bucket count is 0")

	return profilePool
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