package main

import "core:fmt"
import "core:strings"
import "core:math"
import "core:thread"
import "core:time"
import "core:slice"
import rl "vendor:raylib"

INITIAL_SCREEN_WIDTH :: 1440
INITIAL_SCREEN_HEIGHT :: 720

START_ZOOM_INDEX :: Timeframe.DAY

ZOOM_THRESHOLD :: 3
HORIZONTAL_ZOOM_INCREMENT :: 1.12
VERTICAL_ZOOM_INCREMENT :: 1.07

HORIZONTAL_LABEL_PADDING :: 3
VERTICAL_LABEL_PADDING :: HORIZONTAL_LABEL_PADDING - 2

profilerData : ProfilerData

headerFont : rl.Font
HEADER_FONT_SIZE :: 32
labelFont : rl.Font
LABEL_FONT_SIZE :: 14

labelHeight : f32

volumeProfileIcon : rl.Texture2D
fibRetracementIcon : rl.Texture2D

main :: proc()
{
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
	rl.InitWindow(INITIAL_SCREEN_WIDTH, INITIAL_SCREEN_HEIGHT, "Trading")
    rl.SetTargetFPS(165)
	icon := rl.LoadImage("assets/icon.png"); defer rl.UnloadImage(icon)
	rl.SetWindowIcon(icon)

	headerFont = rl.LoadFontEx("assets/roboto-bold.ttf", HEADER_FONT_SIZE, nil, 0); defer rl.UnloadFont(headerFont)
	labelFont = rl.LoadFontEx("assets/roboto-bold.ttf", LABEL_FONT_SIZE, nil, 0); defer rl.UnloadFont(labelFont)
	labelHeight = rl.MeasureTextEx(labelFont, "W\x00", LABEL_FONT_SIZE, 0).y + VERTICAL_LABEL_PADDING * 2

	volumeProfileIcon = rl.LoadTexture("assets/volumeProfileIcon.png"); defer rl.UnloadTexture(volumeProfileIcon)
	fibRetracementIcon = rl.LoadTexture("assets/fibRetracementIcon.png"); defer rl.UnloadTexture(fibRetracementIcon)

	screenWidth : f32 = INITIAL_SCREEN_WIDTH
	screenHeight : f32 = INITIAL_SCREEN_HEIGHT
	
	windowedScreenWidth : f32 = 0
	windowedScreenHeight : f32 = 0

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
	chart.isDownloading = false
	
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

		chart.isDownloading = true
	}
	
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
	
	reserve(&chart.dailyVolumeProfiles, len(chart.candles[Timeframe.DAY].candles) + 7)
	resize(&chart.dailyVolumeProfiles, len(chart.candles[Timeframe.DAY].candles))
	reserve(&chart.weeklyVolumeProfiles, len(chart.candles[Timeframe.WEEK].candles) + 1)
	resize(&chart.weeklyVolumeProfiles, len(chart.candles[Timeframe.WEEK].candles))

	viewport : Viewport

	Viewport_Init(&viewport, chart, rl.Rectangle{0, 0, screenWidth, screenHeight}); defer Viewport_Destroy(viewport)
	
	// UPDATE <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	for !rl.WindowShouldClose()
	{
		if rl.IsWindowResized()
		{
			screenWidth = f32(rl.GetScreenWidth())
			screenHeight = f32(rl.GetScreenHeight())
			
			Viewport_Resize(&viewport, rl.Rectangle{0, 0, screenWidth, screenHeight})
		}

		if rl.IsKeyPressed(.F11)
		{
			if !rl.IsWindowFullscreen()
			{
				windowedScreenWidth = screenWidth
				windowedScreenHeight = screenHeight

				rl.SetWindowSize(rl.GetMonitorWidth(0), rl.GetMonitorHeight(0))
				
				screenWidth = f32(rl.GetMonitorWidth(0))
				screenHeight = f32(rl.GetMonitorHeight(0))
				
				rl.ToggleFullscreen()
			}
			else
			{
				rl.ToggleFullscreen()
				
				rl.SetWindowSize(i32(windowedScreenWidth), i32(windowedScreenHeight))

				screenWidth = windowedScreenWidth
				screenHeight = windowedScreenHeight
			}

			Viewport_Resize(&viewport, rl.Rectangle{0, 0, screenWidth, screenHeight})
		}

		Viewport_Update(&viewport, chart)
		
		// Check download thread
		if chart.isDownloading
		{
			if thread.is_done(downloadThread)
			{
				thread.destroy(downloadThread)

				// 404 Not Found
				if downloadedTrades == nil
				{
					chart.isDownloading = false
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
						chart.isDownloading = false
					}
				}
			}
		}

		if rl.IsKeyPressed(.X)
		{
			Profiler_PrintData(profilerData)
		}
		
		// Rendering ><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

        rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		Viewport_Draw(&viewport, chart)

        rl.EndDrawing()
	}
}
