package main

import "core:fmt"
import "core:math"

CandleList :: struct
{
	candles : [dynamic]Candle,
	cumulativeDelta : [dynamic]f64,
	offset : i32,
	timeframe : Timeframe,
}

Timeframe :: enum
{
	MINUTE,
	MINUTE_5,
	MINUTE_15,
	MINUTE_30,
	HOUR,
	HOUR_3,
	HOUR_6,
	HOUR_12,
	DAY,
	WEEK,
	MONTH,
	//QTR,
	//YEAR,
}

// May return out of range index, consider CandleList_TimestampToIndex_Clamped
CandleList_TimestampToIndex :: proc(candleList : CandleList, timestamp : i32) -> i32
{
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	if candleList.timeframe == .MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS

		offsetIndex := candleList.offset / FOUR_YEARS * 48
		remainingOffsetTimestamp := candleList.offset % FOUR_YEARS

		remainingOffsetIndex : i32 = 47

		for remainingOffsetTimestamp < monthlyIncrements[remainingOffsetIndex]
		{
			remainingOffsetIndex -= 1
		}

		index := timestamp / FOUR_YEARS * 48 - offsetIndex
		remainingTimestamp := timestamp % FOUR_YEARS

		remainingIndex : i32 = 47

		for remainingTimestamp < monthlyIncrements[remainingIndex]
		{
			remainingIndex -= 1
		}

		index += remainingIndex - remainingOffsetIndex

		return index
	}

	// Everything below months is uniform, and can be mathed
	increment := timeframeIncrements[candleList.timeframe]

	index := (timestamp - candleList.offset) / increment

	return index
}

// Ensures that the returned index is not out of range
CandleList_TimestampToIndex_Clamped :: proc(candleList : CandleList, timestamp : i32) -> i32
{
	return math.clamp(CandleList_TimestampToIndex(candleList, timestamp), 0, i32(len(candleList.candles)) - 1)
}

CandleList_IndexToTimestamp :: proc(candleList : CandleList, index : i32) -> i32
{
	if candleList.timeframe == .MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS

		offsetRemainderTimestamp := candleList.offset % FOUR_YEARS
		offsetRemainderIndex : i32 = 47

		for offsetRemainderTimestamp < monthlyIncrements[offsetRemainderIndex]
		{
			offsetRemainderIndex -= 1
		}

		baseIndex := (offsetRemainderIndex + index) / 48
		remainderIndex := (offsetRemainderIndex + index) % 48

		return candleList.offset + baseIndex * FOUR_YEARS + monthlyIncrements[remainderIndex] - monthlyIncrements[offsetRemainderIndex]
	}

	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	return timeframeIncrements[candleList.timeframe] * index + candleList.offset
}

CandleList_IndexToPixelX :: proc(candleList : CandleList, index : i32, scaleData : ScaleData) -> f32
{
	return Timestamp_ToPixelX(CandleList_IndexToTimestamp(candleList, index), scaleData)
}

// Returns the width of a candle as a timestamp
CandleList_IndexToDuration :: proc(candleList : CandleList, index : i32) -> i32
{
	if candleList.timeframe == .MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS

		offsetRemainderTimestamp := candleList.offset % FOUR_YEARS
		offsetRemainderIndex : i32 = 47

		for offsetRemainderTimestamp < monthlyIncrements[offsetRemainderIndex]
		{
			offsetRemainderIndex -= 1
		}

		remainderIndex := (offsetRemainderIndex + index) % 48

		daysPerMonth := DAYS_PER_MONTH

		return i32(daysPerMonth[remainderIndex]) * DAY
	}

	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	return timeframeIncrements[candleList.timeframe]
}

CandleList_IndexToWidth :: proc(candleList : CandleList, index : i32, scaleData : ScaleData) -> f32
{
	return Timestamp_ToPixelX(CandleList_IndexToDuration(candleList, index), scaleData)
}

// Returned i32 is the slice's index within the candleList, -1 if slice is empty
CandleList_CandlesBetweenTimestamps :: proc(candleList : CandleList, startTimestamp : i32, endTimestamp : i32) -> ([]Candle, i32)
{
	if candleList.offset > endTimestamp
	{
		// End is further left than the leftmost candle
		return nil, -1
	}

    startTimestamp := startTimestamp - candleList.offset
    endTimestamp := endTimestamp - candleList.offset

    candleListLen := i32(len(candleList.candles))

	lastCandleIndex := candleListLen - 1

	if candleList.timeframe == .MONTH
	{
		monthlyIncrements := MONTHLY_INCREMENTS

		startTimestamp = math.max(startTimestamp, 0)

		cameraCandleIndex := startTimestamp / FOUR_YEARS * 48
		remainingCameraTimestamp := startTimestamp % FOUR_YEARS

		remainingIndex : i32 = 47

		for remainingCameraTimestamp < monthlyIncrements[remainingIndex]
		{
			remainingIndex -= 1
		}

		cameraCandleIndex += remainingIndex

		if candleListLen <= cameraCandleIndex
		{
			// Start is further right than the rightmost candle
			return nil, -1
		}

		cameraEndCandleIndex := endTimestamp / FOUR_YEARS * 48
		remainingCameraEndTimestamp := endTimestamp % FOUR_YEARS

		remainingIndex = 47

		for remainingCameraEndTimestamp < monthlyIncrements[remainingIndex]
		{
			remainingIndex -= 1
		}

		cameraCandleIndex = math.clamp(cameraCandleIndex, 0, lastCandleIndex)
		cameraEndCandleIndex = math.clamp(cameraEndCandleIndex + remainingIndex, 0, lastCandleIndex + 1)

		return candleList.candles[cameraCandleIndex:cameraEndCandleIndex], cameraCandleIndex
	}

	// Everything below months is uniform, and can be mathed
	timeframeIncrements := CANDLE_TIMEFRAME_INCREMENTS

	increment := timeframeIncrements[candleList.timeframe]

	if candleListLen * increment < startTimestamp
	{
		// Start is further right than the rightmost candle
		return nil, -1
	}

	startIndex := math.clamp(startTimestamp / increment, 0, lastCandleIndex)
	endIndex := math.clamp(endTimestamp / increment + 1, 0, lastCandleIndex + 1) // +1 because slices exclude the max index

	return candleList.candles[startIndex:endIndex], startIndex
}
