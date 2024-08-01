package main

import "core:fmt"
import "core:math"
import "core:slice"

Position :: struct
{
	entry : f32, // inactive if entry == 0
	entryTimestamp : i32,
	
	target : f32,
	stopLoss : f32,
	
	isShort : bool,
}

Result :: struct
{
	entry : f32,

	entryTimestamp : i32,
	exitTimestamp : i32,
	
	target : f32,
	stopLoss : f32,
	
	isWin : bool,
}

Level :: struct
{
	price : f32,
	endTimestamp : u32, // Converts -1 to max value, causing levels with no end to get sorted properly
	position : Position,
}

// Assumes closeLevels is sorted by startTimestamp
// Returned [dynamic]Result must be freed
Calculate :: proc(chart : Chart, multitool : ^Multitool, closeLevels : []CandleCloseLevel, target : f32 = 1.01, stopLoss : f32 = 0.99)
{
	clear(&multitool.strategyResults)
	
	// Sorted by descending end timestamps
	activeLevels : [dynamic]Level
 
	nextLevelIndex := 0

	// Determine which close levels are already active at the start timestamp
	{
		initialLevels : [dynamic]Level
		
		for closeLevels[nextLevelIndex].startTimestamp < multitool.startTimestamp
		{
			// Only add the level if it overlaps the price range of the multitool
			if closeLevels[nextLevelIndex].price >= multitool.volumeProfile.bottomPrice &&
		       closeLevels[nextLevelIndex].price <= VolumeProfile_BucketToPrice(multitool.volumeProfile, len(multitool.volumeProfile.buckets), true)
			{
				append(&initialLevels, Level{price = closeLevels[nextLevelIndex].price, endTimestamp = u32(closeLevels[nextLevelIndex].endTimestamp)})
			}

			nextLevelIndex += 1
		}

		for _, index in initialLevels
		{
			if initialLevels[index].endTimestamp > u32(multitool.startTimestamp)
			{
				append(&activeLevels, initialLevels[index])
			}
		}

		slice.sort_by(activeLevels[:], proc(i, j : Level) -> bool{return i.endTimestamp > j.endTimestamp})
	}

	minuteCandles := chart.candles[Timeframe.MINUTE]
	candleStartIndex := CandleList_TimestampToIndex_Clamped(minuteCandles, multitool.startTimestamp)
	candleEndIndex := CandleList_TimestampToIndex_Clamped(minuteCandles, multitool.endTimestamp)

	candles := minuteCandles.candles[candleStartIndex:candleEndIndex]
	
	orphanedPositions : [dynamic]Position

	currentTimestamp := math.max(multitool.startTimestamp, minuteCandles.offset)
	
	for candle in candles
	{
		// Check for new active level
		if nextLevelIndex < len(closeLevels) &&
		   closeLevels[nextLevelIndex].startTimestamp < currentTimestamp
		{
			closeLevel := closeLevels[nextLevelIndex]
			
			insertIndex := 0

			for insertIndex < len(activeLevels) &&
			    activeLevels[insertIndex].endTimestamp > u32(closeLevel.endTimestamp)
			{
				insertIndex += 1
			}
		
			inject_at(&activeLevels, insertIndex, Level{price = closeLevel.price, endTimestamp = u32(closeLevel.endTimestamp)})

			nextLevelIndex += 1
		}

		if len(activeLevels) > 0
		{
			// Check for expired levels
			lastLevel := slice.last(activeLevels[:])
		
			for lastLevel.endTimestamp < u32(currentTimestamp)
			{
				// If the expired level still has an active position
				if lastLevel.position.entry != 0
				{
					append(&orphanedPositions, lastLevel.position)
				}

				pop(&activeLevels)

				if len(activeLevels) == 0
				{
					break
				}

				lastLevel = slice.last(activeLevels[:])
			}

			for _, levelIndex in activeLevels
			{
				// If level doesn't have an active position
				if activeLevels[levelIndex].position.entry == 0
				{
					if candle.open > activeLevels[levelIndex].price &&
					   candle.low < activeLevels[levelIndex].price
					{
						// Long entry
						activeLevels[levelIndex].position.entry = activeLevels[levelIndex].price
						activeLevels[levelIndex].position.entryTimestamp = currentTimestamp
						activeLevels[levelIndex].position.target = activeLevels[levelIndex].position.entry * target
						activeLevels[levelIndex].position.stopLoss = activeLevels[levelIndex].position.entry / stopLoss
						activeLevels[levelIndex].position.isShort = false
					}
					else if candle.open < activeLevels[levelIndex].price &&
					        candle.high > activeLevels[levelIndex].price
					{
						// Short entry
						activeLevels[levelIndex].position.entry = activeLevels[levelIndex].price
						activeLevels[levelIndex].position.entryTimestamp = currentTimestamp
						activeLevels[levelIndex].position.target = activeLevels[levelIndex].position.entry / target
						activeLevels[levelIndex].position.stopLoss = activeLevels[levelIndex].position.entry * stopLoss
						activeLevels[levelIndex].position.isShort = true
					}
				}
				
				// If activeLevels[levelIndex] has an active position
				if activeLevels[levelIndex].position.entry != 0
				{
					// If target or stopLoss has been crossed by latest candle
					if activeLevels[levelIndex].position.isShort && (candle.high > activeLevels[levelIndex].position.stopLoss || candle.low < activeLevels[levelIndex].position.target) ||
					  !activeLevels[levelIndex].position.isShort && (candle.low < activeLevels[levelIndex].position.stopLoss || candle.high > activeLevels[levelIndex].position.target)
					{
						isWin := activeLevels[levelIndex].position.isShort && candle.low < activeLevels[levelIndex].position.target || \
						        !activeLevels[levelIndex].position.isShort && candle.high > activeLevels[levelIndex].position.target
					        	
						result := Result \
						{
							entry = activeLevels[levelIndex].position.entry,
							entryTimestamp = activeLevels[levelIndex].position.entryTimestamp,
							exitTimestamp = currentTimestamp + 60,
							target = activeLevels[levelIndex].position.target,
							stopLoss = activeLevels[levelIndex].position.stopLoss,
							isWin = isWin,
						}
					
						append(&multitool.strategyResults, result)
				
						// Deactivate position
						activeLevels[levelIndex].position.entry = 0
					}
				}
			}
		}

		// Reverse since elements will be removed
		#reverse for position, index in orphanedPositions
		{
			// If target or stopLoss has been crossed by latest candle
			if position.isShort && (candle.high > position.stopLoss || candle.low < position.target) ||
			  !position.isShort && (candle.low < position.stopLoss || candle.high > position.target)
			{
				isWin := position.isShort && candle.low < position.target || \
				        !position.isShort && candle.high > position.target
				        	
				result := Result \
				{
					entry = position.entry,
					entryTimestamp = position.entryTimestamp,
					exitTimestamp = currentTimestamp + 60,
					target = position.target,
					stopLoss = position.stopLoss,
					isWin = isWin,
				}

				append(&multitool.strategyResults, result)

				unordered_remove(&orphanedPositions, index)
			}
		}

		currentTimestamp += 60
	}
}
