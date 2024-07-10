package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import "core:slice"
import "core:strings"
import "core:encoding/csv"

ProfilerDataPoint :: struct
{
    sectionName : string,
    sectionNameBuffer : [32]u8,
    durations : [dynamic]time.Duration,
    timestamps : [dynamic]time.Time,
    stopwatch : time.Stopwatch,

    longestDuration : time.Duration,
    shortestDuration : time.Duration,
    totalDuration : time.Duration,
}

ProfilerData :: struct
{
    dataPoints : [dynamic]ProfilerDataPoint,
    totalDuration : time.Duration,
}

// Returns handle for speedier retrieval in StopProfile
Profiler_StartProfile :: proc(sectionName : string, profilerData : ^ProfilerData) -> int
{
    for dataPoint, i in profilerData.dataPoints
    {
        if strings.compare(sectionName, dataPoint.sectionName) == 0
        {
            time.stopwatch_start(&profilerData.dataPoints[i].stopwatch)
            return i
        }
    }

    append(&profilerData.dataPoints, ProfilerDataPoint{})

    newDataPoint := &profilerData.dataPoints[len(profilerData.dataPoints) - 1]

    newDataPoint.sectionName = fmt.bprint(newDataPoint.sectionNameBuffer[:], sectionName)
    newDataPoint.shortestDuration = 999_999_999_999

    handle := len(profilerData.dataPoints) - 1

    time.stopwatch_start(&newDataPoint.stopwatch)

    return handle
}

Profiler_EndProfile :: proc{Profiler_EndProfileWithName, Profiler_EndProfileWithHandle}

Profiler_EndProfileWithHandle :: proc(handle : int, profilerData : ^ProfilerData)
{
    time.stopwatch_stop(&profilerData.dataPoints[handle].stopwatch)

    duration := time.stopwatch_duration(profilerData.dataPoints[handle].stopwatch)

    time.stopwatch_reset(&profilerData.dataPoints[handle].stopwatch)

    append(&profilerData.dataPoints[handle].durations, duration)
    append(&profilerData.dataPoints[handle].timestamps, time.now())

    profilerData.dataPoints[handle].shortestDuration = math.min(profilerData.dataPoints[handle].shortestDuration, duration)
    profilerData.dataPoints[handle].longestDuration = math.max(profilerData.dataPoints[handle].longestDuration, duration)
    profilerData.dataPoints[handle].totalDuration += duration
}

Profiler_EndProfileWithName :: proc(sectionName : string, profilerData : ^ProfilerData)
{
    for dataPoint, i in profilerData.dataPoints
    {
        if strings.compare(sectionName, dataPoint.sectionName) == 0
        {
            time.stopwatch_stop(&profilerData.dataPoints[i].stopwatch)

            duration := time.stopwatch_duration(dataPoint.stopwatch)

            time.stopwatch_reset(&profilerData.dataPoints[i].stopwatch)

            append(&profilerData.dataPoints[i].durations, duration)
            append(&profilerData.dataPoints[i].timestamps, time.now())

            if duration < dataPoint.shortestDuration
            {
                profilerData.dataPoints[i].shortestDuration = duration
            }

            if duration > dataPoint.longestDuration
            {
                profilerData.dataPoints[i].longestDuration = duration
            }

            profilerData.dataPoints[i].totalDuration += duration

            return
        }
    }

    fmt.println("End called for nonexistent profiler data:", sectionName)
}

Profiler_PrintData :: proc(profilerData : ProfilerData)
{
    totalDuration : time.Duration
    totalSamples := 0

    longestTitle := 0

    for dataPoint in profilerData.dataPoints
    {
        totalDuration += dataPoint.totalDuration
        totalSamples += len(dataPoint.durations)

        if longestTitle < len(dataPoint.sectionName)
        {
            longestTitle = len(dataPoint.sectionName)
        }
    }

    SortCriteria :: proc(i : ProfilerDataPoint, j : ProfilerDataPoint) -> bool
    {
        return i.totalDuration > j.totalDuration
    }

    slice.sort_by(profilerData.dataPoints[:], SortCriteria)

    for dataPoint, i in profilerData.dataPoints
    {
        profilerData.dataPoints[i].sectionName = string(profilerData.dataPoints[i].sectionNameBuffer[:len(dataPoint.sectionName)])
        fmt.print(profilerData.dataPoints[i].sectionName)

        for i in len(profilerData.dataPoints[i].sectionName) ..< longestTitle + 1
        {
            fmt.print(" ")
        }

        if len(profilerData.dataPoints) > 1
        {
            percentage := f64(dataPoint.totalDuration) / f64(totalDuration) * 100

            if percentage < 10 { fmt.print(" ") }

            fmt.printf("%.2f", percentage)
            fmt.print("%, ")
        }

        fmt.print("Mean:", dataPoint.totalDuration / time.Duration(len(dataPoint.durations)))
        fmt.print(", Low:", dataPoint.shortestDuration)
        fmt.print(", High:", dataPoint.longestDuration)
        fmt.println(", Samples:", len(dataPoint.durations))
    }
}

Profiler_ExportCSV :: proc(sectionName : string, profilerData : ProfilerData)
{
    using os

    NANOSECONDS_2020 :: 1577836800000000000

    for dataPoint in profilerData.dataPoints
    {
        if strings.compare(sectionName, dataPoint.sectionName) == 0
        {
            fileNameBuffer : [64]u8
            fileName := fmt.bprintf(fileNameBuffer[:], "%s%i.csv", sectionName, (time.now()._nsec - NANOSECONDS_2020) / 1000000000)

            fmt.println(fileName)

            outputFile, ok := os.open(fileName, os.O_CREATE)
            defer os.close(outputFile)

            outputStream := os.stream_from_handle(outputFile)

            writer : csv.Writer

            csv.writer_init(&writer, outputStream)

            csv.write(&writer, {"Duration", "Timestamp"})

            for _, i in dataPoint.durations
            {
                durationStringBuffer : [64]u8
                durationString := fmt.bprint(durationStringBuffer[:], i64(dataPoint.durations[i]))

                timestampStringBuffer : [64]u8
                timestampString := fmt.bprint(timestampStringBuffer[:], (dataPoint.timestamps[i]._nsec - dataPoint.timestamps[0]._nsec) / 1000)
                csv.write(&writer, {durationString, timestampString})
            }

            fmt.println("Written:", ok)

            return
        }
    }

    fmt.println("Export called for nonexistent profiler data:", sectionName)
}