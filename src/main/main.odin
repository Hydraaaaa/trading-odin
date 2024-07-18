package main

import "core:fmt"
import "core:strings"
import "core:math"
import "core:thread"
import "core:time"
import "core:slice"
import "vendor:raylib"

INITIAL_SCREEN_WIDTH :: 1440
INITIAL_SCREEN_HEIGHT :: 720

START_ZOOM_INDEX :: Timeframe.DAY

ZOOM_THRESHOLD :: 3
HORIZONTAL_ZOOM_INCREMENT :: 1.12
VERTICAL_ZOOM_INCREMENT :: 1.07

HORIZONTAL_LABEL_PADDING :: 3
VERTICAL_LABEL_PADDING :: HORIZONTAL_LABEL_PADDING - 2

FONT_SIZE :: 14

MouseState :: enum
{
	NONE,
	PAN,
	DRAG_HORIZONTAL,
	DRAG_VERTICAL,
	DRAG_DIAGONAL,
}

profilerData : ProfilerData
font : raylib.Font

main :: proc()
{
	using raylib

	SetConfigFlags({.WINDOW_RESIZABLE})

	SetTraceLogLevel(TraceLogLevel.WARNING)

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

	font = LoadFontEx("roboto-bold.ttf", FONT_SIZE, nil, 0)

	chart : Chart

	chart.dateToDownload = LoadDateToDownload()

	chart.candles[Timeframe.MINUTE].offset = BYBIT_ORIGIN_MINUTE_TIMESTAMP
	chart.candles[Timeframe.MINUTE].candles = LoadMinuteCandles()
	chart.candles[Timeframe.MINUTE].cumulativeDelta = LoadMinuteDelta()
	defer delete(chart.candles[Timeframe.MINUTE].candles)

	// Init chart.candles offsets and timeframes
	{
		prevTimeframe := Timeframe.MINUTE
		for timeframe in Timeframe.MINUTE_5 ..= Timeframe.WEEK
		{
			chart.candles[timeframe].offset = Candle_FloorTimestamp(chart.candles[prevTimeframe].offset, timeframe)
			chart.candles[timeframe].timeframe = timeframe

			prevTimeframe = timeframe
		}

		monthlyIncrements := MONTHLY_INCREMENTS

		fourYearTimestamp := chart.candles[prevTimeframe].offset % FOUR_YEARS

		fourYearIndex := 47

		for fourYearTimestamp < monthlyIncrements[fourYearIndex]
		{
			fourYearIndex -= 1
		}

		chart.candles[Timeframe.MONTH].offset = chart.candles[prevTimeframe].offset - fourYearTimestamp + monthlyIncrements[fourYearIndex]
		chart.candles[Timeframe.MONTH].timeframe = Timeframe.MONTH
	}

	chart.hourVolumeProfilePool = LoadHourVolumeProfiles()

	// Time is UTC, which matches Bybit's historical data upload time
	currentDate := Timestamp_ToDayMonthYear(i32(time.now()._nsec / i64(time.Second)) - TIMESTAMP_2010)

	downloadThread : ^thread.Thread
	downloadedTrades : []Trade
	downloading := false

	if len(chart.candles[Timeframe.MINUTE].candles) == 0
	{
		fmt.println("Waiting for first day's data to finish downloading before launching visual application")
		DownloadDay(&chart.dateToDownload, &downloadedTrades)
		AppendDay(&downloadedTrades, &chart)
	}
	else
	{
		Chart_CreateHTFCandles(&chart)
	}

	if chart.dateToDownload != currentDate
	{
		downloadThread = thread.create_and_start_with_poly_data2(&chart.dateToDownload, &downloadedTrades, DownloadDay)

		downloading = true
	}

	scaleData : ScaleData

	scaleData.horizontalZoom = 1
	scaleData.verticalZoom = 1
	scaleData.horizontalScale = f64(CandleList_IndexToDuration(chart.candles[START_ZOOM_INDEX], 0) / (ZOOM_THRESHOLD * 2))
	scaleData.logScale = true

	cameraPosX : i32
	cameraPosY : i32

	zoomIndex := START_ZOOM_INDEX
	zoomLevel := 0
	verticalZoomLevel : f32 = 0

	mouseState := MouseState.NONE
	mouseStateHasMoved := false
	mouseStateStartCandleIndex : i32
	mouseStateStartZoomIndex : Timeframe
	mouseStateStartPrice : f32


	rightDragging := false
	rightDraggingPriceStart : f32

	multitools : [dynamic]Multitool
	defer for multitool in multitools
	{
		Multitool_Destroy(multitool)
	}

	selectedMultitool : ^Multitool
	selectedMultitoolIndex : int

	hoveredMultitool : ^Multitool
	hoveredMultitoolIndex : int

	dailyCloseLevels := CandleCloseLevels_Create(chart.candles[Timeframe.DAY], SKYBLUE)
	defer CandleCloseLevels_Destroy(dailyCloseLevels)

	weeklyCloseLevels := CandleCloseLevels_Create(chart.candles[Timeframe.WEEK], YELLOW)
	defer CandleCloseLevels_Destroy(weeklyCloseLevels)

	drawCVD := true
	drawDayOfWeek := false
	drawSessions := true
	drawHTFOutlines := true
	drawCloseLevels := false
	drawPreviousDayVolumeProfiles := true
	drawPreviousWeekVolumeProfiles := false

	// Set initial camera X position to show the most recent candle on the right
	{
		candleIndex := i32(len(chart.candles[zoomIndex].candles) - 1)

		cameraPosX = i32(f64(CandleList_IndexToTimestamp(chart.candles[zoomIndex], i32(len(chart.candles[zoomIndex].candles))) + CandleList_IndexToDuration(chart.candles[zoomIndex], candleIndex)) / scaleData.horizontalScale - INITIAL_SCREEN_WIDTH + 70)
	}

	cameraTimestamp := i32(f64(cameraPosX) * scaleData.horizontalScale)
	cameraEndTimestamp := i32(f64(cameraPosX + INITIAL_SCREEN_WIDTH) * scaleData.horizontalScale)
	mouseTimestamp : i32

	// Slice of all candles that currently fit within the width of the screen
	visibleCandles : []Candle
	visibleCandlesStartIndex : i32
	visibleCandles, visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(chart.candles[zoomIndex], cameraTimestamp, cameraEndTimestamp)

	highestCandle, highestCandleIndex := Candle_HighestHigh(visibleCandles)
	lowestCandle, lowestCandleIndex := Candle_LowestLow(visibleCandles)

	highestCandleIndex += visibleCandlesStartIndex
	lowestCandleIndex += visibleCandlesStartIndex
	cursorCandleIndex : i32
	cursorCandle : Candle
	isCursorSnapped := false
	cursorSnapPrice : f32

	initialVerticalScale : f64

	// Set initial vertical scale to fit all initially visible candles on screen
	{
		low : f32 = 10000000
		high : f32 = 0

		for candle in visibleCandles
		{
			low = math.min(low, candle.low)
			high = math.max(high, candle.high)
		}

		middle : f32 = (math.log10(high) + math.log10(low)) / 2

		initialVerticalScale = f64(math.log10(high) - math.log10(low)) / (INITIAL_SCREEN_HEIGHT - 64)

		cameraPosY = i32(-(f64(middle) / initialVerticalScale) - INITIAL_SCREEN_HEIGHT / 2)
	}

	scaleData.verticalScale = initialVerticalScale

	cameraTopPrice : f32 = Price_FromPixelY(cameraPosY, scaleData)
	cameraBottomPrice : f32 = Price_FromPixelY(cameraPosY + screenHeight, scaleData)

	reserve(&chart.dailyVolumeProfiles, len(chart.candles[Timeframe.DAY].candles) + 7)
	resize(&chart.dailyVolumeProfiles, len(chart.candles[Timeframe.DAY].candles))
	reserve(&chart.weeklyVolumeProfiles, len(chart.candles[Timeframe.WEEK].candles) + 1)
	resize(&chart.weeklyVolumeProfiles, len(chart.candles[Timeframe.WEEK].candles))

	defer for i in 0 ..< len(chart.dailyVolumeProfiles)
	{
		if chart.dailyVolumeProfiles[i].bucketSize != 0
		{
			VolumeProfile_Destroy(chart.dailyVolumeProfiles[i])
		}
	}

	defer for i in 0 ..< len(chart.weeklyVolumeProfiles)
	{
		if chart.weeklyVolumeProfiles[i].bucketSize != 0
		{
			VolumeProfile_Destroy(chart.weeklyVolumeProfiles[i])
		}
	}

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

		hoveredHandle := MultitoolHandle.NONE

		if selectedMultitool != nil
		{
			hoveredHandle = Multitool_HandleAt(selectedMultitool^, GetMouseX() + cameraPosX, GetMouseY() + cameraPosY, scaleData)
		}
	
		// TODO: Hover least recently selected multitool when multiple are hovered
		hoveredMultitool = nil
		hoveredMultitoolIndex = -1

		if hoveredHandle == .NONE
		{
			// Reverse order to match visual order
			for i := len(multitools) - 1; i >= 0; i -= 1
			{
				if Multitool_IsOverlapping(multitools[i], GetMouseX() + cameraPosX, GetMouseY() + cameraPosY, scaleData)
				{
					hoveredMultitool = &multitools[i]
					hoveredMultitoolIndex = i
					break
				}
			}
		}

		hoverCursors := [16]MouseCursor \
		{
			.DEFAULT,
			.RESIZE_NWSE,
			.RESIZE_NS,
			.RESIZE_NESW,
			.RESIZE_EW,
			.RESIZE_EW,
			.RESIZE_NESW,
			.RESIZE_NS,
			.RESIZE_NWSE,
			.POINTING_HAND,
			.POINTING_HAND,
			.POINTING_HAND,
			.POINTING_HAND,
			.POINTING_HAND,
			.POINTING_HAND,
			.POINTING_HAND,
		}

		cursor := hoverCursors[hoveredHandle]

		if hoveredMultitool != nil && (mouseState == .NONE || !mouseStateHasMoved)
		{
			cursor = .POINTING_HAND
		}

		if IsMouseButtonPressed(.LEFT)
		{
			mouseStateHasMoved = false

			mouseStateStartCandleIndex = cursorCandleIndex
			mouseStateStartZoomIndex = zoomIndex
			mouseStateStartPrice = cursorSnapPrice

			if !IsKeyDown(.LEFT_SHIFT)
			{
				#partial switch hoveredHandle
				{
					case .EDGE_TOPLEFT:
					{
						mouseState = .DRAG_DIAGONAL
						mouseStateStartPrice = selectedMultitool.low
						mouseStateStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.endTimestamp)
						mouseStateStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseStateStartZoomIndex], selectedMultitool.endTimestamp)
					}
					case .EDGE_TOPRIGHT:
					{
						mouseState = .DRAG_DIAGONAL
						mouseStateStartPrice = selectedMultitool.low
						mouseStateStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.startTimestamp)
						mouseStateStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseStateStartZoomIndex], selectedMultitool.startTimestamp)
					}
					case .EDGE_BOTTOMLEFT:
					{
						mouseState = .DRAG_DIAGONAL
						mouseStateStartPrice = selectedMultitool.high
						mouseStateStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.endTimestamp)
						mouseStateStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseStateStartZoomIndex], selectedMultitool.endTimestamp)
					}
					case .EDGE_BOTTOMRIGHT:
					{
						mouseState = .DRAG_DIAGONAL
						mouseStateStartPrice = selectedMultitool.high
						mouseStateStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.startTimestamp)
						mouseStateStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseStateStartZoomIndex], selectedMultitool.startTimestamp)
					}
					case .EDGE_TOP:
					{
						mouseState = .DRAG_VERTICAL
						mouseStateStartPrice = selectedMultitool.low
					}
					case .EDGE_LEFT:
					{
						mouseState = .DRAG_HORIZONTAL
						mouseStateStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.endTimestamp)
						mouseStateStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseStateStartZoomIndex], selectedMultitool.endTimestamp)
					}
					case .EDGE_RIGHT:
					{
						mouseState = .DRAG_HORIZONTAL
						mouseStateStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.startTimestamp)
						mouseStateStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseStateStartZoomIndex], selectedMultitool.startTimestamp)
					}
					case .EDGE_BOTTOM:
					{
						mouseState = .DRAG_VERTICAL
						mouseStateStartPrice = selectedMultitool.high
					}
					case: mouseState = .PAN
				}
			}
			else
			{
				mouseState = .DRAG_DIAGONAL
				append(&multitools, Multitool{})

				if selectedMultitool != nil &&
				   selectedMultitool.tools == nil
				{
					unordered_remove(&multitools, selectedMultitoolIndex)
				}
				
				selectedMultitool = &multitools[len(multitools) - 1]
				selectedMultitoolIndex = len(multitools) - 1

				selectedMultitool.tools = {.VOLUME_PROFILE}
				selectedMultitool.volumeProfileDrawFlags = {.BODY, .POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP}

				newStartTimestamp : i32
				newEndTimestamp : i32

				if CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex) > CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
				{
					newStartTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
					newEndTimestamp = CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex + 1)
				}
				else
				{
					newStartTimestamp = CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex)
					newEndTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex + 1)
				}

				minZoomIndex := math.min(zoomIndex, mouseStateStartZoomIndex)

				startIndex := CandleList_TimestampToIndex(chart.candles[minZoomIndex], newStartTimestamp)
				endIndex := CandleList_TimestampToIndex(chart.candles[minZoomIndex], newEndTimestamp)

				selectedMultitool.volumeProfile = VolumeProfile_Create(newStartTimestamp, newEndTimestamp, chart, 25)

				selectedMultitool.startTimestamp = newStartTimestamp
				selectedMultitool.endTimestamp = newEndTimestamp
				selectedMultitool.high = math.max(mouseStateStartPrice, cursorSnapPrice)
				selectedMultitool.low = math.min(mouseStateStartPrice, cursorSnapPrice)
				selectedMultitool.isUpsideDown = mouseStateStartPrice < cursorSnapPrice
			}
		}

		if IsMouseButtonReleased(.LEFT)
		{
			if mouseState == .PAN && !mouseStateHasMoved
			{
				#partial switch hoveredHandle
				{
					case .POC: selectedMultitool.volumeProfileDrawFlags ~= {.POC}
					case .VAL: selectedMultitool.volumeProfileDrawFlags ~= {.VAL}
					case .VAH: selectedMultitool.volumeProfileDrawFlags ~= {.VAH}
					case .TV_VAL: selectedMultitool.volumeProfileDrawFlags ~= {.TV_VAL}
					case .TV_VAH: selectedMultitool.volumeProfileDrawFlags ~= {.TV_VAH}
					case .VWAP: selectedMultitool.volumeProfileDrawFlags ~= {.VWAP}
					case .NONE:
					{
						if selectedMultitool != nil &&
						   selectedMultitool.tools == nil
						{
							unordered_remove(&multitools, selectedMultitoolIndex)
						}
				
						selectedMultitool = hoveredMultitool
						selectedMultitoolIndex = hoveredMultitoolIndex
					}
				}
			}

			mouseState = .NONE
			mouseStateHasMoved = false
		}

		cursorDelta := GetMouseDelta()

		#partial switch mouseState
		{
			// An XOR to determine which of the two diagonal cursors to display
			case .DRAG_DIAGONAL: cursor = .RESIZE_NESW - MouseCursor((cursorCandleIndex > mouseStateStartCandleIndex) != (cursorSnapPrice > mouseStateStartPrice))

			case .DRAG_HORIZONTAL: cursor = .RESIZE_EW
			case .DRAG_VERTICAL: cursor = .RESIZE_NS
		}

		if cursorDelta.x != 0 ||
		   cursorDelta.y != 0
		{
			mouseStateHasMoved = true

			#partial switch mouseState
			{
				case .PAN:
				{
					mouseStateHasMoved = true

					cameraPosX -= i32(cursorDelta.x)
					cameraPosY -= i32(cursorDelta.y)
				}
				case .DRAG_DIAGONAL:
				{
					newStartTimestamp : i32
					newEndTimestamp : i32

					if CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex) > CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
					{
						newStartTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
						newEndTimestamp = CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex + 1)
					}
					else
					{
						newStartTimestamp = CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex)
						newEndTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex + 1)
					}

					minZoomIndex := math.min(zoomIndex, mouseStateStartZoomIndex)

					startIndex := CandleList_TimestampToIndex(chart.candles[minZoomIndex], newStartTimestamp)
					endIndex := CandleList_TimestampToIndex(chart.candles[minZoomIndex], newEndTimestamp)

					VolumeProfile_Resize(&selectedMultitool.volumeProfile, selectedMultitool.startTimestamp, selectedMultitool.endTimestamp, newStartTimestamp, newEndTimestamp, chart)

					selectedMultitool.startTimestamp = newStartTimestamp
					selectedMultitool.endTimestamp = newEndTimestamp
					selectedMultitool.high = math.max(mouseStateStartPrice, cursorSnapPrice)
					selectedMultitool.low = math.min(mouseStateStartPrice, cursorSnapPrice)
					selectedMultitool.isUpsideDown = mouseStateStartPrice < cursorSnapPrice
				}
				case .DRAG_HORIZONTAL:
				{
					newStartTimestamp : i32
					newEndTimestamp : i32

					if CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex) > CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
					{
						newStartTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
						newEndTimestamp = CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex + 1)
					}
					else
					{
						newStartTimestamp = CandleList_IndexToTimestamp(chart.candles[mouseStateStartZoomIndex], mouseStateStartCandleIndex)
						newEndTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex + 1)
					}

					minZoomIndex := math.min(zoomIndex, mouseStateStartZoomIndex)

					startIndex := CandleList_TimestampToIndex(chart.candles[minZoomIndex], newStartTimestamp)
					endIndex := CandleList_TimestampToIndex(chart.candles[minZoomIndex], newEndTimestamp)

					VolumeProfile_Resize(&selectedMultitool.volumeProfile, selectedMultitool.startTimestamp, selectedMultitool.endTimestamp, newStartTimestamp, newEndTimestamp, chart)

					selectedMultitool.startTimestamp = newStartTimestamp
					selectedMultitool.endTimestamp = newEndTimestamp
				}
				case .DRAG_VERTICAL:
				{
					selectedMultitool.high = math.max(mouseStateStartPrice, cursorSnapPrice)
					selectedMultitool.low = math.min(mouseStateStartPrice, cursorSnapPrice)
					selectedMultitool.isUpsideDown = mouseStateStartPrice < cursorSnapPrice
				}
			}
		}

		SetMouseCursor(cursor)

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

		if IsKeyPressed(.T) &&
		   selectedMultitool != nil
		{
			Calculate(chart, selectedMultitool, dailyCloseLevels.levels[:], 1.01, 1.01)
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
			cameraCenterX : f64 = (f64(cameraPosX) + f64(screenWidth) / 2) * scaleData.horizontalZoom
			cameraCenterY : f64 = (f64(cameraPosY) + f64(screenHeight) / 2) * scaleData.verticalZoom

			scaleData.horizontalZoom = 1
			scaleData.verticalZoom = 1

			i := zoomLevel

			for i > 0
			{
				scaleData.horizontalZoom *= HORIZONTAL_ZOOM_INCREMENT
				scaleData.verticalZoom *= VERTICAL_ZOOM_INCREMENT
				i -= 1
			}

			for i < 0
			{
				scaleData.horizontalZoom /= HORIZONTAL_ZOOM_INCREMENT
				scaleData.verticalZoom /= VERTICAL_ZOOM_INCREMENT
				i += 1
			}

			zoomIndex = Timeframe(TIMEFRAME_COUNT - 1)

			for int(zoomIndex) > 0 &&
			    CandleList_IndexToWidth(chart.candles[zoomIndex - Timeframe(1)], 0, scaleData) > ZOOM_THRESHOLD
			{
				zoomIndex -= Timeframe(1)
			}

			// Re-add zoom post update
			cameraPosX = i32(cameraCenterX / scaleData.horizontalZoom - f64(screenWidth) / 2)
			cameraPosY = i32(cameraCenterY / scaleData.verticalZoom - f64(screenHeight) / 2)
		}

		// Check download thread
		if downloading
		{
			if thread.is_done(downloadThread)
			{
				thread.destroy(downloadThread)

				// 404 Not Found
				if downloadedTrades == nil
				{
					downloading = false
				}
				else
				{
					AppendDay(&downloadedTrades, &chart)
					if chart.dateToDownload != currentDate
					{
						downloadThread = thread.create_and_start_with_poly_data2(&chart.dateToDownload, &downloadedTrades, DownloadDay)
					}
					else
					{
						downloading = false
					}
				}
			}
		}

		// Update visibleCandles
		cameraTimestamp = Timestamp_FromPixelX(cameraPosX, scaleData)
		cameraEndTimestamp = Timestamp_FromPixelX(cameraPosX + screenWidth, scaleData)
		visibleCandles, visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(chart.candles[zoomIndex], cameraTimestamp, cameraEndTimestamp)
		highestCandle, highestCandleIndex = Candle_HighestHigh(visibleCandles)
		lowestCandle, lowestCandleIndex = Candle_LowestLow(visibleCandles)

		highestCandleIndex += visibleCandlesStartIndex
		lowestCandleIndex += visibleCandlesStartIndex

		cameraTopPrice = Price_FromPixelY(cameraPosY, scaleData)
		cameraBottomPrice = Price_FromPixelY(cameraPosY + screenHeight, scaleData)

		// If the last candle is before the start of the viewport
		// Update candle under cursor
		{
			// We add one pixel to the cursor's position, as all of the candles' timestamps get rounded down when converted
			// As we are doing the opposite conversion, the mouse will always be less than or equal to the candles
			timestamp : i32 = Timestamp_FromPixelX(GetMouseX() + cameraPosX + 1, scaleData)

			cursorCandleIndex = CandleList_TimestampToIndex(chart.candles[zoomIndex], timestamp)
			cursorCandleIndex = math.min(cursorCandleIndex, i32(len(visibleCandles)) - 1 + visibleCandlesStartIndex)
			cursorCandleIndex = math.max(cursorCandleIndex, 0)
			cursorCandle = chart.candles[zoomIndex].candles[cursorCandleIndex]
		}

		if IsKeyPressed(.L)
		{
			priceUpper : f32 = 0
			priceLower : f32 = 10000000

			// Rescale Candles
			for candle in visibleCandles
			{
				priceUpper = math.max(priceUpper, candle.high)
				priceLower = math.min(priceLower, candle.low)
			}

			priceUpper = math.min(priceUpper, cameraTopPrice)
			priceLower = math.max(priceLower, cameraBottomPrice)

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

		if IsKeyPressed(.DELETE) &&
		   selectedMultitool != nil
		{
			unordered_remove(&multitools, selectedMultitoolIndex)

			selectedMultitool = nil
			selectedMultitoolIndex = -1
		}

		if IsKeyPressed(.C) { drawCVD = !drawCVD }
		if IsKeyPressed(.M) { drawDayOfWeek = !drawDayOfWeek }
		if IsKeyPressed(.S) { drawSessions = !drawSessions }
		if IsKeyPressed(.Q) { drawCloseLevels = !drawCloseLevels }
		if IsKeyPressed(.D) { drawPreviousDayVolumeProfiles = !drawPreviousDayVolumeProfiles }
		if IsKeyPressed(.W) { drawPreviousWeekVolumeProfiles = !drawPreviousWeekVolumeProfiles }
		if IsKeyPressed(.H) { drawHTFOutlines = !drawHTFOutlines }

		// Snap cursor to nearest OHLC value
		{
			SNAP_PIXELS :: 32

			mouseY := GetMouseY()

			high := Price_ToPixelY(cursorCandle.high, scaleData) - cameraPosY
			low := Price_ToPixelY(cursorCandle.low, scaleData) - cameraPosY

			midHighPrice := math.max(cursorCandle.open, cursorCandle.close)
			midLowPrice := math.min(cursorCandle.open, cursorCandle.close)
			midHigh := Price_ToPixelY(midHighPrice, scaleData) - cameraPosY
			midLow := Price_ToPixelY(midLowPrice, scaleData) - cameraPosY

			highestSnap := high - SNAP_PIXELS
			lowestSnap := low + SNAP_PIXELS

			if mouseY >= highestSnap &&
			   mouseY <= lowestSnap
			{
				// Midpoints (in pixels)
				highMidHigh := (high + midHigh) / 2
				midHighMidLow := (midHigh + midLow) / 2
				midLowLow := (midLow + low) / 2

				if mouseY < highMidHigh
				{
					mouseY = high
					cursorSnapPrice = cursorCandle.high
				}
				else if mouseY < midHighMidLow
				{
					mouseY = midHigh
					cursorSnapPrice = midHighPrice
				}
				else if mouseY < midLowLow
				{
					mouseY = midLow
					cursorSnapPrice = midLowPrice
				}
				else
				{
					mouseY = low
					cursorSnapPrice = cursorCandle.low
				}

				isCursorSnapped = true
			}
			else
			{
				cursorSnapPrice = Price_FromPixelY(mouseY + cameraPosY, scaleData)
			}
		}

		// Rendering ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

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
			textBuffer : [32]u8, // Much larger buffer than timestamp labels, as log scale can balloon the prices, and memecoins, if ever implemented, use huge decimals
			width : i32,
			color : Color,
		}

		// These are the only four linear scale increments, once these are exhausted, the values are multiplied by 10 and recycled
		priceLabels : [dynamic]PriceLabel
		reserve(&priceLabels, 32)

		labelHeight := i32(MeasureTextEx(font, "W\x00", FONT_SIZE, 0).y + VERTICAL_LABEL_PADDING * 2)

		priceLabelSpacing : i32 = labelHeight + 6

		MIN_DECIMAL :: 0.01
		MAX_PRICE_DIFFERENCE : f32 : 1_000_000_000

		if scaleData.logScale
		{
			priceIncrements : [4]f32 = {1, 2.5, 5, 10}

			topLabelPrice := Price_FromPixelY(cameraPosY - labelHeight / 2, scaleData)
			priceDifference := math.min(Price_FromPixelY(cameraPosY - labelHeight / 2 - priceLabelSpacing, scaleData) - topLabelPrice, MAX_PRICE_DIFFERENCE)

			currentMagnitude := MAX_PRICE_DIFFERENCE

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
			fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
			label.width = i32(MeasureTextEx(font, cstring(&label.textBuffer[0]), FONT_SIZE, 0).x) + HORIZONTAL_LABEL_PADDING * 2
			label.color = Color{255, 255, 255, MAX_ALPHA}

			prevPrice := topLabelPrice
			prevPixel := Price_ToPixelY(prevPrice, scaleData)

			for prevPixel < cameraPosY + screenHeight
			{
				currentPrice := Price_FromPixelY(prevPixel + priceLabelSpacing, scaleData)
				priceDifference = prevPrice - currentPrice

				// Price_FromPixelY can sometimes return +inf, which crashes the program without this break
				if currentPrice > MAX_PRICE_DIFFERENCE
				{
					break
				}

				for currentMagnitude > priceDifference
				{
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
				fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
				label.width = i32(MeasureTextEx(font, cstring(&label.textBuffer[0]), FONT_SIZE, 0).x) + HORIZONTAL_LABEL_PADDING * 2
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

			priceLabelSpacing = i32(f32(priceLabelSpacing) / MIN_DECIMAL)

			pixelPriceIncrement : f32 = abs(Price_ToPixelY_f32(1, scaleData) - Price_ToPixelY_f32(0, scaleData))

			// Will need to reference a minimum size value in the scenario of memecoins or alt pairs with BTC
			priceIncrementMultiplier : i32 = 1
			priceIncrementIndex := 0

			// Can we math this out?
			for i32(pixelPriceIncrement * f32(priceIncrementMultiplier) * slice.last(priceIncrements[:])) < priceLabelSpacing
			{
				priceIncrementMultiplier *= 10
			}

			for i32(pixelPriceIncrement * f32(priceIncrementMultiplier) * priceIncrements[priceIncrementIndex]) < priceLabelSpacing
			{
				priceIncrementIndex += 1
			}

			priceIncrement := i32(f32(priceIncrementMultiplier) * priceIncrements[priceIncrementIndex])

			screenTopPrice := i32(Price_FromPixelY(cameraPosY, scaleData) / MIN_DECIMAL)
			screenBottomPrice := i32(Price_FromPixelY(cameraPosY + screenHeight, scaleData) / MIN_DECIMAL)

			// Round to the nearest increment (which lies above the screen border)
			currentPrice := screenTopPrice + priceIncrement - screenTopPrice % priceIncrement
			lastPrice := i32(screenBottomPrice - priceIncrement)

			for currentPrice > lastPrice
			{
				append(&priceLabels, PriceLabel{})
				label := &priceLabels[len(priceLabels) - 1]

				label.price = f32(currentPrice) / 100
				fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
				label.width = i32(MeasureTextEx(font, cstring(&label.textBuffer[0]), FONT_SIZE, 0).x) + HORIZONTAL_LABEL_PADDING * 2

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
								case 2: fmt.bprintf(label.textBuffer[:], "Feb\x00")
								case 3: fmt.bprintf(label.textBuffer[:], "Mar\x00")
								case 4: fmt.bprintf(label.textBuffer[:], "Apr\x00")
								case 5: fmt.bprintf(label.textBuffer[:], "May\x00")
								case 6: fmt.bprintf(label.textBuffer[:], "Jun\x00")
								case 7: fmt.bprintf(label.textBuffer[:], "Jul\x00")
								case 8: fmt.bprintf(label.textBuffer[:], "Aug\x00")
								case 9: fmt.bprintf(label.textBuffer[:], "Sep\x00")
								case 10: fmt.bprintf(label.textBuffer[:], "Oct\x00")
								case 11: fmt.bprintf(label.textBuffer[:], "Nov\x00")
								case 12: fmt.bprintf(label.textBuffer[:], "Dec\x00")
								case: fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.year)
							}
						}
						else
						{
							fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.day)
						}
					}
					else
					{
						hours   := dayTimestamp / 3600
						minutes := dayTimestamp % 3600 / 60
						fmt.bprintf(label.textBuffer[:], "%i:%2i", hours, minutes)
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
						case 2: fmt.bprintf(label.textBuffer[:], "Feb\x00")
						case 3: fmt.bprintf(label.textBuffer[:], "Mar\x00")
						case 4: fmt.bprintf(label.textBuffer[:], "Apr\x00")
						case 5: fmt.bprintf(label.textBuffer[:], "May\x00")
						case 6: fmt.bprintf(label.textBuffer[:], "Jun\x00")
						case 7: fmt.bprintf(label.textBuffer[:], "Jul\x00")
						case 8: fmt.bprintf(label.textBuffer[:], "Aug\x00")
						case 9: fmt.bprintf(label.textBuffer[:], "Sep\x00")
						case 10: fmt.bprintf(label.textBuffer[:], "Oct\x00")
						case 11: fmt.bprintf(label.textBuffer[:], "Nov\x00")
						case 12: fmt.bprintf(label.textBuffer[:], "Dec\x00")
						case: fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.year)
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
		if drawCloseLevels
		{
			levelsSlice := []CandleCloseLevels{dailyCloseLevels}

			for closeLevels in levelsSlice
			{
				for level in closeLevels.levels
				{
					pixelY := i32(Price_ToPixelY(level.price, scaleData) - cameraPosY)

					// endX := endTimestamp == -1 ? screenWidth : endTimestamp
					endX := screenWidth * i32(level.endTimestamp == -1) + i32(Timestamp_ToPixelX(level.endTimestamp, scaleData) - cameraPosX) * i32(level.endTimestamp != -1)

					DrawLine(i32(Timestamp_ToPixelX(level.startTimestamp, scaleData) - cameraPosX), pixelY, endX, pixelY, closeLevels.color)
				}
			}
		}

		// Draw days of week
		if drawDayOfWeek &&
		   zoomIndex <= .DAY
		{
			// Convert current visible indices into visible day indices
			startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex))
			endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(len(visibleCandles))))

			for i in startIndex ..< endIndex
			{
				startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i), scaleData)
				endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 1, scaleData)

				colors := [7]Color{RED, GREEN, YELLOW, PURPLE, BLUE, GRAY, WHITE}
				colors[0].a = 31; colors[1].a = 31; colors[2].a = 31; colors[3].a = 31; colors[4].a = 31; colors[5].a = 31; colors[6].a = 31;

				dayOfWeek := Timestamp_ToDayOfWeek(CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i)))

				DrawRectangle(startPixel - cameraPosX, 0, endPixel - startPixel, screenHeight, colors[dayOfWeek])
			}
		}

		// Draw sessions
		if drawSessions &&
		   zoomIndex <= .MINUTE_30
		{
			// Convert current visible indices to visible day indices - 1
			startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex))
			endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(len(visibleCandles)))) + 1

			asia := RED
			asia.a = 31
			london := YELLOW
			london.a = 31
			newYork := BLUE
			newYork.a = 31

			for i in startIndex ..< endIndex
			{
				startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
				asiaStart := Timestamp_ToPixelX(startTimestamp, scaleData)
				asiaLength := Timestamp_ToPixelX(1800 * 16, scaleData)
				londonStart := asiaStart + asiaLength
				londonLength := Timestamp_ToPixelX(1800 * 16, scaleData)
				newYorkStart := Timestamp_ToPixelX(startTimestamp + 1800 * 27, scaleData)
				newYorkLength := Timestamp_ToPixelX(1800 * 13, scaleData)
				endTimestamp := startTimestamp + 10800

				DrawRectangle(asiaStart - cameraPosX, 0, asiaLength, screenHeight, asia)
				DrawRectangle(londonStart - cameraPosX, 0, londonLength, screenHeight, london)
				DrawRectangle(newYorkStart - cameraPosX, 0, newYorkLength, screenHeight, newYork)
			}
		}


		// Draw HTF Candle Outlines
		if drawHTFOutlines
		{
			zoomIndexHTF := zoomIndex + Timeframe(1)

			if zoomIndexHTF < Timeframe(TIMEFRAME_COUNT)
			{
				visibleHTFCandles, visibleHTFCandlesStartIndex := CandleList_CandlesBetweenTimestamps(chart.candles[zoomIndexHTF], cameraTimestamp, cameraEndTimestamp)

				outlineColors := [2]Color{{0, 255, 0, 63}, {255, 0, 0, 63}}

				for candle, i in visibleHTFCandles
				{
					xPos := CandleList_IndexToPixelX(chart.candles[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, scaleData) - cameraPosX
					candleWidth := CandleList_IndexToWidth(chart.candles[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, scaleData)

					bodyPosY := Price_ToPixelY(math.max(candle.open, candle.close), scaleData)
					bodyHeight:= math.max(Price_ToPixelY(math.min(candle.open, candle.close), scaleData) - bodyPosY, 1)

					DrawRectangleLines(xPos, bodyPosY - cameraPosY, candleWidth, bodyHeight, outlineColors[int(candle.close <= candle.open)])
				}
			}
		}

		// [0] = green, [1] = red
		candleColors := [2]Color{{0, 255, 0, 255}, {255, 0, 0, 255}}

		// Draw Candles
		for candle, i in visibleCandles
		{
			xPos := CandleList_IndexToPixelX(chart.candles[zoomIndex], i32(i) + visibleCandlesStartIndex, scaleData) - cameraPosX
			candleWidth := CandleList_IndexToWidth(chart.candles[zoomIndex], i32(i) + visibleCandlesStartIndex, scaleData)

			bodyPosY := Price_ToPixelY(math.max(candle.open, candle.close), scaleData)
			bodyHeight:= math.max(Price_ToPixelY(math.min(candle.open, candle.close), scaleData) - bodyPosY, 1)

			wickPosY := Price_ToPixelY(candle.high, scaleData)
			wickHeight:= Price_ToPixelY(candle.low, scaleData) - wickPosY

			DrawRectangle(xPos, bodyPosY - cameraPosY, candleWidth, bodyHeight, candleColors[int(candle.close <= candle.open)]) // Body
			DrawRectangle(xPos + i32(f32(candleWidth) / 2 - 0.5), wickPosY - cameraPosY, 1, wickHeight, candleColors[int(candle.close <= candle.open)]) // Wick
		}

		// Draw previous week volume profiles
		if drawPreviousWeekVolumeProfiles &&
		   zoomIndex <= .DAY
		{
			// Convert current visible indices to visible week indices - 1
			startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.WEEK], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex)) - 1
			endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.WEEK], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(len(visibleCandles))))

			for i in startIndex ..< endIndex
			{
				startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i))
				endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i) + 1)
				if chart.weeklyVolumeProfiles[i].bucketSize == 0
				{
					startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i))
					endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i) + 1)
					weekCandle := chart.candles[Timeframe.WEEK].candles[i]
					chart.weeklyVolumeProfiles[i] = VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
				}

				startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.WEEK], i32(i) + 1, scaleData)
				endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.WEEK], i32(i) + 2, scaleData)

				VolumeProfile_Draw(chart.weeklyVolumeProfiles[i], startPixel - cameraPosX, endPixel - startPixel, cameraPosY, scaleData, 95, {.POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
			}
		}

		// Draw previous day volume profiles
		if drawPreviousDayVolumeProfiles &&
		   zoomIndex <= .HOUR
		{
			// Convert current visible indices to visible day indices - 1
			startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex)) - 1
			endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(len(visibleCandles))))

			for i in startIndex ..< endIndex
			{
				startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
				endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i) + 1)

				// bucketSize is 0 if a profile hasn't been loaded yet
				if chart.dailyVolumeProfiles[i].bucketSize == 0
				{
					startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
					endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i) + 1)
					dayCandle := chart.candles[Timeframe.DAY].candles[i]
					chart.dailyVolumeProfiles[i] = VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
				}

				startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 1, scaleData)
				endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 2, scaleData)

				VolumeProfile_Draw(chart.dailyVolumeProfiles[i], startPixel - cameraPosX, endPixel - startPixel, cameraPosY, scaleData, 63, {.POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
			}
		}

		// Draw CVD
		if drawCVD
		{
			highestCloseCandle, _ := Candle_HighestClose(visibleCandles)
			lowestCloseCandle, _ := Candle_LowestClose(visibleCandles)

			highestClose := math.min(highestCloseCandle.close, cameraTopPrice)
			lowestClose := math.max(lowestCloseCandle.close, cameraBottomPrice)

			visibleDeltas := chart.candles[zoomIndex].cumulativeDelta[visibleCandlesStartIndex:visibleCandlesStartIndex + i32(len(visibleCandles))]

			highestPixel := Price_ToPixelY_f32(highestClose, scaleData) - f32(cameraPosY)
			lowestPixel := Price_ToPixelY_f32(lowestClose, scaleData) - f32(cameraPosY)
			pixelRange := highestPixel - lowestPixel

			highestDelta := visibleDeltas[0]
			lowestDelta := visibleDeltas[0]

			for delta in visibleDeltas[1:]
			{
				highestDelta = math.max(highestDelta, delta)
				lowestDelta = math.min(lowestDelta, delta)
			}

			cvdDeltaRange := highestDelta - lowestDelta

			highestCandleY := Price_ToPixelY(highestClose, scaleData) - cameraPosY
			lowestCandleY := Price_ToPixelY(lowestClose, scaleData) - cameraPosY

			prevX := CandleList_IndexToPixelX(chart.candles[zoomIndex], visibleCandlesStartIndex + 1, scaleData) - cameraPosX
			prevY := i32(f32((visibleDeltas[0] - lowestDelta) / cvdDeltaRange) * pixelRange + lowestPixel)

			for delta, i in visibleDeltas[1:]
			{
				x := CandleList_IndexToPixelX(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(i) + 2, scaleData) - cameraPosX
				y := i32(f32((delta - lowestDelta) / cvdDeltaRange) * pixelRange + lowestPixel)

				DrawLine(prevX, prevY, x, y, Color{255, 255, 255, 191})

				prevX = x
				prevY = y
			}
		}

		for multitool in multitools
		{
			Multitool_Draw(multitool, cameraPosX, cameraPosY, scaleData)
		}

		if hoveredMultitool != nil
		{
			posX := Timestamp_ToPixelX(hoveredMultitool.startTimestamp, scaleData)
			posY := Price_ToPixelY(hoveredMultitool.high, scaleData)
			width := Timestamp_ToPixelX(hoveredMultitool.endTimestamp, scaleData) - posX
			height := Price_ToPixelY(hoveredMultitool.low, scaleData) - posY
			DrawRectangleLines(posX - cameraPosX, posY - cameraPosY, width, height, {255, 255, 255, 127})
		}

		if selectedMultitool != nil
		{
			Multitool_DrawHandles(selectedMultitool^, cameraPosX, cameraPosY, scaleData)
		}

		// Draw Crosshair
		{
			mouseY := GetMouseY()

			crosshairColor := WHITE
			crosshairColor.a = 127

			for i : i32 = 0; i < screenWidth; i += 3
			{
				DrawPixel(i, mouseY, crosshairColor)
			}

			xPos : i32 = CandleList_IndexToPixelX(chart.candles[zoomIndex], cursorCandleIndex, scaleData) - cameraPosX
			candleWidth : i32 = CandleList_IndexToWidth(chart.candles[zoomIndex], cursorCandleIndex, scaleData)

			for i : i32 = 0; i < screenHeight; i += 3
			{
				DrawPixel(xPos + i32(f32(candleWidth) / 2 - 0.5), i, crosshairColor)
			}
		}

		// Draw current price line
		lastCandle := slice.last(chart.candles[zoomIndex].candles[:])
		priceY := Price_ToPixelY(lastCandle.close, scaleData) - cameraPosY - i32(lastCandle.close < lastCandle.open)
		priceColor := candleColors[int(lastCandle.close < lastCandle.open)]

		for i : i32 = 0; i < screenWidth; i += 3
		{
			DrawPixel(i, priceY, priceColor)
		}

		textBuffer : [64]u8 = ---

		textRect : Vector2 = ---
		candleCenterOffset : f32 = ---
		labelPosX : f32 = ---
		labelPosY : f32 = ---

		// Highest Candle
		if cursorCandleIndex != highestCandleIndex ||
		   cursorSnapPrice != highestCandle.high
	    {
			fmt.bprintf(textBuffer[:], "%.2f\x00", highestCandle.high)
			textRect = MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
			labelPosX = f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], highestCandleIndex, scaleData) - cameraPosX) - textRect.x / 2 + candleCenterOffset
			labelPosY = f32(Price_ToPixelY(highestCandle.high, scaleData) - cameraPosY) - textRect.y - VERTICAL_LABEL_PADDING

			labelPosX = math.clamp(labelPosX, 2, f32(screenWidth) - textRect.x - 2)

			candleCenterOffset = f32(CandleList_IndexToWidth(chart.candles[zoomIndex], highestCandleIndex, scaleData)) / 2 - 0.5
			DrawTextEx(font, cstring(&textBuffer[0]), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)
	    }

		// Lowest Candle
		if cursorCandleIndex != lowestCandleIndex ||
		   cursorSnapPrice != lowestCandle.low
	    {
			fmt.bprintf(textBuffer[:], "%.2f\x00", lowestCandle.low)
			textRect = MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
			labelPosX = f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], lowestCandleIndex, scaleData) - cameraPosX) - textRect.x / 2 + candleCenterOffset
			labelPosY = f32(Price_ToPixelY(lowestCandle.low, scaleData) - cameraPosY) + VERTICAL_LABEL_PADDING

			labelPosX = math.clamp(labelPosX, 2, f32(screenWidth) - textRect.x - 2)

			candleCenterOffset = f32(CandleList_IndexToWidth(chart.candles[zoomIndex], lowestCandleIndex, scaleData)) / 2 - 0.5
			DrawTextEx(font, cstring(&textBuffer[0]), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)
		}

		// "Downloading" text
		if downloading
		{
			lastCandleIndex := i32(len(chart.candles[zoomIndex].candles)) - 1
			lastCandleTimestamp := CandleList_IndexToTimestamp(chart.candles[zoomIndex], lastCandleIndex)

			// If last candle is visible
			if lastCandleIndex == visibleCandlesStartIndex + i32(len(visibleCandles)) - 1
			{
				posX := f32(Timestamp_ToPixelX(DayMonthYear_ToTimestamp(chart.dateToDownload), scaleData) - cameraPosX) + 2
				posY := f32(Price_ToPixelY(chart.candles[zoomIndex].candles[lastCandleIndex].close, scaleData) - cameraPosY) - MeasureTextEx(font, "W\x00", FONT_SIZE, 0).y / 2
				fmt.bprint(textBuffer[:], "Downloading\x00")
				DrawTextEx(font, cstring(&textBuffer[0]), {posX, posY}, FONT_SIZE, 0, WHITE)
			}
		}

		// Hovered price label
		labelBackground := BLACK
		labelBackground.a = 127

		if isCursorSnapped
		{
			fmt.bprintf(textBuffer[:], "%.2f\x00", cursorSnapPrice)

			width := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2

			posX := f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], cursorCandleIndex, scaleData) - cameraPosX) - width
			posY := f32(Price_ToPixelY(cursorSnapPrice, scaleData) - cameraPosY) - f32(labelHeight) / 2

			if posX + HORIZONTAL_LABEL_PADDING < 0
			{
				posX += width + f32(CandleList_IndexToWidth(chart.candles[zoomIndex], cursorCandleIndex, scaleData))
			}

			DrawRectangleRounded({posX, posY, width, f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, cstring(&textBuffer[0]), {posX + HORIZONTAL_LABEL_PADDING, posY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}
		else
		{
			fmt.bprintf(textBuffer[:], "%.2f\x00", Price_FromPixelY(GetMouseY() + cameraPosY, scaleData))

			width := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2

			posX := f32(GetMouseX()) - width
			posY := f32(GetMouseY()) - f32(labelHeight) / 2

			if posX + HORIZONTAL_LABEL_PADDING < 0
			{
				posX += width + f32(GetMouseX())
			}

			DrawRectangleRounded({posX, posY, width, f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, cstring(&textBuffer[0]), {posX + HORIZONTAL_LABEL_PADDING, posY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}

		// FPS
		fmt.bprintf(textBuffer[:], "%i\x00", GetFPS())
		DrawTextEx(font, cstring(&textBuffer[0]), {0, 0}, FONT_SIZE, 0, WHITE)

		// Zoom Index
		fmt.bprint(textBuffer[:], zoomIndex, "\x00")
		DrawTextEx(font, cstring(&textBuffer[0]), {0, FONT_SIZE}, FONT_SIZE, 0, WHITE)

		// Draw Price Labels
		for i in 0 ..< len(priceLabels)
		{
			pixelY := Price_ToPixelY(priceLabels[i].price, scaleData) - cameraPosY

			labelPosX = f32(screenWidth) - f32(priceLabels[i].width)
			labelPosY = f32(pixelY) - f32(labelHeight) / 2

			DrawRectangleRounded({labelPosX, labelPosY, f32(priceLabels[i].width), f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, cstring(&priceLabels[i].textBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}

		// Draw current price label
		{
			fmt.bprintf(textBuffer[:], "%.2f\x00", lastCandle.close)

			labelWidth := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			labelPosX = f32(screenWidth) - labelWidth
			labelPosY = f32(priceY) - f32(labelHeight) / 2

			DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, priceColor)
			DrawTextEx(font, cstring(&textBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}

		// Draw Timestamp Labels
		for i in 0 ..< len(timestampLabels)
		{
			pixelX := Timestamp_ToPixelX(timestampLabels[i].timestamp, scaleData) - cameraPosX

			labelWidth := MeasureTextEx(font, cstring(&timestampLabels[i].textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			labelPosX = f32(pixelX) - labelWidth / 2
			labelPosY = f32(screenHeight) - f32(labelHeight)

			labelColor := timestampLabels[i].color
			labelColor.a = 255

			DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, cstring(&timestampLabels[i].textBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, labelColor)
		}

		// Draw Cursor Timestamp Label
		{
			cursorTimestamp := CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)

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

			labelWidth := MeasureTextEx(font, cstring(&cursorLabelBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			labelPosX = f32(pixelX) - labelWidth / 2
			labelPosY = f32(screenHeight) - f32(labelHeight)

			DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, Color{54, 58, 69, 255})
			DrawTextEx(font, cstring(&cursorLabelBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}

		clear(&timestampLabels)

        EndDrawing()
	}

	Profiler_PrintData(profilerData)
}
