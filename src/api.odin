package main

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:math"
import "core:os"
import "core:bytes"
import "core:compress/gzip"
import "core:mem"
import "core:bufio"
import "odin-http/client"

import "core:time"

Trade :: struct
{
	timestamp : i32,
	price : f32,
	volume : f32,
	isBuy : bool,
}

MinuteCandleData :: struct
{
	open : f32,
	high : f32,
	low : f32,
	close : f32,
	volume : f32,
}

TRADES_FILE :: "historicaltrades.bin"
MINUTE_CANDLES_FILE :: "historicalminutecandles.bin"

// 00:00:00 UTC, 25 March 2020
//BYBIT_ORIGIN_TIMESTAMP :: 1_585_094_400 // Shouldn't need this with timestamps that are shared between multiple exchanges
BYBIT_ORIGIN_DATE :: DayMonthYear{25, 3, 2020} // Not sure if this can be avoided, may need a start date for each exchange

UpdateHistoricalData :: proc()
{
	trades : [dynamic]Trade
	reserve(&trades, 524288)
	candles : [dynamic]MinuteCandleData
	reserve(&candles, 1440)

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
		
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload.day))
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload.month))
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload.year))

		fmt.println("New trades file")
	}
	else
	{
		historicalTradesFile, ok = os.open(TRADES_FILE, os.O_RDWR)

		dateBytes : [size_of(DayMonthYear)]byte

		integer, err := os.read(historicalTradesFile, dateBytes[:])

		// The file stores the next date to be downloaded, rather than the last date that it contains
		dateToDownload.day = (^int)(&dateBytes[0])^
		dateToDownload.month = (^int)(&dateBytes[size_of(dateToDownload.day)])^
		dateToDownload.year = (^int)(&dateBytes[size_of(dateToDownload.day) + size_of(dateToDownload.month)])^
		
		fmt.printf("Existing trades file, next date to download is: %2i/%2i/%i\n", dateToDownload.day, dateToDownload.month, dateToDownload.year)
	
		tradeBuffer : [size_of(Trade)]u8
		integer, err = os.read(historicalTradesFile, tradeBuffer[:])
		firstTrade = (^Trade)(&tradeBuffer[0])^
		
		os.seek(historicalTradesFile, -size_of(Trade), os.SEEK_END)
		integer, err = os.read(historicalTradesFile, tradeBuffer[:])
		previousDayLastTrade = (^Trade)(&tradeBuffer[0])^
	}
	
	defer os.close(historicalTradesFile)
	
	// Load Historical Candles File ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	historicalCandlesFile : os.Handle

	if !os.is_file(MINUTE_CANDLES_FILE)
	{
		historicalCandlesFile, ok = os.open(MINUTE_CANDLES_FILE, os.O_CREATE)

		fmt.println("New candles file")
	}
	else
	{
		historicalCandlesFile, ok = os.open(MINUTE_CANDLES_FILE, os.O_RDWR)

		fmt.println("Existing candles file")
	
		os.seek(historicalCandlesFile, 0, os.SEEK_END)
	}
		
	defer os.close(historicalCandlesFile)
	
	// Download Data <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

	pathBuffer : [len("https://public.bybit.com/trading/BTCUSDT/BTCUSDTYYYY-MM-DD.csv.gz")]u8
	
	// Time is UTC time, which should reflect the Bybit historical data upload time
	currentDate := Timestamp_ToDayMonthYear(i32(time.now()._nsec / i64(time.Second)))
	
	downloadedTrades : [dynamic]Trade
	reserve(&downloadedTrades, 524288)

	for dateToDownload != currentDate
	{
		apiResponse, apiError := client.get(fmt.bprintf(pathBuffer[:], "https://public.bybit.com/trading/BTCUSDT/BTCUSDT%i-%2i-%2i.csv.gz", dateToDownload.year, dateToDownload.month, dateToDownload.day))

		fmt.printf("Downloading %2i/%2i/%i", dateToDownload.day, dateToDownload.month, dateToDownload.year)
		if apiError != nil
		{
			fmt.printf("Request failed: %s", apiError)
			return
		}

		defer client.response_destroy(&apiResponse)

		responseBody, responseBodyWasAllocated, responseBodyError := client.response_body(&apiResponse)
		
		if responseBodyError != nil
		{
			fmt.printf("Error retrieving response body: %s", responseBodyError)
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
		
		clear(&downloadedTrades)

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
			// TODO: Error main.odin(212:58) Invalid slice indices 67108911:67108864 is out of range 0..<67108864
			// Further details in Remnote
		}

		clear(&trades)
		
		// Direction of data within Bybit daily trades files isn't consistent all the way through
		// In the first day (25, 3, 2020), trades are in inverse chronological order
		// More recent days are in chronological order

		// If trades were listed in reverse order in the response body
		if downloadedTrades[0].timestamp > downloadedTrades[len(downloadedTrades) - 1].timestamp
		{
			#reverse for trade in downloadedTrades
			{
				append(&trades, trade)
			}
		}
		else
		{
			for trade in downloadedTrades
			{
				append(&trades, trade)
			}
		}
		
		if dateToDownload == BYBIT_ORIGIN_DATE
		{
			firstTrade = trades[0]
		}
		
		// Append to local trades file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

		fmt.println(", Appending", len(trades), "trades to local file")
		
		_, writeLocalFileError := os.write(historicalTradesFile, slice.to_bytes(trades[:]))
		
		if writeLocalFileError != 0
		{
			fmt.println(writeLocalFileError)
		}

		// Convert trades to candles <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
		
		currentCandleTimestamp : i32
		
		if dateToDownload == BYBIT_ORIGIN_DATE
		{
			// On the first day, the first trade happens later than 00:00:00 UTC, and so the first candle does as well
			currentCandleTimestamp = i32(math.floor(f32(firstTrade.timestamp) / 60)) * 60
		}
		else
		{
			currentCandleTimestamp = DayMonthYear_ToTimestamp(dateToDownload)
		}

		candle : MinuteCandleData
		
		if dateToDownload == BYBIT_ORIGIN_DATE
		{
			// In the event of this being the first day of data, there is no previous day last trade, so use the first trade instead
			previousDayLastTrade = trades[0]
		}

		// First candle will open at the close of the previous candle
		candle.open = previousDayLastTrade.price
		candle.high = previousDayLastTrade.price
		candle.low = previousDayLastTrade.price
		candle.close = previousDayLastTrade.price
		
		candlesAdded := 0
		
		for trade in trades
		{
			newCandle := false

			// This is a for instead of an if to handle cases where the next trade is more than a minute after the last trade
			// Keep adding empty minutes until we're up to the minute of the trade
			for trade.timestamp >= currentCandleTimestamp + 60
			{
				closePrice := candle.close
				currentCandleTimestamp += 60
				candlesAdded += 1
				append(&candles, candle)
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
		
		// Is the final trade actually closed?
		
		dateToDownload = DayMonthYear_AddDays(dateToDownload, 1)
		
		nextDayTimestamp := DayMonthYear_ToTimestamp(dateToDownload)

		// Close final candle
		// This is a for to handle the case where no new trades have been made during the final minute(s) of the day
		// Will create empty candles up until the new day
		for currentCandleTimestamp < nextDayTimestamp
		{
			candlesAdded += 1
			append(&candles, candle)
			currentCandleTimestamp += 60
			candle.open = candle.close
			candle.high = candle.close
			candle.low = candle.close
			candle.volume = 0
		}
		
		// Append to local minute candles file <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

		if candlesAdded != 1440
		{
            // This isn't necessarily a problem for the first day of data, given that trades didn't begin at 00:00:00 on that day
			fmt.println("PROBLEM!!! Added", candlesAdded, "candles to local file, should be 1440")
		}
		
		_, writeLocalFileError = os.write(historicalCandlesFile, slice.to_bytes(candles[:]))
		
		if writeLocalFileError != 0
		{
			fmt.println(writeLocalFileError)
		}

		clear(&candles)
		
		previousDayLastTrade = downloadedTrades[len(downloadedTrades) - 1]

		os.seek(historicalTradesFile, 0, os.SEEK_SET)
			
		// File intended to store the next date to be downloaded in future
		// dateToDownload was incremented a bit before the minute candles were appended to the file
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload.day))
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload.month))
		os.write(historicalTradesFile, mem.any_to_bytes(dateToDownload.year))

		// Close and reopen both files in order to save their contents
		os.close(historicalTradesFile)
		historicalTradesFile, ok = os.open(TRADES_FILE, os.O_RDWR)
		os.seek(historicalTradesFile, 0, os.SEEK_END)

		os.close(historicalCandlesFile)
		historicalCandlesFile, ok = os.open(MINUTE_CANDLES_FILE, os.O_RDWR)
		os.seek(historicalCandlesFile, 0, os.SEEK_END)

		previousDayLastTrade = trades[len(trades) - 1]
	}
}