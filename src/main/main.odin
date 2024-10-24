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

profilerData : ProfilerData

font : raylib.Font
labelHeight : f32

volumeProfileIcon : raylib.Texture2D
fibRetracementIcon : raylib.Texture2D

main :: proc()
{
	using raylib

	SetConfigFlags({.WINDOW_RESIZABLE})

	SetTraceLogLevel(TraceLogLevel.WARNING)

	InitWindow(INITIAL_SCREEN_WIDTH, INITIAL_SCREEN_HEIGHT, "Trading"); defer CloseWindow()

	icon := LoadImage("icon.png"); defer UnloadImage(icon)

	SetWindowIcon(icon)

	screenWidth : f32 = INITIAL_SCREEN_WIDTH
	screenHeight : f32 = INITIAL_SCREEN_HEIGHT

	windowedScreenWidth : f32 = 0
	windowedScreenHeight : f32 = 0

    SetTargetFPS(60)

	font = LoadFontEx("roboto-bold.ttf", FONT_SIZE, nil, 0); defer UnloadFont(font)
	labelHeight = MeasureTextEx(font, "W\x00", FONT_SIZE, 0).y + VERTICAL_LABEL_PADDING * 2

	volumeProfileIcon = LoadTexture("volumeProfileIcon.png"); defer UnloadTexture(volumeProfileIcon)
	fibRetracementIcon = LoadTexture("fibRetracementIcon.png"); defer UnloadTexture(fibRetracementIcon)

	chart : Chart

	chart.dateToDownload = LoadDateToDownload()

	chart.candles[Timeframe.MINUTE].offset = BYBIT_ORIGIN_MINUTE_TIMESTAMP
	chart.candles[Timeframe.MINUTE].candles = LoadMinuteCandles(); defer delete(chart.candles[Timeframe.MINUTE].candles)
	chart.candles[Timeframe.MINUTE].cumulativeDelta = LoadMinuteDelta(); defer delete(chart.candles[Timeframe.MINUTE].cumulativeDelta)

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

	cameraX : f32
	cameraY : f32

	zoomIndex := START_ZOOM_INDEX
	zoomLevel := 0
	verticalZoomLevel : f32 = 0

	selectedHandle := MultitoolHandle.NONE
	hasMouseMovedSelection := false
	mouseSelectionStartTimestamp : i32
	mouseSelectionStartCandleIndex : i32
	mouseSelectionStartZoomIndex : Timeframe
	mouseSelectionStartPrice : f32

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

		cameraX = f32(f64(CandleList_IndexToTimestamp(chart.candles[zoomIndex], i32(len(chart.candles[zoomIndex].candles))) + CandleList_IndexToDuration(chart.candles[zoomIndex], candleIndex)) / scaleData.horizontalScale - INITIAL_SCREEN_WIDTH + 70)
	}

	cameraTimestamp := i32(f64(cameraX) * scaleData.horizontalScale)
	cameraEndTimestamp := i32(f64(cameraX + INITIAL_SCREEN_WIDTH) * scaleData.horizontalScale)

	// Slice of all candles that currently fit within the width of the screen
	visibleCandles : []Candle
	visibleCandlesStartIndex : i32
	visibleCandles, visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(chart.candles[zoomIndex], cameraTimestamp, cameraEndTimestamp)

	highestCandle, highestCandleIndex := Candle_HighestHigh(visibleCandles)
	lowestCandle, lowestCandleIndex := Candle_LowestLow(visibleCandles)

	highestCandleIndex += visibleCandlesStartIndex
	lowestCandleIndex += visibleCandlesStartIndex
	cursorTimestamp : i32
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

		cameraY = f32(-(f64(middle) / initialVerticalScale) - INITIAL_SCREEN_HEIGHT / 2)
	}

	scaleData.verticalScale = initialVerticalScale

	cameraTopPrice : f32 = Price_FromPixelY(cameraY, scaleData)
	cameraBottomPrice : f32 = Price_FromPixelY(cameraY + screenHeight, scaleData)

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

			cameraX -= f32(newScreenWidth) - screenWidth

			cameraPrice : f32 = Price_FromPixelY(cameraY + screenHeight / 2, scaleData)

			initialVerticalScale *= f64(screenHeight) / f64(newScreenHeight)
			scaleData.verticalScale *= f64(screenHeight) / f64(newScreenHeight)

			screenWidth = f32(newScreenWidth)
			screenHeight = f32(newScreenHeight)

			cameraY = Price_ToPixelY(cameraPrice, scaleData) - screenHeight / 2
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
				SetWindowSize(i32(windowedScreenWidth), i32(windowedScreenHeight))
			}
		}
		
		// Update candle under cursor
		{
			// We add one pixel to the cursor's position, as all of the candles' timestamps get rounded down when converted
			// As we are doing the opposite conversion, the mouse will always be less than or equal to the candles
			cursorTimestamp = Timestamp_FromPixelX(f32(GetMouseX()) + cameraX + 1, scaleData)
			cursorCandleIndex = CandleList_TimestampToIndex_Clamped(chart.candles[zoomIndex], cursorTimestamp)
			cursorCandle = chart.candles[zoomIndex].candles[cursorCandleIndex]
		}

		hoveredHandle := MultitoolHandle.NONE

		if selectedMultitool != nil
		{
			hoveredHandle = Multitool_HandleAt(selectedMultitool^, f32(GetMouseX()), f32(GetMouseY()), cameraX, cameraY, scaleData)
		}
	
		// TODO: Hover least recently selected multitool when multiple are hovered
		hoveredMultitool = nil
		hoveredMultitoolIndex = -1

		if hoveredHandle == .NONE
		{
			// Reverse order to match visual order
			for i := len(multitools) - 1; i >= 0; i -= 1
			{
				if Multitool_IsOverlapping(multitools[i], f32(GetMouseX()) + cameraX, f32(GetMouseY()) + cameraY, scaleData)
				{
					hoveredMultitool = &multitools[i]
					hoveredMultitoolIndex = i
					break
				}
			}
		}

		cursor : MouseCursor = ---
		
		#partial switch(hoveredHandle)
		{
			case .EDGE_TOPLEFT, .EDGE_BOTTOMRIGHT: cursor = .RESIZE_NWSE
			case .EDGE_TOP, .EDGE_BOTTOM:          cursor = .RESIZE_NS
			case .EDGE_TOPRIGHT, .EDGE_BOTTOMLEFT: cursor = .RESIZE_NESW
			case .EDGE_LEFT, .EDGE_RIGHT:          cursor = .RESIZE_EW
				
			case .NONE: cursor = .DEFAULT
			case: cursor = .POINTING_HAND
		}

		if hoveredMultitool != nil && !hasMouseMovedSelection
		{
			cursor = .POINTING_HAND
		}

		if IsMouseButtonPressed(.LEFT) &&
		   hoveredHandle != .HOTBAR_VOLUME_PROFILE &&
		   hoveredHandle != .HOTBAR_FIB_RETRACEMENT
		{
			hasMouseMovedSelection = false

			mouseSelectionStartTimestamp = cursorTimestamp
			mouseSelectionStartCandleIndex = cursorCandleIndex
			mouseSelectionStartZoomIndex = zoomIndex
			mouseSelectionStartPrice = cursorSnapPrice

			if !IsKeyDown(.LEFT_SHIFT)
			{
				selectedHandle = hoveredHandle
				
				#partial switch selectedHandle
				{
					case .EDGE_TOPLEFT:
					{
						mouseSelectionStartPrice = selectedMultitool.low
						mouseSelectionStartTimestamp = selectedMultitool.endTimestamp
						mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.endTimestamp)
						mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseSelectionStartZoomIndex], selectedMultitool.endTimestamp) - 1
					}
					case .EDGE_TOPRIGHT:
					{
						mouseSelectionStartPrice = selectedMultitool.low
						mouseSelectionStartTimestamp = selectedMultitool.startTimestamp
						mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.startTimestamp)
						mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseSelectionStartZoomIndex], selectedMultitool.startTimestamp)
					}
					case .EDGE_BOTTOMLEFT:
					{
						mouseSelectionStartPrice = selectedMultitool.high
						mouseSelectionStartTimestamp = selectedMultitool.endTimestamp
						mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.endTimestamp)
						mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseSelectionStartZoomIndex], selectedMultitool.endTimestamp) - 1
					}
					case .EDGE_BOTTOMRIGHT:
					{
						mouseSelectionStartPrice = selectedMultitool.high
						mouseSelectionStartTimestamp = selectedMultitool.startTimestamp
						mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.startTimestamp)
						mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseSelectionStartZoomIndex], selectedMultitool.startTimestamp)
					}
					case .EDGE_TOP:
					{
						mouseSelectionStartPrice = selectedMultitool.low
					}
					case .EDGE_LEFT:
					{
						mouseSelectionStartTimestamp = selectedMultitool.endTimestamp
						mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.endTimestamp)
						mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseSelectionStartZoomIndex], selectedMultitool.endTimestamp) - 1
					}
					case .EDGE_RIGHT:
					{
						mouseSelectionStartTimestamp = selectedMultitool.startTimestamp
						mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, selectedMultitool.startTimestamp)
						mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[mouseSelectionStartZoomIndex], selectedMultitool.startTimestamp)
					}
					case .EDGE_BOTTOM:
					{
						mouseSelectionStartPrice = selectedMultitool.high
					}
				}
			}
			else
			{
				mouseSelectionStartTimestamp = CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
				selectedHandle = .EDGE_TOPRIGHT

				if selectedMultitool != nil &&
				   selectedMultitool.tools == nil
				{
					unordered_remove(&multitools, selectedMultitoolIndex)
				}
				
				append(&multitools, Multitool{})
				selectedMultitool = &multitools[len(multitools) - 1]
				selectedMultitoolIndex = len(multitools) - 1

				selectedMultitool.startTimestamp = mouseSelectionStartTimestamp
				selectedMultitool.endTimestamp = mouseSelectionStartTimestamp + CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
				selectedMultitool.high = cursorSnapPrice
				selectedMultitool.low = cursorSnapPrice
				selectedMultitool.isUpsideDown = false
				
				selectedMultitool.tools = nil
				
				selectedMultitool.volumeProfile = VolumeProfile_Create(selectedMultitool.startTimestamp, selectedMultitool.endTimestamp, chart, 25)
				selectedMultitool.volumeProfileDrawFlags = {.BODY, .POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP}
				
				selectedMultitool.draw618 = true
			}
		}

		if IsMouseButtonReleased(.LEFT)
		{
			if !hasMouseMovedSelection
			{
				#partial switch hoveredHandle
				{
					case .POC: selectedMultitool.volumeProfileDrawFlags ~= {.POC}
					case .VAL: selectedMultitool.volumeProfileDrawFlags ~= {.VAL}
					case .VAH: selectedMultitool.volumeProfileDrawFlags ~= {.VAH}
					case .TV_VAL: selectedMultitool.volumeProfileDrawFlags ~= {.TV_VAL}
					case .TV_VAH: selectedMultitool.volumeProfileDrawFlags ~= {.TV_VAH}
					case .VWAP: selectedMultitool.volumeProfileDrawFlags ~= {.VWAP}
					case .VOLUME_PROFILE_BODY: selectedMultitool.volumeProfileDrawFlags ~= {.BODY}
					case .FIB_618: selectedMultitool.draw618 = !selectedMultitool.draw618
					case .HOTBAR_VOLUME_PROFILE:
					{
						if IsKeyDown(.LEFT_SHIFT)
						{
							selectedMultitool.tools ~= {.VOLUME_PROFILE}
						}
						else
						{
							selectedMultitool.tools = {.VOLUME_PROFILE}
						}
					}
					case .HOTBAR_FIB_RETRACEMENT:
					{
						if IsKeyDown(.LEFT_SHIFT)
						{
							selectedMultitool.tools ~= {.FIB_RETRACEMENT}
						}
						else
						{
							selectedMultitool.tools = {.FIB_RETRACEMENT}
						}
					}
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

			selectedHandle = .NONE
			hasMouseMovedSelection = false
		}

		mouseDelta := GetMouseDelta()

		#partial switch selectedHandle
		{
			case .EDGE_TOPRIGHT, .EDGE_BOTTOMLEFT: cursor = .RESIZE_NESW
			case .EDGE_TOPLEFT, .EDGE_BOTTOMRIGHT: cursor = .RESIZE_NWSE
			case .EDGE_LEFT, .EDGE_RIGHT: cursor = .RESIZE_EW
			case .EDGE_TOP, .EDGE_BOTTOM: cursor = .RESIZE_NS
		}

		if IsMouseButtonDown(.LEFT) &&
		   (mouseDelta.x != 0 ||
		    mouseDelta.y != 0)
		{
			hasMouseMovedSelection = true

			#partial switch selectedHandle
			{
				case .EDGE_TOPLEFT, .EDGE_TOPRIGHT, .EDGE_BOTTOMLEFT, .EDGE_BOTTOMRIGHT:
				{
					cursorCandleTimestamp := CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
					newStartTimestamp : i32 = ---
					newEndTimestamp : i32 = ---

					if cursorCandleTimestamp >= mouseSelectionStartTimestamp
					{
						#partial switch selectedHandle
						{
							case .EDGE_TOPLEFT: selectedHandle = .EDGE_TOPRIGHT; mouseSelectionStartTimestamp -= CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
							case .EDGE_BOTTOMLEFT: selectedHandle = .EDGE_BOTTOMRIGHT; mouseSelectionStartTimestamp -= CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex);
						}
						
						newStartTimestamp = mouseSelectionStartTimestamp
						newEndTimestamp = cursorCandleTimestamp + CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
					}
					else
					{
						#partial switch selectedHandle
						{
							case .EDGE_TOPRIGHT: selectedHandle = .EDGE_TOPLEFT; mouseSelectionStartTimestamp += CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
							case .EDGE_BOTTOMRIGHT: selectedHandle = .EDGE_BOTTOMLEFT; mouseSelectionStartTimestamp += CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
						}
						
						newStartTimestamp = cursorCandleTimestamp
						newEndTimestamp = mouseSelectionStartTimestamp
					}

					// Check for flipping of coordinates
					isBottomEdge := selectedHandle == .EDGE_BOTTOMLEFT || selectedHandle == .EDGE_BOTTOMRIGHT

					if (mouseSelectionStartPrice < cursorSnapPrice) == isBottomEdge
					{
						selectedMultitool.isUpsideDown = !selectedMultitool.isUpsideDown
						#partial switch selectedHandle
						{
							case .EDGE_BOTTOMLEFT: selectedHandle = .EDGE_TOPLEFT
							case .EDGE_BOTTOMRIGHT: selectedHandle = .EDGE_TOPRIGHT
							case .EDGE_TOPLEFT: selectedHandle = .EDGE_BOTTOMLEFT
							case .EDGE_TOPRIGHT: selectedHandle = .EDGE_BOTTOMRIGHT
						}
					}
					
					VolumeProfile_Resize(&selectedMultitool.volumeProfile, selectedMultitool.startTimestamp, selectedMultitool.endTimestamp, newStartTimestamp, newEndTimestamp, chart)

					selectedMultitool.startTimestamp = newStartTimestamp
					selectedMultitool.endTimestamp = newEndTimestamp
					selectedMultitool.high = math.max(mouseSelectionStartPrice, cursorSnapPrice)
					selectedMultitool.low = math.min(mouseSelectionStartPrice, cursorSnapPrice)
				}
				case .EDGE_LEFT, .EDGE_RIGHT:
				{
					cursorCandleTimestamp := CandleList_IndexToTimestamp(chart.candles[zoomIndex], cursorCandleIndex)
					newStartTimestamp : i32 = ---
					newEndTimestamp : i32 = ---

					if cursorCandleTimestamp >= mouseSelectionStartTimestamp
					{
						if selectedHandle == .EDGE_LEFT
						{
							selectedHandle = .EDGE_RIGHT
							mouseSelectionStartTimestamp -= CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
						}
						
						newStartTimestamp = mouseSelectionStartTimestamp
						newEndTimestamp = cursorCandleTimestamp + CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
					}
					else
					{
						if selectedHandle == .EDGE_RIGHT
						{
							selectedHandle = .EDGE_LEFT
							mouseSelectionStartTimestamp += CandleList_IndexToDuration(chart.candles[zoomIndex], cursorCandleIndex)
						}
						
						newStartTimestamp = cursorCandleTimestamp
						newEndTimestamp = mouseSelectionStartTimestamp
					}

					VolumeProfile_Resize(&selectedMultitool.volumeProfile, selectedMultitool.startTimestamp, selectedMultitool.endTimestamp, newStartTimestamp, newEndTimestamp, chart)

					selectedMultitool.startTimestamp = newStartTimestamp
					selectedMultitool.endTimestamp = newEndTimestamp
				}
				case .EDGE_TOP, .EDGE_BOTTOM:
				{
					selectedMultitool.high = math.max(mouseSelectionStartPrice, cursorSnapPrice)
					selectedMultitool.low = math.min(mouseSelectionStartPrice, cursorSnapPrice)
					
					// Check for a flipping of coordinates
					if mouseSelectionStartPrice < cursorSnapPrice &&
					   selectedHandle == .EDGE_BOTTOM
					{
						selectedMultitool.isUpsideDown = false
						selectedHandle = .EDGE_TOP
					}
					else if mouseSelectionStartPrice > cursorSnapPrice &&
					        selectedHandle == .EDGE_TOP
					{
						selectedMultitool.isUpsideDown = true
						selectedHandle = .EDGE_BOTTOM
					}
				}
				case:
				{
					hasMouseMovedSelection = true

					cameraX -= mouseDelta.x
					cameraY -= mouseDelta.y
				}
			}
		}

		SetMouseCursor(cursor)

		// Vertical Scale Adjustment
		if IsMouseButtonPressed(.RIGHT)
		{
			rightDragging = true
			rightDraggingPriceStart = Price_FromPixelY(cameraY + screenHeight / 2, scaleData)
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

			cameraY = Price_ToPixelY(rightDraggingPriceStart, scaleData) - screenHeight / 2
		}

		// Zooming
		if GetMouseWheelMove() != 0
		{
			zoomLevel -= int(GetMouseWheelMove())

			// Remove zoom from screen space as we adjust it
			cameraCenterX : f64 = (f64(cameraX) + f64(screenWidth) / 2) * scaleData.horizontalZoom
			cameraCenterY : f64 = (f64(cameraY) + f64(screenHeight) / 2) * scaleData.verticalZoom

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
			cameraX = f32(cameraCenterX / scaleData.horizontalZoom - f64(screenWidth) / 2)
			cameraY = f32(cameraCenterY / scaleData.verticalZoom - f64(screenHeight) / 2)
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
		cameraTimestamp = Timestamp_FromPixelX(cameraX, scaleData)
		cameraEndTimestamp = Timestamp_FromPixelX(cameraX + screenWidth, scaleData)
		visibleCandles, visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(chart.candles[zoomIndex], cameraTimestamp, cameraEndTimestamp)
		highestCandle, highestCandleIndex = Candle_HighestHigh(visibleCandles)
		lowestCandle, lowestCandleIndex = Candle_LowestLow(visibleCandles)

		highestCandleIndex += visibleCandlesStartIndex
		lowestCandleIndex += visibleCandlesStartIndex

		cameraTopPrice = Price_FromPixelY(cameraY, scaleData)
		cameraBottomPrice = Price_FromPixelY(cameraY + screenHeight, scaleData)

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

			prePixelUpper : f32 = Price_ToPixelY(priceUpper, scaleData)
			prePixelLower : f32 = Price_ToPixelY(priceLower, scaleData)

			pixelOffset : f32 = prePixelUpper - cameraY

			scaleData.logScale = !scaleData.logScale

			postPixelUpper : f32 = Price_ToPixelY(priceUpper, scaleData)
			postPixelLower : f32 = Price_ToPixelY(priceLower, scaleData)

			difference : f64 = f64(postPixelLower - postPixelUpper) / f64(prePixelLower - prePixelUpper)

			initialVerticalScale *= difference
			scaleData.verticalScale *= difference

			cameraY = Price_ToPixelY(priceUpper, scaleData) - pixelOffset
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

			mouseY := f32(GetMouseY())

			high := Price_ToPixelY(cursorCandle.high, scaleData) - cameraY
			low := Price_ToPixelY(cursorCandle.low, scaleData) - cameraY

			midHighPrice := math.max(cursorCandle.open, cursorCandle.close)
			midLowPrice := math.min(cursorCandle.open, cursorCandle.close)
			midHigh := Price_ToPixelY(midHighPrice, scaleData) - cameraY
			midLow := Price_ToPixelY(midLowPrice, scaleData) - cameraY

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
				cursorSnapPrice = Price_FromPixelY(mouseY + cameraY, scaleData)
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
			width : f32,
			color : Color,
		}

		// These are the only four linear scale increments, once these are exhausted, the values are multiplied by 10 and recycled
		priceLabels : [dynamic]PriceLabel
		reserve(&priceLabels, 32)

		priceLabelSpacing : f32 = labelHeight + 6

		MIN_DECIMAL :: 0.01
		MAX_PRICE_DIFFERENCE : f32 : 1_000_000_000

		if scaleData.logScale
		{
			priceIncrements : [4]f32 = {1, 2.5, 5, 10}

			topLabelPrice := Price_FromPixelY(cameraY - labelHeight / 2, scaleData)
			priceDifference := math.min(Price_FromPixelY(cameraY - labelHeight / 2 - priceLabelSpacing, scaleData) - topLabelPrice, MAX_PRICE_DIFFERENCE)

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
			label.width = MeasureTextEx(font, cstring(&label.textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			label.color = Color{255, 255, 255, MAX_ALPHA}

			prevPrice := topLabelPrice
			prevPixel := Price_ToPixelY(prevPrice, scaleData)

			for prevPixel < cameraY + screenHeight
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
				label.width = MeasureTextEx(font, cstring(&label.textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
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

			priceLabelSpacing /= MIN_DECIMAL

			pixelPriceIncrement := abs(Price_ToPixelY(1, scaleData) - Price_ToPixelY(0, scaleData))

			// Will need to reference a minimum size value in the scenario of memecoins or alt pairs with BTC
			priceIncrementMultiplier : f32 = 1
			priceIncrementIndex := 0

			// Can we math this out?
			for pixelPriceIncrement * priceIncrementMultiplier * slice.last(priceIncrements[:]) < priceLabelSpacing
			{
				priceIncrementMultiplier *= 10
			}

			for pixelPriceIncrement * priceIncrementMultiplier * priceIncrements[priceIncrementIndex] < priceLabelSpacing
			{
				priceIncrementIndex += 1
			}

			priceIncrement := i32(priceIncrementMultiplier * priceIncrements[priceIncrementIndex])

			screenTopPrice := i32(Price_FromPixelY(cameraY, scaleData) / MIN_DECIMAL)
			screenBottomPrice := i32(Price_FromPixelY(cameraY + screenHeight, scaleData) / MIN_DECIMAL)

			// Round to the nearest increment (which lies above the screen border)
			currentPrice := screenTopPrice + priceIncrement - screenTopPrice % priceIncrement
			lastPrice := i32(screenBottomPrice - priceIncrement)

			for currentPrice > lastPrice
			{
				append(&priceLabels, PriceLabel{})
				label := &priceLabels[len(priceLabels) - 1]

				label.price = f32(currentPrice) / 100
				fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
				label.width = MeasureTextEx(font, cstring(&label.textBuffer[0]), FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2

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
			pixelY := Price_ToPixelY(label.price, scaleData) - cameraY

			DrawRectangleRec(Rectangle{0, pixelY, screenWidth - label.width, 1}, label.color)
		}

		// Generate timestamp labels
		// Draw lines before candles are drawn
		// Draw labels after candles are drawn
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
			pixelX := Timestamp_ToPixelX(label.timestamp, scaleData) - cameraX

			DrawRectangleRec(Rectangle{pixelX, 0, 1, timeAxisLineHeight}, label.color)
		}

		// Draw Candle Close Levels
		if drawCloseLevels
		{
			levelsSlice := []CandleCloseLevels{dailyCloseLevels}

			for closeLevels in levelsSlice
			{
				for level in closeLevels.levels
				{
					pixelY := Price_ToPixelY(level.price, scaleData) - cameraY

					// endX := endTimestamp == -1 ? screenWidth : endTimestamp
					endX := screenWidth * f32(i32(level.endTimestamp == -1)) + Timestamp_ToPixelX(level.endTimestamp, scaleData) - cameraX * f32(i32(level.endTimestamp != -1))

					DrawLineV(Vector2{Timestamp_ToPixelX(level.startTimestamp, scaleData) - cameraX, pixelY}, Vector2{endX, pixelY}, closeLevels.color)
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

				DrawRectangleRec(Rectangle{startPixel - cameraX, 0, endPixel - startPixel, screenHeight}, colors[dayOfWeek])
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

				DrawRectangleRec(Rectangle{asiaStart - cameraX, 0, asiaLength, screenHeight}, asia)
				DrawRectangleRec(Rectangle{londonStart - cameraX, 0, londonLength, screenHeight}, london)
				DrawRectangleRec(Rectangle{newYorkStart - cameraX, 0, newYorkLength, screenHeight}, newYork)
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
					xPos := CandleList_IndexToPixelX(chart.candles[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, scaleData) - cameraX
					candleWidth := CandleList_IndexToWidth(chart.candles[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, scaleData)

					bodyPosY := Price_ToPixelY(math.max(candle.open, candle.close), scaleData)
					bodyHeight := math.max(Price_ToPixelY(math.min(candle.open, candle.close), scaleData) - bodyPosY, 1)

					DrawRectangleLinesEx(Rectangle{xPos, bodyPosY - cameraY, candleWidth, bodyHeight}, 1, outlineColors[int(candle.close <= candle.open)])
				}
			}
		}

		// [0] = green, [1] = red
		candleColors := [2]Color{{0, 255, 0, 255}, {255, 0, 0, 255}}

		// Draw Candles
		for candle, i in visibleCandles
		{
			xPos := CandleList_IndexToPixelX(chart.candles[zoomIndex], i32(i) + visibleCandlesStartIndex, scaleData) - cameraX
			candleWidth := CandleList_IndexToWidth(chart.candles[zoomIndex], i32(i) + visibleCandlesStartIndex, scaleData)

			bodyPosY := Price_ToPixelY(math.max(candle.open, candle.close), scaleData)
			bodyHeight := math.max(Price_ToPixelY(math.min(candle.open, candle.close), scaleData) - bodyPosY, 1)

			wickPosY := Price_ToPixelY(candle.high, scaleData)
			wickHeight := Price_ToPixelY(candle.low, scaleData) - wickPosY

			DrawRectangleRec(Rectangle{xPos, bodyPosY - cameraY, candleWidth, bodyHeight}, candleColors[int(candle.close <= candle.open)]) // Body
			DrawRectangleRec(Rectangle{xPos + f32(candleWidth) / 2 - 0.5, wickPosY - cameraY, 1, wickHeight}, candleColors[int(candle.close <= candle.open)]) // Wick
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
				if chart.weeklyVolumeProfiles[i].bucketSize == 0
				{
					startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i))
					endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i) + 1)
					chart.weeklyVolumeProfiles[i] = VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
				}

				startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.WEEK], i32(i) + 1, scaleData)
				endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.WEEK], i32(i) + 2, scaleData)

				VolumeProfile_Draw(chart.weeklyVolumeProfiles[i], startPixel - cameraX, endPixel - startPixel, cameraY, scaleData, 95, {.POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
			}
		}

		// Draw previous day volume profiles
		if drawPreviousDayVolumeProfiles &&
		   zoomIndex <= .HOUR
		{
			// Convert current visible indices to visible day indices - 1
			startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex)) - 1
			endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], CandleList_IndexToTimestamp(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(len(visibleCandles))))

			// If no candles are on screen, just draw the last profile
			if len(visibleCandles) == 0
			{
				endIndex = i32(len(chart.candles[Timeframe.DAY].candles))
				startIndex = endIndex - 1
			}

			for i in startIndex ..< endIndex
			{
				// bucketSize is 0 if a profile hasn't been loaded yet
				if chart.dailyVolumeProfiles[i].bucketSize == 0
				{
					startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
					endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i) + 1)
					chart.dailyVolumeProfiles[i] = VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
				}

				startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 1, scaleData)
				endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 2, scaleData)

				VolumeProfile_Draw(chart.dailyVolumeProfiles[i], startPixel - cameraX, endPixel - startPixel, cameraY, scaleData, 63, {.POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
			}
		}

		// Draw CVD
		if drawCVD &&
		   len(visibleCandles) > 0
		{
			highestCloseCandle, _ := Candle_HighestClose(visibleCandles)
			lowestCloseCandle, _ := Candle_LowestClose(visibleCandles)

			highestClose := math.min(highestCloseCandle.close, cameraTopPrice)
			lowestClose := math.max(lowestCloseCandle.close, cameraBottomPrice)

			visibleDeltas := chart.candles[zoomIndex].cumulativeDelta[visibleCandlesStartIndex:visibleCandlesStartIndex + i32(len(visibleCandles))]

			if len(visibleDeltas) > 0
			{
				highestPixel := Price_ToPixelY(highestClose, scaleData) - f32(cameraY)
				lowestPixel := Price_ToPixelY(lowestClose, scaleData) - f32(cameraY)
				pixelRange := highestPixel - lowestPixel

				highestDelta := visibleDeltas[0]
				lowestDelta := visibleDeltas[0]

				for delta in visibleDeltas[1:]
				{
					highestDelta = math.max(highestDelta, delta)
					lowestDelta = math.min(lowestDelta, delta)
				}

				deltaRange := highestDelta - lowestDelta

				points : [1000]Vector2 = ---

				for delta, i in visibleDeltas
				{
					points[i].x = f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], visibleCandlesStartIndex + i32(i) + 1, scaleData) - cameraX)
					points[i].y = f32((delta - lowestDelta) / deltaRange) * pixelRange + lowestPixel
				}

				DrawLineStrip(raw_data(points[:]), i32(len(visibleDeltas)), Color{255, 255, 255, 191})
			}
		}

		for multitool in multitools
		{
			if Multitool_IsOverlapping(multitool, cameraX, cameraY, screenWidth, screenHeight, scaleData)
			{
				Multitool_Draw(multitool, cameraX, cameraY, scaleData)
			}
		}

		if hoveredMultitool != nil
		{
			posX := Timestamp_ToPixelX(hoveredMultitool.startTimestamp, scaleData)
			posY := Price_ToPixelY(hoveredMultitool.high, scaleData)
			width := Timestamp_ToPixelX(hoveredMultitool.endTimestamp, scaleData) - posX
			height := Price_ToPixelY(hoveredMultitool.low, scaleData) - posY
			DrawRectangleLinesEx(Rectangle{posX - cameraX, posY - cameraY, width, height}, 1, {255, 255, 255, 127})
		}

		if selectedMultitool != nil
		{
			Multitool_DrawHandles(selectedMultitool^, cameraX, cameraY, scaleData)
		}

		// Draw Crosshair
		{
			mouseY := f32(GetMouseY())

			crosshairColor := WHITE
			crosshairColor.a = 127

			for i : f32 = 0; i < screenWidth; i += 3
			{
				DrawPixelV(Vector2{i, mouseY}, crosshairColor)
			}

			posX : f32 = CandleList_IndexToPixelX(chart.candles[zoomIndex], cursorCandleIndex, scaleData) - cameraX
			candleWidth : f32 = CandleList_IndexToWidth(chart.candles[zoomIndex], cursorCandleIndex, scaleData)

			for i : f32 = 0; i < screenHeight; i += 3
			{
				DrawPixelV(Vector2{posX + candleWidth / 2 - 0.5, i}, crosshairColor)
			}
		}

		// Draw current price line
		lastCandle := slice.last(chart.candles[zoomIndex].candles[:])
		priceY := Price_ToPixelY(lastCandle.close, scaleData) - cameraY - f32(i32(lastCandle.close < lastCandle.open))
		priceColor := candleColors[int(lastCandle.close < lastCandle.open)]

		for i : f32 = 0; i < screenWidth; i += 3
		{
			DrawPixelV(Vector2{i, priceY}, priceColor)
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
			labelPosX = f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], highestCandleIndex, scaleData) - cameraX) - textRect.x / 2 + candleCenterOffset
			labelPosY = f32(Price_ToPixelY(highestCandle.high, scaleData) - cameraY) - textRect.y - VERTICAL_LABEL_PADDING

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
			labelPosX = f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], lowestCandleIndex, scaleData) - cameraX) - textRect.x / 2 + candleCenterOffset
			labelPosY = f32(Price_ToPixelY(lowestCandle.low, scaleData) - cameraY) + VERTICAL_LABEL_PADDING

			labelPosX = math.clamp(labelPosX, 2, f32(screenWidth) - textRect.x - 2)

			candleCenterOffset = f32(CandleList_IndexToWidth(chart.candles[zoomIndex], lowestCandleIndex, scaleData)) / 2 - 0.5
			DrawTextEx(font, cstring(&textBuffer[0]), {labelPosX, labelPosY}, FONT_SIZE, 0, WHITE)
		}

		// "Downloading" text
		if downloading
		{
			lastCandleIndex := i32(len(chart.candles[zoomIndex].candles)) - 1

			// If last candle is visible
			if lastCandleIndex == visibleCandlesStartIndex + i32(len(visibleCandles)) - 1
			{
				posX := f32(Timestamp_ToPixelX(DayMonthYear_ToTimestamp(chart.dateToDownload), scaleData) - cameraX) + 2
				posY := f32(Price_ToPixelY(chart.candles[zoomIndex].candles[lastCandleIndex].close, scaleData) - cameraY) - MeasureTextEx(font, "W\x00", FONT_SIZE, 0).y / 2
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

			posX := f32(CandleList_IndexToPixelX(chart.candles[zoomIndex], cursorCandleIndex, scaleData) - cameraX) - width
			posY := f32(Price_ToPixelY(cursorSnapPrice, scaleData) - cameraY) - f32(labelHeight) / 2

			if posX + HORIZONTAL_LABEL_PADDING < 0
			{
				posX += width + f32(CandleList_IndexToWidth(chart.candles[zoomIndex], cursorCandleIndex, scaleData))
			}

			DrawRectangleRounded({posX, posY, width, f32(labelHeight)}, 0.5, 10, labelBackground)
			DrawTextEx(font, cstring(&textBuffer[0]), {posX + HORIZONTAL_LABEL_PADDING, posY + VERTICAL_LABEL_PADDING}, FONT_SIZE, 0, WHITE)
		}
		else
		{
			fmt.bprintf(textBuffer[:], "%.2f\x00", Price_FromPixelY(f32(GetMouseY()) + cameraY, scaleData))

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
			pixelY := Price_ToPixelY(priceLabels[i].price, scaleData) - cameraY

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
			pixelX := Timestamp_ToPixelX(timestampLabels[i].timestamp, scaleData) - cameraX

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

			pixelX := Timestamp_ToPixelX(cursorTimestamp, scaleData) - cameraX

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
