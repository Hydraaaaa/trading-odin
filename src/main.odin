package main

import "core:fmt"
import "core:strings"
import "core:math"
import "vendor:raylib"

INITIAL_SCREEN_WIDTH :: 1440
INITIAL_SCREEN_HEIGHT :: 720

ZOOM_INDEX_COUNT :: 10
START_ZOOM_INDEX :: CandleTimeframe.DAY

ZOOM_THRESHOLD :: 3
ZOOM_INCREMENT :: 1.05

LABEL_PADDING :: 4

FONT_SIZE :: 14

CANDLE_TIMEFRAME_INCREMENTS : [10]i32 : {60, 300, 900, 1800, 3600, 10_800, 21_600, 43_200, 86_400, 604_800}

main :: proc()
{
	using raylib
	
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
	
	candleData : [ZOOM_INDEX_COUNT]CandleTimeframeData
	candleData[CandleTimeframe.MINUTE].candles = LoadHistoricalData()
	candleData[CandleTimeframe.MINUTE].offset = BYBIT_ORIGIN_MINUTE_TIMESTAMP
	defer delete(candleData[CandleTimeframe.MINUTE].candles)
	
	candleTimeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	// Create higher timeframe candles ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	{
		prevTimeframe := CandleTimeframe.MINUTE
		
		for timeframe in CandleTimeframe.MINUTE_5 ..= CandleTimeframe.WEEK
		{
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
	}

	scaleData : ScaleData

	scaleData.zoom = 1
	scaleData.horizontalScale = f64(Candle_IndexToDuration(0, START_ZOOM_INDEX) / (ZOOM_THRESHOLD * 2))
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

		cameraPosX = i32(f64(Candle_IndexToTimestamp(i32(len(candleData[zoomIndex].candles)), zoomIndex, candleData[zoomIndex].offset) + Candle_IndexToDuration(candleIndex, zoomIndex)) / scaleData.horizontalScale - INITIAL_SCREEN_WIDTH + 70)
	}

	cameraTimestamp := i32(f64(cameraPosX) * scaleData.horizontalScale)
	cameraEndTimestamp := i32(f64(cameraPosX + INITIAL_SCREEN_WIDTH) * scaleData.horizontalScale)
	mouseTimestamp : i32

	// Slice of all candles that currently fit within the width of the screen
	visibleCandles : []Candle
	visibleCandlesStartIndex : i32
	visibleCandles, visibleCandlesStartIndex = GetVisibleCandles(candleData[zoomIndex].candles[:], zoomIndex, candleData[zoomIndex].offset, cameraPosX, screenWidth, scaleData)

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

			zoomIndex = CandleTimeframe.WEEK
			
			for int(zoomIndex) > 0 &&
			    Timestamp_ToPixelX(Candle_IndexToDuration(0, zoomIndex - CandleTimeframe(1)), scaleData) > ZOOM_THRESHOLD
			{
				zoomIndex -= CandleTimeframe(1)
			}

			// Re-add zoom post update
			cameraPosX = i32(cameraCenterX / scaleData.zoom - f64(screenWidth) / 2)
			cameraPosY = i32(cameraCenterY / scaleData.zoom - f64(screenHeight) / 2)
		}

		// Update visibleCandles
		cameraTimestamp = Timestamp_FromPixelX(cameraPosX, scaleData)
		cameraEndTimestamp = Timestamp_FromPixelX(cameraPosX + screenWidth, scaleData)
		visibleCandles, visibleCandlesStartIndex = GetVisibleCandles(candleData[zoomIndex].candles[:], zoomIndex, candleData[zoomIndex].offset, cameraPosX, screenWidth, scaleData)
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
			if Candle_IndexToTimestamp(i32(len(visibleCandles)) + visibleCandlesStartIndex - 1, zoomIndex, candleData[zoomIndex].offset) < timestamp
			{
				cursorCandleIndex = i32(len(visibleCandles)) - 1 + visibleCandlesStartIndex
			}
			else
			{
				cursorCandleIndex = Candle_TimestampToIndex(timestamp, candleData[zoomIndex], zoomIndex)
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

		labelHeight := i32(MeasureTextEx(font, "W\x00", FONT_SIZE, 0).y + LABEL_PADDING * 2)

		priceLabelSpacing : i32 = labelHeight + 6

		MINIMUM_DECIMAL :: 0.01

		if scaleData.logScale
		{
			priceIncrements : [4]f32 = {1, 2.5, 5, 10}

			topLabelPrice := Price_FromPixelY(cameraPosY - labelHeight / 2, scaleData)
			priceDifference := Price_FromPixelY(cameraPosY - labelHeight / 2 - priceLabelSpacing, scaleData) - topLabelPrice
			
			currentMagnitude : f32 = 100_000_000
			
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
			label.width = i32(MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x) + LABEL_PADDING * 2
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
				label.width = i32(MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x) + LABEL_PADDING * 2
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
				label.width = i32(MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x) + LABEL_PADDING * 2
				
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
		zoomIndexHTF := zoomIndex + CandleTimeframe(1)

		if zoomIndexHTF < CandleTimeframe(ZOOM_INDEX_COUNT - 1)
		{
			visibleHTFCandles, visibleHTFCandleStartIndex := GetVisibleCandles(candleData[zoomIndexHTF].candles[:], zoomIndexHTF, candleData[zoomIndexHTF].offset, cameraPosX, screenWidth, scaleData)
			for candle, i in visibleHTFCandles
			{
				xPos : i32 = Candle_IndexToPixelX(i32(i) + visibleHTFCandleStartIndex, zoomIndexHTF, candleData[zoomIndexHTF].offset, scaleData) - cameraPosX
				candleWidth : i32 = Timestamp_ToPixelX(Candle_IndexToDuration(i32(i) + visibleHTFCandleStartIndex, zoomIndexHTF), scaleData)

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
			xPos : i32 = Candle_IndexToPixelX(i32(i) + visibleCandlesStartIndex, zoomIndex, candleData[zoomIndex].offset, scaleData) - cameraPosX
			candleWidth : i32 = Timestamp_ToPixelX(Candle_IndexToDuration(i32(i) + visibleCandlesStartIndex, zoomIndex), scaleData)

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

		xPos : i32 = Candle_IndexToPixelX(cursorCandleIndex, zoomIndex, candleData[zoomIndex].offset, scaleData) - cameraPosX
		candleWidth : i32 = Timestamp_ToPixelX(Candle_IndexToDuration(cursorCandleIndex, zoomIndex), scaleData)

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
		labelPosX = f32(Candle_IndexToPixelX(highestCandleIndex, zoomIndex, candleData[zoomIndex].offset, scaleData) - cameraPosX) - textRect.x / 2 + candleCenterOffset
		labelPosY = f32(Price_ToPixelY(highestCandle.high, scaleData) - cameraPosY) - textRect.y - LABEL_PADDING

		if labelPosX < 2
		{
			labelPosX = 2
		}

		if labelPosX > f32(screenWidth) - textRect.x - 2 
		{
			labelPosX = f32(screenWidth) - textRect.x - 2
		}

		candleCenterOffset = f32(Timestamp_ToPixelX(Candle_IndexToDuration(highestCandleIndex, zoomIndex), scaleData)) / 2 - 0.5
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)

		// Lowest Candle
		output = fmt.bprintf(text[:], "%.2f\x00", lowestCandle.low)
		textRect = MeasureTextEx(font, strings.unsafe_string_to_cstring(output), FONT_SIZE, 0)
		labelPosX = f32(Candle_IndexToPixelX(lowestCandleIndex, zoomIndex, candleData[zoomIndex].offset, scaleData) - cameraPosX) - textRect.x / 2 + candleCenterOffset
		labelPosY = f32(Price_ToPixelY(lowestCandle.low, scaleData) - cameraPosY) + LABEL_PADDING

		if labelPosX < 2
		{
			labelPosX = 2
		}

		if labelPosX > f32(screenWidth) - textRect.x - 2 
		{
			labelPosX = f32(screenWidth) - textRect.x - 2
		}

		candleCenterOffset = f32(Timestamp_ToPixelX(Candle_IndexToDuration(lowestCandleIndex, zoomIndex), scaleData)) / 2 - 0.5
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)

		// FPS
		output = fmt.bprintf(text[:], "%i\x00", GetFPS())
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, 0}, FONT_SIZE, 0, WHITE)

		// Zoom Index
		output = fmt.bprint(text[:], zoomIndex, "\x00")
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, FONT_SIZE}, FONT_SIZE, 0, WHITE)

		// Current Candle Price
		output = fmt.bprintf(text[:], "%.2f, %.2f, %.2f, %.2f\x00", candleData[zoomIndex].candles[cursorCandleIndex].open, candleData[zoomIndex].candles[cursorCandleIndex].high, candleData[zoomIndex].candles[cursorCandleIndex].low, candleData[zoomIndex].candles[cursorCandleIndex].close)
		DrawTextEx(font, strings.unsafe_string_to_cstring(output), {0, FONT_SIZE * 2}, FONT_SIZE, 0, WHITE)

		labelBackground := BLACK
		labelBackground.a = 127

		// Draw Price Labels
		for label, i in priceLabels
		{
			pixelY := Price_ToPixelY(label.price, scaleData) - cameraPosY
			
			labelPosX = f32(screenWidth) - f32(label.width)
			labelPosY = f32(pixelY) - f32(labelHeight) / 2
			
			DrawRectangleRounded({labelPosX, labelPosY, f32(label.width), f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, strings.unsafe_string_to_cstring(label.text), {labelPosX + LABEL_PADDING, labelPosY + LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}
		
		// Draw Timestamp Labels
		for label, i in timestampLabels
		{
			pixelX := Timestamp_ToPixelX(label.timestamp, scaleData) - cameraPosX
			
			labelWidth := MeasureTextEx(font, strings.unsafe_string_to_cstring(label.text), FONT_SIZE, 0).x
			labelPosX = f32(pixelX) - labelWidth / 2
			labelPosY = f32(screenHeight) - f32(labelHeight)
			
			labelColor := label.color
			labelColor.a = 255
			
			DrawRectangleRounded({labelPosX - LABEL_PADDING, labelPosY - LABEL_PADDING, labelWidth + LABEL_PADDING * 2, labelWidth + LABEL_PADDING * 2}, 0.5, 10, labelBackground)
			DrawTextEx(font, strings.unsafe_string_to_cstring(label.text), {labelPosX, labelPosY}, FONT_SIZE, 0, labelColor)
		}
		
		clear(&timestampLabels)

        EndDrawing()
	}
}

GetVisibleCandles :: proc(candles : []Candle, timeframe : CandleTimeframe, timestampOffset : i32, cameraPosX : i32, screenWidth : i32, scaleData : ScaleData) -> ([]Candle, i32)
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	cameraEndTimestamp := Timestamp_FromPixelX(cameraPosX + screenWidth, scaleData)

	if timestampOffset > cameraEndTimestamp
	{
		// Camera is further left than the leftmost candle
		return nil, 0
	}

	cameraTimestamp := Timestamp_FromPixelX(cameraPosX + 1, scaleData) - timestampOffset
	cameraEndTimestamp -= timestampOffset

	lastCandleIndex := i32(len(candles)) - 1
	
	// Everything below months is uniform, and can be mathed
	//if timeframe == CandleTimeframe.MONTH
	//{
	//	monthlyIncrements := MONTHLY_INCREMENTS
	//	
	//	cameraCandleIndex := cameraTimestamp / monthlyIncrements[47] * 48
	//	remainingCameraTimestamp := cameraTimestamp % monthlyIncrements[47]
	//	
	//	searchIndex : i32 = 0
	//	
	//	for remainingCameraTimestamp > monthlyIncrements[searchIndex]
	//	{
	//		searchIndex += 1
	//	}
	//	
	//	cameraCandleIndex += searchIndex

	//	if i32(len(candles)) <= cameraCandleIndex
	//	{
	//		// Camera is further right than the rightmost candle
	//		return nil, 0
	//	}

	//	cameraEndCandleIndex := cameraEndTimestamp / monthlyIncrements[47] * 48
	//	remainingCameraEndTimestamp := cameraEndTimestamp % monthlyIncrements[47]
	//	
	//	searchIndex = 0

	//	for remainingCameraEndTimestamp > monthlyIncrements[searchIndex]
	//	{
	//		searchIndex += 1
	//	}
	//	
	//	cameraEndCandleIndex += searchIndex + 1

	//	if cameraCandleIndex < 0
	//	{
	//		cameraCandleIndex = 0
	//	}
	//	else if cameraCandleIndex > lastCandleIndex
	//	{
	//		cameraCandleIndex = lastCandleIndex		
	//	}
	//	
	//	if cameraEndCandleIndex < 0
	//	{
	//		cameraEndCandleIndex = 0
	//	}
	//	else if cameraEndCandleIndex > lastCandleIndex
	//	{
	//		cameraEndCandleIndex = lastCandleIndex		
	//	}

	//	return candles[cameraCandleIndex:cameraEndCandleIndex], cameraCandleIndex
	//}
	
	increment := timeframeIncrements[timeframe]

	if i32(len(candles)) * increment < cameraTimestamp
	{
		// Camera is further right than the rightmost candle
		return nil, 0
	}

	startIndex := cameraTimestamp / increment
	endIndex := cameraEndTimestamp / increment + 1
	
	if startIndex < 0
	{
		startIndex = 0
	}
	else if startIndex > lastCandleIndex
	{
		startIndex = lastCandleIndex
	}

	if endIndex < 0
	{
		endIndex = 0
	}
	else if endIndex > lastCandleIndex + 1
	{
		// +1 because slices exclude the max index
		endIndex = lastCandleIndex + 1
	}
	
	return candles[startIndex:endIndex], startIndex
}