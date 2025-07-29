package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "core:os"
import "core:encoding/csv"
import "core:strings"
import rl "vendor:raylib"

HalfHourOfWeek_Heatmap :: struct
{
    params : HeatmapParameters,
    
    bucketCount : int,
    buckets : []i32, // Each column of the heatmap is a separate histogram. This slice stores each histogram back-to-back

    totalSamples : [336]i32, // Since samples can be culled due to being outside the specified range, this will ensure no issues
    biggestBucket : i32,
    biggestBuckets : [336]i32,
    means : [336]f32,
    medians : [336]int, // Should I even have this? It won't be precise
}

HeatmapParameters :: struct
{
    accumulator : proc(candle : Candle) -> f32,
    bucketSize : f32,
    minValue : f32,
    maxValue : f32,
}

// Must be freed with HalfHourOfWeek_Heatmap_Destroy
HalfHourOfWeek_Heatmap_Create :: proc(chart : Chart, startTimestamp : i32, endTimestamp : i32, params : HeatmapParameters) -> HalfHourOfWeek_Heatmap
{
    // Initialize heatmap buckets
    heatmap : HalfHourOfWeek_Heatmap

    heatmap.params = params
    heatmap.params.minValue -= math.mod(params.minValue, params.bucketSize)

    if params.maxValue != math.mod(params.maxValue, params.bucketSize)
    {
        heatmap.params.maxValue -= math.mod(params.maxValue, params.bucketSize)
    }
    
    heatmap.bucketCount = int((heatmap.params.maxValue - heatmap.params.minValue) / params.bucketSize)

    heatmap.buckets = make([]i32, heatmap.bucketCount * 336)

    // Loop through the candles
	timeframeIncrements := TIMEFRAME_INCREMENTS
	halfHourCandles := chart.candles[Timeframe.MINUTE_30]
	
    firstHalfHourTimestamp := CandleList_RoundTimestamp_Clamped(halfHourCandles, startTimestamp)
	firstWeekTimestamp := CandleList_RoundTimestamp_Clamped(chart.candles[Timeframe.WEEK], startTimestamp)
    
    // columnIndex refers to which histogram in the heatmap to assign to
    columnIndex := int((firstHalfHourTimestamp - firstWeekTimestamp) / timeframeIncrements[Timeframe.MINUTE_30]) * heatmap.bucketCount
    
    candleStartIndex := CandleList_TimestampToIndex_Clamped(halfHourCandles, startTimestamp)
    candleEndIndex := CandleList_TimestampToIndex_Clamped(halfHourCandles, endTimestamp)

    for candle in halfHourCandles.candles[candleStartIndex:candleEndIndex]
    {
        bucketValue := heatmap.params.accumulator(candle)

        if bucketValue >= heatmap.params.minValue &&
           bucketValue < heatmap.params.maxValue
        {
            bucketIndex := int((bucketValue - heatmap.params.minValue) / heatmap.params.bucketSize)
            heatmap.buckets[columnIndex + bucketIndex] += 1
        }
        
        columnIndex += heatmap.bucketCount
        columnIndex %= heatmap.bucketCount * 336
    }

    HalfHourOfWeek_Heatmap_CalculateMetadata(&heatmap)
    
    return heatmap
}

HalfHourOfWeek_Heatmap_Resize :: proc(heatmap : ^HalfHourOfWeek_Heatmap, chart : Chart, oldStartTimestamp : i32, oldEndTimestamp : i32, newStartTimestamp : i32, newEndTimestamp : i32)
{
    // If the new region doesn't overlap the old region, regenerate
    // If the new region is less than half the size of the old region, regenerate (less work than shrinking)
    // TODO: Determine size of the non-overlapping region specifically, do the same for volume profiles
    if newStartTimestamp > oldEndTimestamp ||
       newEndTimestamp < oldStartTimestamp ||
       newEndTimestamp - newStartTimestamp / 2 < oldEndTimestamp - oldStartTimestamp
    {
        HalfHourOfWeek_Heatmap_Destroy(heatmap^)
        heatmap^ = HalfHourOfWeek_Heatmap_Create(chart, newStartTimestamp, newEndTimestamp, heatmap.params)
        return
    }

    // TODO: Actually resize
    HalfHourOfWeek_Heatmap_Destroy(heatmap^)
    heatmap^ = HalfHourOfWeek_Heatmap_Create(chart, newStartTimestamp, newEndTimestamp, heatmap.params)
}

@(private="file")
HalfHourOfWeek_Heatmap_CalculateMetadata :: proc(heatmap : ^HalfHourOfWeek_Heatmap)
{
    heatmap.biggestBucket = slice.max(heatmap.buckets)

    for colIndex in 0 ..< 336
    {
        column := heatmap.buckets[heatmap.bucketCount * colIndex:heatmap.bucketCount * (colIndex+1)]
        
        heatmap.biggestBuckets[colIndex] = slice.max(column)

        totalSamples : i32 = 0
        totalValue : f32 = 0

        for i in 0 ..< heatmap.bucketCount
        {
            totalSamples += column[i]
            bucketValue := heatmap.params.minValue + heatmap.params.bucketSize * f32(i)
            totalValue += f32(column[i]) * bucketValue
        }

        heatmap.totalSamples[colIndex] = totalSamples
        heatmap.means[colIndex] = totalValue / f32(totalSamples)

        totalSamples /= 2
        medianIndex := 0
        
        for medianIndex < heatmap.bucketCount
        {
            totalSamples -= heatmap.buckets[medianIndex]

            if totalSamples <= 0
            {
                break
            }

            medianIndex += 1
        }

        heatmap.medians[colIndex] = medianIndex
    }
}

HalfHourOfWeek_Heatmap_Destroy :: proc(heatmap : HalfHourOfWeek_Heatmap)
{
    delete(heatmap.buckets)
}
