package stats

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:slice"
import "vendor:raylib"
import "core:encoding/csv"

import "../main"

FONT_SIZE :: 14

main :: proc()
{
	SCREEN_WIDTH :: 1750
	SCREEN_HEIGHT :: 500

	using main
	using raylib

	SetConfigFlags({.WINDOW_RESIZABLE})

	SetTraceLogLevel(TraceLogLevel.WARNING)

	InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Chart")
	defer CloseWindow()

    SetTargetFPS(60)

	font := LoadFontEx("roboto-bold.ttf", FONT_SIZE, nil, 0)

	chart : Chart

	chart.candles[Timeframe.MINUTE].offset = BYBIT_ORIGIN_MINUTE_TIMESTAMP
	chart.candles[Timeframe.MINUTE].candles = LoadMinuteCandles()
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

	Chart_CreateHTFCandles(&chart)

	halfHourCandleVolume := GetHalfHourCandleVolume(chart)

	highestValue := halfHourCandleVolume.highestValue

	dayOfWeekHalfHourCandleVolume : [7]HalfHourCandleVolume

	for i in 0 ..< 7
	{
		dayOfWeekHalfHourCandleVolume[i] = GetHalfHourCandleVolumeByDayOfWeek(chart, DayOfWeek(i))

		highestValue = math.max(highestValue, dayOfWeekHalfHourCandleVolume[i].highestValue)
	}

	// UPDATE <><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
	for !WindowShouldClose()
	{
        BeginDrawing()

		ClearBackground(BLACK)

		//DrawHalfHourCandleVolume(halfHourCandleVolume, 0, 0, 400, 400, highestValue)

		posX : i32 = 0
		posY : i32 = 0

		for i in 0 ..< 7
		{
			DrawHalfHourCandleVolume(dayOfWeekHalfHourCandleVolume[i], posX, posY, SCREEN_WIDTH / 7, SCREEN_HEIGHT, highestValue)

			posX += SCREEN_WIDTH / 7
		}

        EndDrawing()
	}
}