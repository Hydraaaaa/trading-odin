package main

import "core:fmt"
import "core:math"

FibResults :: struct
{
	data : []i32,
	increment : f32,
}

CalcFibs :: proc(chart : Chart, highlows : []HighLow, startsHigh : bool) -> FibResults
{
	// fibRange
	results : []f32 = make([]f32, len(highlows)); defer delete(results)

	highestValue : f32

	prevHighlow1 := highlows[0]
	prevHighlow2 := highlows[1]

	isHigh := startsHigh

	for highlow, index in highlows[2:]
	{
		range := prevHighlow1.price - prevHighlow2.price
		results[index] = (highlow.price - prevHighlow2.price) / range

		highestValue = math.max(highestValue, results[index])

		prevHighlow1 = prevHighlow2
		prevHighlow2 = highlow

		isHigh = !isHigh
	}

	fibResults : FibResults

	fibResults.increment = 0.01

	fibResults.data = make([]i32, int(highestValue / fibResults.increment) + 1)

	for result in results
	{
		index := int(result / fibResults.increment)
		
		fibResults.data[index] += 1
	}

	return fibResults
}
