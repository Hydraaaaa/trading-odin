package main

import "core:fmt"
import "core:bytes"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:compress/gzip"

import "../odin-http/client"

BYBIT_ORIGIN_DATE :: DayMonthYear{25, 3, 2020}
BYBIT_ORIGIN_MINUTE_TIMESTAMP :: 1_585_132_560 - TIMESTAMP_2010
BYBIT_ORIGIN_HOUR_OF_DAY :: 10

// Allocates to trades slice, will be nil if download fails
DownloadDay :: proc(date : ^DayMonthYear, trades : ^[]Trade)
{
	trades^ = nil

	pathBuffer : [len("https://public.bybit.com/trading/BTCUSDT/BTCUSDTYYYY-MM-DD.csv.gz")]u8

	apiResponse, apiError := client.get(fmt.bprintf(pathBuffer[:], "https://public.bybit.com/trading/BTCUSDT/BTCUSDT%i-%2i-%2i.csv.gz", date.year, date.month, date.day))

	fmt.printfln("Downloading %2i/%2i/%i", date.day, date.month, date.year)
	if apiError != nil
	{
		fmt.println("DownloadDay request failed:", apiError)
		return
	}

	defer client.response_destroy(&apiResponse)

	responseBody, responseBodyWasAllocated, responseBodyError := client.response_body(&apiResponse)

	if responseBodyError != nil
	{
		fmt.println("DownloadDay error retrieving response body:", responseBodyError)
		return
	}

	// 404 Not Found
	if responseBody.(client.Body_Plain)[0] == '<'
	{
		fmt.println("DownloadDay: 404 Not Found")
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

	trades^ = make([]Trade, len(downloadedTrades))

	// If trades were listed in reverse order in the response body
	if downloadedTrades[0].timestamp > slice.last(downloadedTrades[:]).timestamp
	{
		for i in 0 ..< len(downloadedTrades)
		{
			trades^[i] = downloadedTrades[len(downloadedTrades) - 1 - i]
		}
	}
	else
	{
		for i in 0 ..< len(downloadedTrades)
		{
			trades^[i] = downloadedTrades[i]
		}
	}
}