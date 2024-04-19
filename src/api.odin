package main

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:os"
import "core:bytes"
import "core:compress/gzip"
import "core:mem"

import "odin-http/client"

Trade :: struct
{
	timestamp : i32,
	price : f32,
	volume : f32,
	isBuy : bool,
}

TRADES_FILE :: "historicaltrades.bin"
MINUTE_CANDLES_FILE :: "historicalminutecandles.bin"

BYBIT_ORIGIN_DATE :: DayMonthYear{25, 3, 2020}
BYBIT_ORIGIN_MINUTE_TIMESTAMP :: 1_585_132_560 - TIMESTAMP_2010

// DayMonthYear is the next date to download
LoadHistoricalData :: proc() -> ([dynamic]Candle, DayMonthYear)
{
	candles := make([dynamic]Candle, 0, 1440)

	firstTrade : Trade
	previousDayLastTrade : Trade

	dateToDownload : DayMonthYear

	// Load Local Trades File ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	historicalTradesFile : os.Handle
	ok : os.Errno
	
	if !os.is_file(TRADES_FILE)
	{
		historicalTradesFile, ok = os.open(TRADES_FILE, os.O_CREATE)

		// First day of bybit trading data
		dateToDownload = DayMonthYear{25, 3, 2020}
		
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload))
	}
	else
	{
		historicalTradesFile, ok = os.open(TRADES_FILE, os.O_RDWR)

		dateBytes : [size_of(DayMonthYear)]byte

		integer, err := os.read(historicalTradesFile, dateBytes[:])

		// The file stores the next date to be downloaded, rather than the last date that it contains
		dateToDownload = transmute(DayMonthYear)dateBytes

		tradeBuffer : [size_of(Trade)]u8
		integer, err = os.read(historicalTradesFile, tradeBuffer[:])
		firstTrade = transmute(Trade)tradeBuffer
		
		os.seek(historicalTradesFile, -size_of(Trade), os.SEEK_END)
		integer, err = os.read(historicalTradesFile, tradeBuffer[:])
		previousDayLastTrade = transmute(Trade)tradeBuffer
	}
	
	os.close(historicalTradesFile)
	
	// Load Historical Candles File ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	historicalCandlesFile : os.Handle

	if !os.is_file(MINUTE_CANDLES_FILE)
	{
		historicalCandlesFile, ok = os.open(MINUTE_CANDLES_FILE, os.O_CREATE)
		os.close(historicalCandlesFile)
	}
	else
	{
		bytes, success := os.read_entire_file_from_filename(MINUTE_CANDLES_FILE)
		
		if !success
		{
			fmt.println("Reading existing candles file unsuccessful")
			return nil, DayMonthYear{0,0,0}
		}

		localCandles := slice.reinterpret([]Candle, bytes)

		reserve(&candles, len(localCandles))
		
		for candle in localCandles
		{
			append(&candles, candle)
		}
	}
	
	return candles, dateToDownload
}

// Returns the next date to be downloaded in future
DownloadDay :: proc(date : ^DayMonthYear, candles : ^[1440]Candle, candlesLen : ^int)
{
	pathBuffer : [len("https://public.bybit.com/trading/BTCUSDT/BTCUSDTYYYY-MM-DD.csv.gz")]u8
	
	apiResponse, apiError := client.get(fmt.bprintf(pathBuffer[:], "https://public.bybit.com/trading/BTCUSDT/BTCUSDT%i-%2i-%2i.csv.gz", date.year, date.month, date.day))

	fmt.printfln("Downloading %2i/%2i/%i", date.day, date.month, date.year)
	if apiError != nil
	{
		fmt.println("Request failed: ", apiError)
		return
	}

	defer client.response_destroy(&apiResponse)

	responseBody, responseBodyWasAllocated, responseBodyError := client.response_body(&apiResponse)
	
	if responseBodyError != nil
	{
		fmt.println("Error retrieving response body: ", responseBodyError)
		return
	}
	
	// 404 Not Found
	if responseBody.(client.Body_Plain)[0] == '<'
	{
		fmt.println("DownloadDay: 404 Not Found")
		candlesLen^ = -1
		return
	}

	defer client.body_destroy(responseBody, responseBodyWasAllocated)

	// Unzip the downloaded gzip file
	downloadedDataBuffer := bytes.Buffer{}

	gzip.load(transmute([]u8)(responseBody.(client.Body_Plain)), &downloadedDataBuffer)

	downloadedDataLen := bytes.buffer_length(&downloadedDataBuffer)
	downloadedData := bytes.buffer_to_string(&downloadedDataBuffer)

	// Read csv into memory
	HEADER :: "timestamp,symbol,side,size,price,tickDirection,trdMatchID,grossValue,homeNotional,foreignNotional\n"

	downloadedDataPos := len(HEADER)
	
	downloadedTrades : [dynamic]Trade
	reserve(&downloadedTrades, 524288)

	for downloadedDataPos < downloadedDataLen - 5
	{
		trade : Trade

		// Timestamp
		// +10 because the shortest a timestamp will ever be is 10 chars
		commaIndex := strings.index_byte(downloadedData[downloadedDataPos + 10:], ',') + 10
		trade.timestamp = i32(i64(strconv.atof(downloadedData[downloadedDataPos:downloadedDataPos + commaIndex])) - TIMESTAMP_2010)
		downloadedDataPos += commaIndex + 9 // After the comma, there are 9 chars before the buy/sell data

		// Buy/Sell
		// Could potentially optimize with some bool arithmetic, downloadedDataPos += 5 - isBuy
		if downloadedData[downloadedDataPos] == 'B'
		{
			trade.isBuy = true
			downloadedDataPos += 4
		}
		else
		{
			trade.isBuy = false
			downloadedDataPos += 5
		}

		ok : bool

		// Volume
		commaIndex = strings.index_byte(downloadedData[downloadedDataPos:], ',')
		trade.volume, ok = strconv.parse_f32(downloadedData[downloadedDataPos:downloadedDataPos + commaIndex])
		downloadedDataPos += commaIndex + 1
		
		// Price
		commaIndex = strings.index_byte(downloadedData[downloadedDataPos:], ',')
		trade.price, ok = strconv.parse_f32(downloadedData[downloadedDataPos:downloadedDataPos + commaIndex])
		downloadedDataPos += commaIndex + 1

		append(&downloadedTrades, trade)
		
		// Each row won't be any shorter than another 63 chars long, so can save time by skipping 63 chars forward
		downloadedDataPos += strings.index_byte(downloadedData[downloadedDataPos + 63:], '\n') + 64
	}
	
	// Direction of data within Bybit daily trades files isn't consistent all the way through
	// In the first day (25, 3, 2020), trades are in inverse chronological order
	// More recent days are in chronological order

	// TODO: Compare writing line by line with #reverse, and appending to new array and bulk copying
	
	orderedTrades : [dynamic]Trade
	reserve(&orderedTrades, len(downloadedTrades))

	// If trades were listed in reverse order in the response body
	if downloadedTrades[0].timestamp > downloadedTrades[len(downloadedTrades) - 1].timestamp
	{
		#reverse for trade in downloadedTrades
		{
			append(&orderedTrades, trade)
		}
	}
	else
	{
		for trade in downloadedTrades
		{
			append(&orderedTrades, trade)
		}
	}

	// Append to local trades file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	firstTrade : Trade
	previousDayLastTrade : Trade

	historicalTradesFile, ok := os.open(TRADES_FILE, os.O_RDWR)

	dateBytes : [size_of(DayMonthYear)]byte

	integer, err := os.read(historicalTradesFile, dateBytes[:])

	tradeBuffer : [size_of(Trade)]u8
	integer, err = os.read(historicalTradesFile, tradeBuffer[:])
	firstTrade = (^Trade)(&tradeBuffer[0])^
	
	os.seek(historicalTradesFile, -size_of(Trade), os.SEEK_END)
	integer, err = os.read(historicalTradesFile, tradeBuffer[:])
	previousDayLastTrade = (^Trade)(&tradeBuffer[0])^
	
	if date^ == BYBIT_ORIGIN_DATE
	{
		firstTrade = orderedTrades[0]
	}

	fmt.println("Appending", len(orderedTrades), "trades to local file")
	
	_, writeLocalFileError := os.write(historicalTradesFile, slice.to_bytes(orderedTrades[:]))
	
	if writeLocalFileError != 0
	{
		fmt.println(writeLocalFileError)
	}

	os.seek(historicalTradesFile, 0, os.SEEK_SET)
		
	// File stores the next date to be downloaded in future
	nextDate := DayMonthYear_AddDays(date^, 1)
	
	os.write(historicalTradesFile, mem.any_to_bytes(nextDate.day))
	os.write(historicalTradesFile, mem.any_to_bytes(nextDate.month))
	os.write(historicalTradesFile, mem.any_to_bytes(nextDate.year))
	
	os.close(historicalTradesFile)

	// Convert trades to candles <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	
	currentCandleTimestamp : i32
	
	if date^ == BYBIT_ORIGIN_DATE
	{
		// On the first day, the first trade happens later than 00:00:00 UTC, and so the first candle does as well
		currentCandleTimestamp = BYBIT_ORIGIN_MINUTE_TIMESTAMP

		// In the event of this being the first day of data, there is no previous day last trade, so use the first trade instead
		previousDayLastTrade = orderedTrades[0]
	}
	else
	{
		currentCandleTimestamp = DayMonthYear_ToTimestamp(date^)
	}
	
	candle : Candle

	// First candle will open at the close of the previous candle
	candle.open = previousDayLastTrade.price
	candle.high = previousDayLastTrade.price
	candle.low = previousDayLastTrade.price
	candle.close = previousDayLastTrade.price
	
	candlesAdded := 0
	
	for trade in orderedTrades
	{
		newCandle := false

		// This is a for instead of an if to handle cases where the next trade is more than a minute after the last trade
		// Keep adding empty minutes until we're up to the minute of the trade
		for trade.timestamp >= currentCandleTimestamp + 60
		{
			closePrice := candle.close
			currentCandleTimestamp += 60
			candles[candlesAdded] = candle
			candlesAdded += 1
			candle.open = closePrice
			candle.high = closePrice
			candle.low = closePrice
			candle.volume = 0
			newCandle = true
		}

		if newCandle
		{
			continue
		}

		if trade.price > candle.high
		{
			candle.high = trade.price
		}
		if trade.price < candle.low
		{
			candle.low = trade.price
		}

		candle.close = trade.price

		candle.volume += trade.volume
	}
	
	nextDayTimestamp := DayMonthYear_ToTimestamp(nextDate)

	// Close final candle
	// This for is to handle the case where no new trades have been made during the final minute(s) of the day
	// Will create empty candles up until the new day
	for currentCandleTimestamp < nextDayTimestamp
	{
		candles[candlesAdded] = candle
		candlesAdded += 1
		currentCandleTimestamp += 60
		candle.open = candle.close
		candle.high = candle.close
		candle.low = candle.close
		candle.volume = 0
	}

	// Append to local historical candles file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	if candlesAdded != 1440 && date^ != BYBIT_ORIGIN_DATE
	{
		// This isn't necessarily a problem for the first day of data, given that trades didn't begin at 00:00:00 on that day
		fmt.println("PROBLEM!!! Added", candlesAdded, "candles to local file, should be 1440")
	}

	historicalCandlesFile : os.Handle
	historicalCandlesFile, ok = os.open(MINUTE_CANDLES_FILE, os.O_RDWR)

	os.seek(historicalCandlesFile, 0, os.SEEK_END)
	
	_, writeLocalFileError = os.write(historicalCandlesFile, slice.to_bytes(candles[:candlesAdded]))
	
	if writeLocalFileError != 0
	{
		fmt.println(writeLocalFileError)
	}

	os.close(historicalCandlesFile)
	
	candlesLen^ = candlesAdded
	date^ = nextDate
}

LoadTradesBetween :: proc(start : i32, end : i32, buffer : ^[dynamic]Trade)
{
	file, ok := os.open(TRADES_FILE, os.O_RDWR)
	defer os.close(file)
	
	if ok != 0
	{
		fmt.println("LoadTradesBetween os.open Error:", ok)
		return
	}
	
	fileSize : i64
	fileSize, ok = os.file_size(file)
	
	if ok != 0
	{
		fmt.println("LoadTradesBetween os.file_size Error:", ok)
	}
	
	DATE_SIZE :: size_of(DayMonthYear)

	min : i32 = 0
	max : i32 = i32((fileSize - DATE_SIZE) / size_of(Trade))
	
	start := start
	end := end

	startIndex : i32 = ---
	endIndex : i32 = ---

	timestampBytes : [size_of(i32)]u8 = ---
	integer, err := os.read_at(file, timestampBytes[:], fileSize - size_of(Trade))
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
			
			integer, err := os.read_at(file, timestampBytes[:], i64(mid) * size_of(Trade) + DATE_SIZE)
		
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

	integer, err = os.read_at(file, timestampBytes[:], DATE_SIZE)
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
		max = endIndex - 1
		
		for
		{
			mid := (max - min) / 2 + min
			
			integer, err := os.read_at(file, timestampBytes[:], i64(mid) * size_of(Trade) + DATE_SIZE)
		
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
	
	integer, err = os.read_at(file, slice.reinterpret([]u8, buffer[:]), i64(startIndex) * size_of(Trade) + DATE_SIZE)
}