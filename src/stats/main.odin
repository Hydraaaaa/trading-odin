package stats

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:slice"
import "core:strings"
import "vendor:raylib"
import "core:encoding/csv"

import "../main"

FONT_SIZE :: 14

main :: proc()
{
	SCREEN_WIDTH :: 1712
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

	dayOfWeekHalfHourCandleVolume : [7]HalfHourCandleVolume
	dayOfWeekStrings := [7]string{"Mon\x00", "Tue\x00", "Wed\x00", "Thur\x00", "Fri\x00", "Sat\x00", "Sun\x00"}

	highestValue : f32 = 0

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

		// Half-hour candle volume for each day of the week
		{
			posX : f32 = 32
			posY : f32 = 0

			chartWidth := f32(SCREEN_WIDTH - posX) / 7

			labelValue := 1000
			labelHeight := (1 - (f32(labelValue) / highestValue)) * SCREEN_HEIGHT

			textBuffer : [16]u8

			for labelHeight > 0
			{
				fmt.bprintf(textBuffer[:], "%i\x00", labelValue)
				textDimensions := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
				DrawTextEx(font, cstring(&textBuffer[0]), {posX - textDimensions[0] - 4, labelHeight - textDimensions[1] / 2}, FONT_SIZE, 0, WHITE)
				lineColor := WHITE
				lineColor.a = 127
				DrawLine(i32(posX), i32(labelHeight), SCREEN_WIDTH, i32(labelHeight), lineColor)

				labelValue += 1000
				labelHeight = (1 - (f32(labelValue) / highestValue)) * SCREEN_HEIGHT
			}

			for i in 0 ..< 7
			{
				DrawHalfHourCandleVolume(dayOfWeekHalfHourCandleVolume[i], font, posX, posY, chartWidth, SCREEN_HEIGHT, highestValue)

				dayOfWeekHalfHourCandleVolume[i] = GetHalfHourCandleVolumeByDayOfWeek(chart, DayOfWeek(i))

				DrawTextEx(font, strings.unsafe_string_to_cstring(dayOfWeekStrings[i]), {f32(posX), 0}, FONT_SIZE, 0, WHITE)
				DrawLine(i32(posX), 0, i32(posX), SCREEN_HEIGHT, WHITE)

				posX += chartWidth
			}
		}

        EndDrawing()
	}
}