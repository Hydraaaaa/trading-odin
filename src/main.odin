package main

import "core:fmt"
import "core:strings"
import "core:math"
import "core:thread"
import "core:time"
import "vendor:raylib"

INITIAL_SCREEN_WIDTH :: 1440
INITIAL_SCREEN_HEIGHT :: 720

START_ZOOM_INDEX :: Timeframe.DAY

ZOOM_THRESHOLD :: 3
ZOOM_INCREMENT :: 1.07

HORIZONTAL_LABEL_PADDING :: 3
VERTICAL_LABEL_PADDING :: HORIZONTAL_LABEL_PADDING - 2

FONT_SIZE :: 14

CANDLE_TIMEFRAME_INCREMENTS : [10]i32 : {60, 300, 900, 1800, 3600, 10_800, 21_600, 43_200, 86_400, 604_800}

main :: proc()
{
	using raylib
	
	profilerData : ProfilerData
	
	SetConfigFlags({.WINDOW_RESIZABLE})

	InitWindow(INITIAL_SCREEN_WIDTH, INITIAL_SCREEN_HEIGHT, "Trading")
	defer CloseWindow()
	
	icon := LoadImage("icon.png")
	defer UnloadImage(icon)

	SetWindowIcon(icon)

	screenWidth : i32 = INITIAL_SCREEN_WIDTH
	screenHeight : i32 = INITIAL_SCREEN_HEIGHT

	windowedScreenWidth : i32 = 0
	windowedScreenHeight : i32 = 0

    SetTargetFPS(60)
	fpsString : string

	font := LoadFontEx("roboto-bold.ttf", FONT_SIZE, nil, 0)
	
	candleData : [TIMEFRAME_COUNT]CandleList

	dateToDownload : DayMonthYear = ---

	candleData[Timeframe.MINUTE].candles, dateToDownload = LoadHistoricalData()
	candleData[Timeframe.MINUTE].offset = BYBIT_ORIGIN_MINUTE_TIMESTAMP
	defer delete(candleData[Timeframe.MINUTE].candles)
	
	candleTimeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	// Time is UTC, which matches Bybit's historical data upload time
	currentDate := Timestamp_ToDayMonthYear(i32(time.now()._nsec / i64(time.Second)))
	
	downloadThread : ^thread.Thread
	downloadedCandles : [dynamic]Candle
	
	if dateToDownload != currentDate
	{
		downloadThread = thread.create_and_start_with_poly_data2(&dateToDownload, &downloadedCandles, DownloadDay)
	}

	// Create higher timeframe candles ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	{
		prevTimeframe := Timeframe.MINUTE
		
		for timeframe in Timeframe.MINUTE_5 ..= Timeframe.WEEK
		{
			candleData[timeframe].timeframe = timeframe

			prevCandles := candleData[prevTimeframe].candles[:]

			prevCandlesLen := len(prevCandles)
			
			timeframeDivisor := int(candleTimeframeIncrements[timeframe] / candleTimeframeIncrements[prevTimeframe])
			
			candleData[timeframe].offset = Candle_FloorTimestamp(candleData[prevTimeframe].offset, timeframe)
			
			// + 1 accounts for a higher timeframe candle at the beginning with only partial data
			reserve(&candleData[timeframe].candles, prevCandlesLen / timeframeDivisor + 1)
			
			// Separately calculate the subcandles of the first candle to handle the case where the candle timestamps aren't aligned
			firstCandleComponentCount := timeframeDivisor - int((candleData[prevTimeframe].offset - candleData[timeframe].offset) / candleTimeframeIncrements[prevTimeframe])
			
			start := 0
			end := firstCandleComponentCount
			
			if end == 0
			{
				end += timeframeDivisor
			}
			
			for end <= prevCandlesLen
			{
				append(&candleData[timeframe].candles, Candle_Merge(prevCandles[start:end]))
				
				start = end
				end += timeframeDivisor
			}
			
			// Create a final partial candle if applicable (like on weekly candles)
			if start < prevCandlesLen
			{
				append(&candleData[timeframe].candles, Candle_Merge(prevCandles[start:prevCandlesLen]))
			}
			
			prevTimeframe = timeframe
		}

		// Monthly candles
		candleData[Timeframe.MONTH].timeframe = Timeframe.MONTH

		// Find floored month offset + start index for the candle creation
		monthlyIncrements := MONTHLY_INCREMENTS
		
		fourYearTimestamp := candleData[prevTimeframe].offset % FOUR_YEARS

		fourYearIndex := 47
		
		for fourYearTimestamp < monthlyIncrements[fourYearIndex]
		{
			fourYearIndex -= 1
		}

		candleData[Timeframe.MONTH].offset = candleData[prevTimeframe].offset - fourYearTimestamp + monthlyIncrements[fourYearIndex]

		// Create candles
		dayCandles := candleData[Timeframe.DAY].candles[:]

		daysPerMonth := DAYS_PER_MONTH
		
		start := 0
		
		offsetDate := Timestamp_ToDayMonthYear(candleData[Timeframe.MONTH].offset)
		
		offsetDate.month += 1
		
		if offsetDate.month > 12
		{
			offsetDate.month = 1
			offsetDate.year += 1
		}
		
		end := int(DayMonthYear_ToTimestamp(DayMonthYear{1, offsetDate.month, offsetDate.year}) - candleData[Timeframe.DAY].offset) / DAY

		dayCandlesLen := len(dayCandles)
			
		for end <= dayCandlesLen
		{
			append(&candleData[Timeframe.MONTH].candles, Candle_Merge(dayCandles[start:end]))
			
			start = end
		
			fourYearIndex += 1
			
			if fourYearIndex > 47
			{
				fourYearIndex = 0
			}

			end += daysPerMonth[fourYearIndex]
		}
		
		// Create a final partial candle when applicable
		if start < dayCandlesLen
		{
			append(&candleData[Timeframe.MONTH].candles, Candle_Merge(dayCandles[start:dayCandlesLen]))
		}
	}
	
	scaleData : ScaleData

	scaleData.zoom = 1
	scaleData.horizontalScale = f64(CandleList_IndexToDuration(candleData[START_ZOOM_INDEX], 0) / (ZOOM_THRESHOLD * 2))
	scaleData.logScale = true

	cameraPosX : i32
	cameraPosY : i32

	zoomIndex := START_ZOOM_INDEX
	zoomLevel := 0
	verticalZoomLevel : f32 = 0

	dragging := false
	rightDragging := false
	rightDraggingPriceStart : f32

	// Set initial camera X position to show the most recent candle on the right
	{
		candleIndex := i32(len(candleData[zoomIndex].candles) - 1)

		cameraPosX = i32(f64(CandleList_IndexToTimestamp(candleData[zoomIndex], i32(len(candleData[zoomIndex].candles))) + CandleList_IndexToDuration(candleData[zoomIndex], candleIndex)) / scaleData.horizontalScale - INITIAL_SCREEN_WIDTH + 70)
	}

	cameraTimestamp := i32(f64(cameraPosX) * scaleData.horizontalScale)
	cameraEndTimestamp := i32(f64(cameraPosX + INITIAL_SCREEN_WIDTH) * scaleData.horizontalScale)
	mouseTimestamp : i32

	// Slice of all candles that currently fit within the width of the screen
	visibleCandles : []Candle
	visibleCandlesStartIndex : i32
	visibleCandles, visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(candleData[zoomIndex], cameraTimestamp, cameraEndTimestamp)

	highestCandle, highestCandleIndex := Candle_HighestHigh(visibleCandles)
	lowestCandle, lowestCandleIndex := Candle_LowestLow(visibleCandles)

	highestCandleIndex += visibleCandlesStartIndex
	lowestCandleIndex += visibleCandlesStartIndex
	cursorCandleIndex : i32

	initialVerticalScale : f64

	// Set initial vertical scale to fit all initially visible candles on screen
	{
		low : f32 = 10000000
		high : f32 = 0

		for candle in visibleCandles
		{
			if candle.low < low
			{
				low = candle.low
			}

			if candle.high > high
			{
				high = candle.high
			}
		}

		middle : f32 = (math.log10(high) + math.log10(low)) / 2

		initialVerticalScale = f64(math.log10(high) - math.log10(low)) / (INITIAL_SCREEN_HEIGHT - 64)

		cameraPosY = i32(-(f64(middle) / initialVerticalScale) - INITIAL_SCREEN_HEIGHT / 2)
	}

	scaleData.verticalScale = initialVerticalScale

	// UPDATE <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	for !WindowShouldClose()
	{
		if IsWindowResized()
		{
			newScreenWidth : i32
			newScreenHeight : i32

			if IsWindowFullscreen()
			{
				newScreenWidth = GetMonitorWidth(0)
				newScreenHeight = GetMonitorHeight(0)
			}
			else
			{
				newScreenWidth = GetScreenWidth()
				newScreenHeight = GetScreenHeight()
			}

			cameraPosX -= newScreenWidth - screenWidth

			cameraPrice : f32 = Price_FromPixelY(cameraPosY + screenHeight / 2, scaleData)

			initialVerticalScale *= f64(screenHeight) / f64(newScreenHeight)
			scaleData.verticalScale *= f64(screenHeight) / f64(newScreenHeight)

			screenWidth = newScreenWidth
			screenHeight = newScreenHeight

			cameraPosY = Price_ToPixelY(cameraPrice, scaleData) - screenHeight / 2
		}

		if IsKeyPressed(.F11)
		{
			ToggleFullscreen()

			if IsWindowFullscreen()
			{
				windowedScreenWidth = screenWidth
				windowedScreenHeight = screenHeight

				SetWindowSize(GetMonitorWidth(0), GetMonitorHeight(0))
			}
			else
			{
				SetWindowSize(windowedScreenWidth, windowedScreenHeight)
			}
		}

		// Camera Panning
		if IsMouseButtonPressed(.LEFT)
		{
			dragging = true
		}

		if IsMouseButtonReleased(.LEFT)
		{
			dragging = false
		}

		if dragging
		{
			cameraPosX -= i32(GetMouseDelta().x)
			cameraPosY -= i32(GetMouseDelta().y)
		}

		// Vertical Scale Adjustment
		if IsMouseButtonPressed(.RIGHT)
		{
			rightDragging = true
			rightDraggingPriceStart = Price_FromPixelY(cameraPosY + screenHeight / 2, scaleData)
		}

		if IsMouseButtonReleased(.RIGHT)
		{
			rightDragging = false
		}

		if rightDragging
		{
			verticalZoomLevel += GetMouseDelta().y
			scaleData.verticalScale = initialVerticalScale * math.exp(f64(verticalZoomLevel) / 500)

			cameraPosY = Price_ToPixelY(rightDraggingPriceStart, scaleData) - screenHeight / 2
		}

		// Zooming
		if GetMouseWheelMove() != 0
		{
			zoomLevel -= int(GetMouseWheelMove())

			// Remove zoom from screen space as we adjust it
			cameraCenterX : f64 = (f64(cameraPosX) + f64(screenWidth) / 2) * scaleData.zoom
			cameraCenterY : f64 = (f64(cameraPosY) + f64(screenHeight) / 2) * scaleData.zoom

			scaleData.zoom = 1

			i := zoomLevel

			for i > 0
			{
				scaleData.zoom *= ZOOM_INCREMENT
				i -= 1
			}

			for i < 0
			{
				scaleData.zoom /= ZOOM_INCREMENT
				i += 1
			}

			zoomIndex = Timeframe(TIMEFRAME_COUNT - 1)
			
			for int(zoomIndex) > 0 &&
			    CandleList_IndexToWidth(candleData[zoomIndex - Timeframe(1)], 0, scaleData) > ZOOM_THRESHOLD
			{
				zoomIndex -= Timeframe(1)
			}

			// Re-add zoom post update
			cameraPosX = i32(cameraCenterX / scaleData.zoom - f64(screenWidth) / 2)
			cameraPosY = i32(cameraCenterY / scaleData.zoom - f64(screenHeight) / 2)
		}
		
		// Check download thread
		if thread.is_done(downloadThread)
		{
			thread.destroy(downloadThread)
			
			// TODO: Merge candles, simplified version of candle creation, can hardcode week/month
			// Candles_Merge(existingCandle, newCandles[:])
	
			if dateToDownload != currentDate
			{
				downloadThread = thread.create_and_start_with_poly_data2(&dateToDownload, &downloadedCandles, DownloadDay)
			}
		}

		// Update visibleCandles
		cameraTimestamp = Timestamp_FromPixelX(cameraPosX, scaleData)
		cameraEndTimestamp = Timestamp_FromPixelX(cameraPosX + screenWidth, scaleData)
		visibleCandles, visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(candleData[zoomIndex], cameraTimestamp, cameraEndTimestamp)
		highestCandle, highestCandleIndex = Candle_HighestHigh(visibleCandles)
		lowestCandle, lowestCandleIndex = Candle_LowestLow(visibleCandles)

		highestCandleIndex += visibleCandlesStartIndex
		lowestCandleIndex += visibleCandlesStartIndex

		// If the last candle is before the start of the viewport
		// Update candle under cursor
		{
			// We add one pixel to the cursor's position, as all of the candles' timestamps get rounded down when converted
			// As we are doing the opposite conversion, the mouse will always be less than or equal to the candles
			timestamp : i32 = Timestamp_FromPixelX(GetMouseX() + cameraPosX + 1, scaleData)

			//if i32(len(visibleCandles) - 1) * candleTimeframeIncrements[zoomIndex] < timestamp @@@
			if CandleList_IndexToTimestamp(candleData[zoomIndex], i32(len(visibleCandles)) + visibleCandlesStartIndex - 1) < timestamp
			{
				cursorCandleIndex = i32(len(visibleCandles)) - 1 + visibleCandlesStartIndex
			}
			else
			{
				cursorCandleIndex = CandleList_TimestampToIndex(candleData[zoomIndex], timestamp)
			}
		}

		if IsKeyPressed(.L)
		{
			cameraTop : f32 = Price_FromPixelY(cameraPosY, scaleData)
			cameraBottom : f32 = Price_FromPixelY(cameraPosY + screenHeight, scaleData)

			priceUpper : f32 = 0
			priceLower : f32 = 10000000

			// Rescale Candles
			for candle in visibleCandles
			{
				if candle.high > priceUpper
				{
					priceUpper = candle.high
				}

				if candle.low < priceLower
				{
					priceLower = candle.low
				}
			}
			
			if priceUpper > cameraTop
			{
				priceUpper = cameraTop
			}

			if priceLower < cameraBottom
			{
				priceLower = cameraBottom
			}
			
			prePixelUpper : f32 = Price_ToPixelY_f32(priceUpper, scaleData)
			prePixelLower : f32 = Price_ToPixelY_f32(priceLower, scaleData)

			pixelOffset : i32 = i32(prePixelUpper) - cameraPosY

			scaleData.logScale = !scaleData.logScale

			postPixelUpper : f32 = Price_ToPixelY_f32(priceUpper, scaleData)
			postPixelLower : f32 = Price_ToPixelY_f32(priceLower, scaleData)

			difference : f64 = f64(postPixelLower - postPixelUpper) / f64(prePixelLower - prePixelUpper)
			
			initialVerticalScale *= difference
			scaleData.verticalScale *= difference
			
			cameraPosY = Price_ToPixelY(priceUpper, scaleData) - pixelOffset
		}

		// Rendering <><><><><><><><><><><><><><><><><><><><><><><><><><><><>
		
        BeginDrawing()

		ClearBackground(BLACK)
		
		// Used for label bars
		MIN_ALPHA :: 10
		MAX_ALPHA :: 19
		ALPHA_RANGE :: MAX_ALPHA - MIN_ALPHA

		// Generate price labels
		// Draw lines before candles are drawn
		// Draw labels after candles are drawn
		PriceLabel :: struct
		{
			price : f32,
			text : string,
			textBuffer : [32]u8, // Much larger buffer than timestamp labels, as log scale can balloon the prices, and memecoins, if ever implemented, use huge decimals
			width : i32,
			color : Color,
		}
		
		// These are the only four linear scale increments, once these are exhausted, the values are multiplied by 10 and recycled
		priceLabels : [dynamic]PriceLabel
		reserve(&priceLabels, 32)

		labelHeight := i32(MeasureTextEx(font, "W\x00", FONT_SIZE, 0).y + VERTICAL_LABEL_PADDING * 2)

		priceLabelSpacing : i32 = labelHeight + 6

		MINIMUM_DECIMAL :: 0.01

		if scaleData.logScale
		{
			priceIncrements : [4]f32 = {1, 2.5, 5, 10}

			topLabelPrice := Price_FromPixelY(cameraPosY - labelHeight / 2, scaleData)
			priceDifference := Price_FromPixelY(cameraPosY - labelHeight / 2 - priceLabelSpacing, scaleData) - topLabelPrice
			
			currentMagnitude : f32 = 1_000_000_000
			
			for currentMagnitude > priceDifference
			{
				currentMagnitude *= 0.1
			}

			normalizedDifference := priceDifference / currentMagnitude

			for i in 1 ..< len(priceIncrements)
			{
				if normalizedDifference < priceIncrements[i]
				{
					topLabelPrice = topLabelPrice - math.mod(topLabelPrice, priceIncrements[i] * currentMagnitude)
					break
				}
			}

			append(&priceLabels, PriceLabel{})
			label := &priceLabels[len(priceLabels) - 1]
			
			label.price = topLabelPrice
			label.text = fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
			label.width = i32(MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x) + HORIZONTAL_LABEL_PADDING * 2
			label.color = Color{255, 255, 255, MAX_ALPHA}
			
			prevPrice := topLabelPrice
			prevPixel := Price_ToPixelY(prevPrice, scaleData)
			
			for prevPixel < cameraPosY + screenHeight
			{
				currentPrice := Price_FromPixelY(prevPixel + priceLabelSpacing, scaleData)
				priceDifference = prevPrice - currentPrice
				
				for currentMagnitude > priceDifference
				{
					// TODO: Infinite loop upon enough zoom out
					currentMagnitude *= 0.1
				}
				
				normalizedDifference = priceDifference / currentMagnitude
				
				for i in 1 ..< len(priceIncrements)
				{
					if normalizedDifference < priceIncrements[i]
					{
						currentPrice = currentPrice - math.mod(currentPrice, priceIncrements[i] * currentMagnitude)
						break
					}
				}

				append(&priceLabels, PriceLabel{})
				label := &priceLabels[len(priceLabels) - 1]
				
				label.price = currentPrice
				label.text = fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
				label.width = i32(MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x) + HORIZONTAL_LABEL_PADDING * 2
				label.color = Color{255, 255, 255, MAX_ALPHA}
				
				prevPixel = Price_ToPixelY(currentPrice, scaleData)
				prevPrice = currentPrice
			}
		}
		else
		{
			priceIncrements : [4]f32 = {1, 2, 2.5, 5}
		
			// Linear scaling
			// Do everything multiplied by the minimum decimal so that the minimum value is 1
			// This way everything can be done in integers and we can avoid precision errors
			
			priceLabelSpacing = i32(f32(priceLabelSpacing) / MINIMUM_DECIMAL)

			pixelPriceIncrement : f32 = abs(Price_ToPixelY_f32(1, scaleData) - Price_ToPixelY_f32(0, scaleData))
			
			// Will need to reference a minimum size value in the scenario of memecoins or alt pairs with BTC
			priceIncrementMultiplier : i32 = 1
			priceIncrementIndex := 0
			
			// Can we math this out?
			for i32(pixelPriceIncrement * f32(priceIncrementMultiplier) * priceIncrements[len(priceIncrements) - 1]) < priceLabelSpacing
			{
				priceIncrementMultiplier *= 10				
			}

			for i32(pixelPriceIncrement * f32(priceIncrementMultiplier) * priceIncrements[priceIncrementIndex]) < priceLabelSpacing
			{
				priceIncrementIndex += 1
			}
			
			priceIncrement := i32(f32(priceIncrementMultiplier) * priceIncrements[priceIncrementIndex])
			
			screenTopPrice := i32(Price_FromPixelY(cameraPosY, scaleData) / MINIMUM_DECIMAL)
			screenBottomPrice := i32(Price_FromPixelY(cameraPosY + screenHeight, scaleData) / MINIMUM_DECIMAL)
			
			// Round to the nearest increment (which lies above the screen border)
			currentPrice := screenTopPrice + priceIncrement - screenTopPrice % priceIncrement
			lastPrice := i32(screenBottomPrice - priceIncrement)
			
			for currentPrice > lastPrice
			{
				append(&priceLabels, PriceLabel{})
				label := &priceLabels[len(priceLabels) - 1]
				
				label.price = f32(currentPrice) / 100
				label.text = fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
				label.width = i32(MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x) + HORIZONTAL_LABEL_PADDING * 2
				
				significantIncrementTest := label.price / (f32(priceIncrementMultiplier) / 10)
				
				if significantIncrementTest == f32(i32(significantIncrementTest))
				{
					label.color = Color{255, 255, 255, MAX_ALPHA}
				}
				else
				{
					label.color = Color{255, 255, 255, MIN_ALPHA}
				}
				
				currentPrice -= priceIncrement
			}
		}

		// Draw Price Lines
		for label in priceLabels
		{
			pixelY := Price_ToPixelY(label.price, scaleData) - cameraPosY

			DrawRectangle(0, pixelY, screenWidth - label.width, 1, label.color)
		}

		// Generate timestamp labels
		// Draw lines before candles are drawn
		// Draw labels after candles are drawn
		timeRange := cameraEndTimestamp - cameraTimestamp

		pixelTimestampIncrement := Timestamp_FromPixelX(1, scaleData)
		
		TimestampLabel :: struct
		{
			timestamp : i32,
			text : string,
			textBuffer : [8]u8,
			color : Color,
		}
		
		timestampLabels : [dynamic]TimestampLabel
		reserve(&timestampLabels, 32)
		
		DAY_TIMESTAMP :: 2880
		DAY31_TIMESTAMP :: 75_000
		
		switch pixelTimestampIncrement
		{
			case 0 ..< DAY_TIMESTAMP: // Times + Days
			{
				INCREMENT_COUNT :: 9
				incrementRequirements : [INCREMENT_COUNT]i32 = \
				{ \
					0, \
					DAY_TIMESTAMP / 2880, \
					DAY_TIMESTAMP / 576, \
					DAY_TIMESTAMP / 192, \
					DAY_TIMESTAMP / 96, \
					DAY_TIMESTAMP / 48, \
					DAY_TIMESTAMP / 16, \
					DAY_TIMESTAMP / 8, \
					DAY_TIMESTAMP / 4 \
				}

				increments : [INCREMENT_COUNT + 1]i32 = \
				{ \
					60, \
					300, \
					900, \
					1800, \
					3600, \
					10_800, \
					21_600, \
					43_200, \
					86_400, \
					86_400 \
				} // Extra 86_400 to conveniently handle [index + 1] query
				
				incrementIndex : int = INCREMENT_COUNT - 1
				
				for pixelTimestampIncrement < incrementRequirements[incrementIndex]
				{
					incrementIndex -= 1
				}
				
				// Round the current timestamp
				// As these are ints, the decimal value will be lost in the division, leading to a perfect increment
				currentTimestamp := (cameraTimestamp / increments[incrementIndex]) * increments[incrementIndex]

				prevTimestamp : i32 = 0
		
				for prevTimestamp < cameraEndTimestamp
				{
					append(&timestampLabels, TimestampLabel{})
					
					label := &timestampLabels[len(timestampLabels) - 1]
					
					label.color = WHITE
					
					currentDate := Timestamp_ToDayMonthYear(currentTimestamp)
					
					label.timestamp = currentTimestamp
					
					dayTimestamp := currentTimestamp % DAY
					
					// Setting label contents
					if dayTimestamp == 0 // Days
					{
						if currentDate.day == 1 // Months
						{
							switch currentDate.month
							{
								case 2: label.text = fmt.bprintf(label.textBuffer[:], "Feb\x00")
								case 3: label.text = fmt.bprintf(label.textBuffer[:], "Mar\x00")
								case 4: label.text = fmt.bprintf(label.textBuffer[:], "Apr\x00")
								case 5: label.text = fmt.bprintf(label.textBuffer[:], "May\x00")
								case 6: label.text = fmt.bprintf(label.textBuffer[:], "Jun\x00")
								case 7: label.text = fmt.bprintf(label.textBuffer[:], "Jul\x00")
								case 8: label.text = fmt.bprintf(label.textBuffer[:], "Aug\x00")
								case 9: label.text = fmt.bprintf(label.textBuffer[:], "Sep\x00")
								case 10: label.text = fmt.bprintf(label.textBuffer[:], "Oct\x00")
								case 11: label.text = fmt.bprintf(label.textBuffer[:], "Nov\x00")
								case 12: label.text = fmt.bprintf(label.textBuffer[:], "Dec\x00")
								case: label.text = fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.year)
							}
						}
						else
						{
							label.text = fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.day)
						}
					}
					else
					{
						hours   := dayTimestamp / 3600
						minutes := dayTimestamp % 3600 / 60
						label.text = fmt.bprintf(label.textBuffer[:], "%i:%2i", hours, minutes)
					}
					
					// Fading out smaller increments
					if incrementIndex == INCREMENT_COUNT - 1
					{
						if currentDate.day != 1
						{
							label.color.a = u8((1 - f32(pixelTimestampIncrement) / DAY_TIMESTAMP) * ALPHA_RANGE) + MIN_ALPHA
						}
						else
						{
							label.color.a = MAX_ALPHA
						}
					}
					else // Fading out days in favour of months
					{
						if currentTimestamp % increments[incrementIndex + 1] != 0
						{
							if incrementRequirements[incrementIndex] != incrementRequirements[incrementIndex + 1]
							{
								label.color.a = u8((1 - (f32(pixelTimestampIncrement) - f32(incrementRequirements[incrementIndex])) / (f32(incrementRequirements[incrementIndex + 1]) - f32(incrementRequirements[incrementIndex]))) * ALPHA_RANGE) + MIN_ALPHA
							}
							else
							{
								label.color.a = MAX_ALPHA							
							}
						}
						else
						{
							label.color.a = MAX_ALPHA
						}
					}

					prevTimestamp = currentTimestamp

					currentTimestamp += increments[incrementIndex]
				}
			}
			case:
			{
				currentDate := Timestamp_ToDayMonthYear(cameraTimestamp)
				currentDate.day = 1
				
				INCREMENT_COUNT :: 4

				// Values for detemining how many months to increment for each label
				incrementRequirements : [INCREMENT_COUNT]i32 = {0, DAY31_TIMESTAMP, DAY31_TIMESTAMP * 3, DAY31_TIMESTAMP * 6}
				increments : [INCREMENT_COUNT + 1]int = {1, 3, 6, 12, 12} // Extra 12 to conveniently handle [index + 1] query
				
				incrementIndex : int = INCREMENT_COUNT - 1
				
				for pixelTimestampIncrement < incrementRequirements[incrementIndex]
				{
					incrementIndex -= 1
				}

				// Get each month within the current increment steps, but make sure that the increments are offset from January
				// This ensures year numbers are included
				monthOffset := currentDate.month % increments[incrementIndex]
				
				if monthOffset == 0
				{
					monthOffset = increments[incrementIndex]
				}
				
				currentDate.month += 1 - monthOffset
				
				for currentDate.month < 1
				{
					currentDate.year -= 1
					currentDate.month += 12
				}
				
				prevTimestamp : i32 = 0
				currentTimestamp := DayMonthYear_ToTimestamp(currentDate)
		
				for prevTimestamp < cameraEndTimestamp
				{
					append(&timestampLabels, TimestampLabel{})
					
					label := &timestampLabels[len(timestampLabels) - 1]
					
					label.color = WHITE
					
					if currentDate.month % increments[incrementIndex + 1] != 1
					{
						if incrementRequirements[incrementIndex] != incrementRequirements[incrementIndex + 1]
						{
							label.color.a = u8((1 - (f32(pixelTimestampIncrement) - f32(incrementRequirements[incrementIndex])) / (f32(incrementRequirements[incrementIndex + 1]) - f32(incrementRequirements[incrementIndex]))) * ALPHA_RANGE) + MIN_ALPHA
						}
						else
						{
							label.color.a = MAX_ALPHA							
						}
					}
					else
					{
						label.color.a = MAX_ALPHA
					}
					
					label.timestamp = currentTimestamp
					
					switch currentDate.month
					{
						case 2: label.text = fmt.bprintf(label.textBuffer[:], "Feb\x00")
						case 3: label.text = fmt.bprintf(label.textBuffer[:], "Mar\x00")
						case 4: label.text = fmt.bprintf(label.textBuffer[:], "Apr\x00")
						case 5: label.text = fmt.bprintf(label.textBuffer[:], "May\x00")
						case 6: label.text = fmt.bprintf(label.textBuffer[:], "Jun\x00")
						case 7: label.text = fmt.bprintf(label.textBuffer[:], "Jul\x00")
						case 8: label.text = fmt.bprintf(label.textBuffer[:], "Aug\x00")
						case 9: label.text = fmt.bprintf(label.textBuffer[:], "Sep\x00")
						case 10: label.text = fmt.bprintf(label.textBuffer[:], "Oct\x00")
						case 11: label.text = fmt.bprintf(label.textBuffer[:], "Nov\x00")
						case 12: label.text = fmt.bprintf(label.textBuffer[:], "Dec\x00")
						case: label.text = fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.year)
					}

					prevTimestamp = currentTimestamp
					currentDate.month += increments[incrementIndex]
					
					if currentDate.month > 12
					{
						currentDate.year += 1
						currentDate.month -= 12
					}
					
					currentTimestamp = DayMonthYear_ToTimestamp(currentDate)
				}
			}
		}
		
		// Draw Time Axis Lines
		timeAxisLineHeight := screenHeight - labelHeight 

		for label in timestampLabels
		{
			pixelX := Timestamp_ToPixelX(label.timestamp, scaleData) - cameraPosX

			DrawRectangle(pixelX, 0, 1, timeAxisLineHeight, label.color)
		}

		// Draw Candle Close Levels
		//for closeLevels in candleCloseLevels[:zoomIndex]
		//{
		//	for closeLevel in closeLevels.closeLevels
		//	{
		//		pixelY := i32(Price_ToPixelY(closeLevel.price, scaleData) - cameraPosY)

		//		if (closeLevel.endTimestamp != -1)
		//		{
		//			if (showInvalidatedCloseLevels)
		//			{
		//				DrawLine(i32(Timestamp_ToPixelX(closeLevel.startTimestamp, scaleData) - cameraPosX), pixelY, i32(Timestamp_ToPixelX(closeLevel.endTimestamp, scaleData) - cameraPosX), pixelY, closeLevels.color)
		//			}
		//		}
		//		else
		//		{
		//			DrawLine(i32(Timestamp_ToPixelX(closeLevel.startTimestamp, scaleData) - cameraPosX), pixelY, screenWidth, pixelY, closeLevels.color)
		//		}
		//	}
		//}

		// Draw HTF Candle Outlines
		zoomIndexHTF := zoomIndex + Timeframe(1)

		if zoomIndexHTF < Timeframe(TIMEFRAME_COUNT)
		{
			visibleHTFCandles, visibleHTFCandlesStartIndex := CandleList_CandlesBetweenTimestamps(candleData[zoomIndexHTF], cameraTimestamp, cameraEndTimestamp)
			for candle, i in visibleHTFCandles
			{
				xPos : i32 = CandleList_IndexToPixelX(candleData[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, scaleData) - cameraPosX
				candleWidth : i32 = CandleList_IndexToWidth(candleData[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, scaleData)

				scaledOpen : i32 = Price_ToPixelY(candle.open, scaleData)
				scaledClose : i32 = Price_ToPixelY(candle.close, scaleData)
				scaledHigh : i32 = Price_ToPixelY(candle.high, scaleData)
				scaledLow : i32 = Price_ToPixelY(candle.low, scaleData)

				if scaledClose > scaledOpen // Red
				{
					candleHeight := scaledClose - scaledOpen

					if candleHeight < 1
					{
						candleHeight = 1
					}

					DrawRectangleLines(xPos, scaledOpen - cameraPosY, candleWidth, candleHeight, Color{255, 0, 0, 63})
				}
				else // Green
				{
					candleHeight := scaledOpen - scaledClose

					if candleHeight < 1
					{
						candleHeight = 1
					}

					DrawRectangleLines(xPos, scaledClose - cameraPosY, candleWidth, candleHeight, Color{0, 255, 0, 63})
				}
			}
		}

		// Draw Candles
		for candle, i in visibleCandles
		{
			xPos : i32 = CandleList_IndexToPixelX(candleData[zoomIndex], i32(i) + visibleCandlesStartIndex, scaleData) - cameraPosX
			candleWidth : i32 = CandleList_IndexToWidth(candleData[zoomIndex], i32(i) + visibleCandlesStartIndex, scaleData)

			scaledOpen : i32 = Price_ToPixelY(candle.open, scaleData)
			scaledClose : i32 = Price_ToPixelY(candle.close, scaleData)
			scaledHigh : i32 = Price_ToPixelY(candle.high, scaleData)
			scaledLow : i32 = Price_ToPixelY(candle.low, scaleData)

			if scaledClose > scaledOpen // Red
			{
				candleHeight := scaledClose - scaledOpen

				if candleHeight < 1
				{
					candleHeight = 1
				}

				DrawRectangle(xPos, scaledOpen - cameraPosY, candleWidth, candleHeight, RED) // Body
				DrawRectangle(xPos + i32(f32(candleWidth) / 2 - 0.5), scaledHigh - cameraPosY, 1, scaledLow - scaledHigh, RED) // Wick
			}
			else // Green
			{
				candleHeight := scaledOpen - scaledClose

				if candleHeight < 1
				{
					candleHeight = 1
				}

				DrawRectangle(xPos, scaledClose - cameraPosY, candleWidth, candleHeight, GREEN) // Body
				DrawRectangle(xPos + i32(f32(candleWidth) / 2 - 0.5), scaledHigh - cameraPosY, 1, scaledLow - scaledHigh, GREEN) // Wick
			}
		}

		mouseY := GetMouseY();

		crosshairColor := WHITE
		crosshairColor.a = 127

		// Draw Crosshair
		for i : i32 = 0; i < screenWidth; i += 2
		{
			DrawPixel(i, GetMouseY(), crosshairColor)
		}

		xPos : i32 = CandleList_IndexToPixelX(candleData[zoomIndex], cursorCandleIndex, scaleData) - cameraPosX
		candleWidth : i32 = CandleList_IndexToWidth(candleData[zoomIndex], cursorCandleIndex, scaleData)

		for i : i32 = 0; i < screenHeight; i += 2
		{
			DrawPixel(xPos + i32(f32(candleWidth) / 2 - 0.5), i, crosshairColor)
		}

		text : [64]u8 = ---
		output : string = ---

		textRect : Vector2 = ---
		candleCenterOffset : f32 = ---
		labelPosX : f32 = ---
		labelPosY : f32 = ---

		// Highest Candle
		output = fmt.bprintf(text[:], "%.2f\x00", highestCandle.high)
		textRect = MeasureTextEx(font, strings.unsafe_string_to_cstring(output), FONT_SIZE, 0)
		labelPosX = f32(CandleList_IndexToPixelX(candleData[zoomIndex], highestCandleIndex, scaleData) - cameraPosX) - textRect.x / 2 + candleCenterOffset
		labelPosY = f32(Price_ToPixelY(highestCandle.high, scaleData) - cameraPosY) - textRect.y - VERTICAL_LABEL_PADDING

		if labelPosX < 2
		{
			labelPosX = 2
		}
		else if labelPosX > f32(screenWidth) - textRect.x - 2 
		{
			labelPosX = f32(screenWidth) - textRect.x - 2
		}

		candleCenterOffset = f32(CandleList_IndexToWidth(candleData[zoomIndex], highestCandleIndex, scaleData)) / 2 - 0.5
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)

		// Lowest Candle
		output = fmt.bprintf(text[:], "%.2f\x00", lowestCandle.low)
		textRect = MeasureTextEx(font, strings.unsafe_string_to_cstring(output), FONT_SIZE, 0)
		labelPosX = f32(CandleList_IndexToPixelX(candleData[zoomIndex], lowestCandleIndex, scaleData) - cameraPosX) - textRect.x / 2 + candleCenterOffset
		labelPosY = f32(Price_ToPixelY(lowestCandle.low, scaleData) - cameraPosY) + VERTICAL_LABEL_PADDING

		if labelPosX < 2
		{
			labelPosX = 2
		}
		else if labelPosX > f32(screenWidth) - textRect.x - 2 
		{
			labelPosX = f32(screenWidth) - textRect.x - 2
		}

		candleCenterOffset = f32(CandleList_IndexToWidth(candleData[zoomIndex], lowestCandleIndex, scaleData)) / 2 - 0.5
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)

		// "Downloading" text
		if !thread.is_done(downloadThread)
		{
			lastCandleIndex := i32(len(candleData[zoomIndex].candles)) - 1
			lastCandleTimestamp := CandleList_IndexToTimestamp(candleData[zoomIndex], lastCandleIndex)

			// If last candle is visible
			if lastCandleIndex == visibleCandlesStartIndex + i32(len(visibleCandles)) - 1
			{
				posX := f32(Timestamp_ToPixelX(DayMonthYear_ToTimestamp(dateToDownload), scaleData) - cameraPosX)
				posY := f32(Price_ToPixelY(candleData[zoomIndex].candles[lastCandleIndex].close, scaleData) - cameraPosY)

				output = fmt.bprint(text[:], "Downloading\x00")
				DrawTextEx(font, strings.unsafe_string_to_cstring(output), {posX, posY}, FONT_SIZE, 0, WHITE)
			}
		}

		// FPS
		output = fmt.bprintf(text[:], "%i\x00", GetFPS())
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, 0}, FONT_SIZE, 0, WHITE)

		// Zoom Index
		output = fmt.bprint(text[:], zoomIndex, "\x00")
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, FONT_SIZE}, FONT_SIZE, 0, WHITE)

		// Current Candle Price
		output = fmt.bprintf(text[:], "%.2f, %.2f, %.2f, %.2f\x00", candleData[zoomIndex].candles[cursorCandleIndex].open, candleData[zoomIndex].candles[cursorCandleIndex].high, candleData[zoomIndex].candles[cursorCandleIndex].low, candleData[zoomIndex].candles[cursorCandleIndex].close)
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, FONT_SIZE * 2}, FONT_SIZE, 0, WHITE)

		// Current Candle Price
		cursorTimestamp := CandleList_IndexToTimestamp(candleData[zoomIndex], cursorCandleIndex)
		output = fmt.bprint(text[:], Timestamp_ToDayMonthYear(cursorTimestamp).day, Timestamp_ToDayOfWeek(cursorTimestamp), "\x00")
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, FONT_SIZE * 3}, FONT_SIZE, 0, WHITE)

		labelBackground := BLACK
		labelBackground.a = 127

		// Draw Price Labels
		for label, i in priceLabels
		{
			pixelY := Price_ToPixelY(label.price, scaleData) - cameraPosY
			
			labelPosX = f32(screenWidth) - f32(label.width)
			labelPosY = f32(pixelY) - f32(labelHeight) / 2
			
			DrawRectangleRounded({labelPosX, labelPosY, f32(label.width), f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, strings.unsafe_string_to_cstring(label.text), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}
		
		// Draw Timestamp Labels
		for label, i in timestampLabels
		{
			pixelX := Timestamp_ToPixelX(label.timestamp, scaleData) - cameraPosX
			
			labelWidth := MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			labelPosX = f32(pixelX) - labelWidth / 2
			labelPosY = f32(screenHeight) - f32(labelHeight)
			
			labelColor := label.color
			labelColor.a = 255
			
			DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, strings.unsafe_string_to_cstring(label.text), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, labelColor)
		}
		
		// Draw Cursor Timestamp Label
		{
			cursorLabelBuffer : [32]u8

			cursorDayOfWeek := Timestamp_ToDayOfWeek(cursorTimestamp)
			cursorDate := Timestamp_ToDayMonthYear(cursorTimestamp)

			bufferIndex := 0
			
			if zoomIndex < .DAY
			{
				dayTimestamp := cursorTimestamp % DAY
				hours   := dayTimestamp / 3600
				minutes := dayTimestamp % 3600 / 60
				fmt.bprintf(cursorLabelBuffer[:], "%i:%2i ", hours, minutes)
				
				if hours >= 10
				{
					bufferIndex += 6
				}
				else
				{
					bufferIndex += 5
				}
			}
			
			switch cursorDayOfWeek
			{
				case .MONDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Mon ")
				case .TUESDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Tue ")
				case .WEDNESDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Wed ")
				case .THURSDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Thu ")
				case .FRIDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Fri ")
				case .SATURDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Sat ")
				case .SUNDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Sun ")
			}
			
			bufferIndex += 4

			fmt.bprintf(cursorLabelBuffer[bufferIndex:bufferIndex + 3], "%i ", cursorDate.day)
			
			if cursorDate.day >= 10
			{
				bufferIndex += 3
			}
			else
			{
				bufferIndex += 2				
			}

			// Setting label contents
			switch cursorDate.month
			{
				case 1: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Jan ")
				case 2: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Feb ")
				case 3: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Mar ")
				case 4: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Apr ")
				case 5: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "May ")
				case 6: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Jun ")
				case 7: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Jul ")
				case 8: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Aug ")
				case 9: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Sep ")
				case 10: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Oct ")
				case 11: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Nov ")
				case 12: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Dec ")
			}
			
			bufferIndex += 4
			
			fmt.bprintf(cursorLabelBuffer[bufferIndex:], "%i\x00", cursorDate.year % 100)
			
			bufferIndex += 3

			pixelX := Timestamp_ToPixelX(cursorTimestamp, scaleData) - cameraPosX

			cursorLabelString := strings.string_from_ptr(&cursorLabelBuffer[0], bufferIndex)

			labelWidth := MeasureTextEx(font, strings.unsafe_string_to_cstring(cursorLabelString), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			labelPosX = f32(pixelX) - labelWidth / 2
			labelPosY = f32(screenHeight) - f32(labelHeight)

			DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, Color{54, 58, 69, 255})
			DrawTextEx(font, strings.unsafe_string_to_cstring(cursorLabelString), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}
		
		clear(&timestampLabels)

        EndDrawing()
	}
	
	Profiler_PrintData(profilerData)
}