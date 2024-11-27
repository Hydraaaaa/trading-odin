package main

import "core:fmt"
import "core:math"
import "core:slice"

@(private="file")
Position :: struct
{
	entry : f32, // inactive if entry == 0
	entryTimestamp : i32,
	
	targetIndex : i32,
	target : f32,
	stopLoss : f32,

	positionSize : f32,
	
	isShort : bool,
}

Level :: struct
{
	price : f32,
	endTimestamp : u32, // Converts -1 to max value, causing levels with no end to get sorted properly
	position : Position,
}

// Assumes closeLevels is sorted by startTimestamp
// Returned [dynamic]Result must be freed
Calculate :: proc(chart : Chart, selection : ^Selection, closeLevels : []CandleCloseLevel, targets : []TradeTarget)
{
	clear(&selection.strategyResults)
	resize(&selection.strategyTargets, len(targets))

	for &target, i in selection.strategyTargets
	{
		target = targets[i]
	}
	
	// Sorted by descending end timestamps
	activeLevels : [dynamic]Level
 
	nextLevelIndex := 0

	// Determine which close levels are already active at the start timestamp
	{
		initialLevels : [dynamic]Level
		
		for closeLevels[nextLevelIndex].startTimestamp < selection.startTimestamp
		{
			// Only add the level if it overlaps the price range of the selection
			if closeLevels[nextLevelIndex].price >= selection.volumeProfile.bottomPrice &&
		       closeLevels[nextLevelIndex].price <= VolumeProfile_BucketToPrice(selection.volumeProfile, len(selection.volumeProfile.buckets), true)
			{
				append(&initialLevels, Level{price = closeLevels[nextLevelIndex].price, endTimestamp = u32(closeLevels[nextLevelIndex].endTimestamp)})
			}

			nextLevelIndex += 1
		}

		for level in initialLevels
		{
			if level.endTimestamp > u32(selection.startTimestamp)
			{
				append(&activeLevels, level)
			}
		}

		slice.sort_by(activeLevels[:], proc(i, j : Level) -> bool{return i.endTimestamp > j.endTimestamp})
	}

	minuteCandles := chart.candles[Timeframe.MINUTE]
	candleStartIndex := CandleList_TimestampToIndex_Clamped(minuteCandles, selection.startTimestamp)
	candleEndIndex := CandleList_TimestampToIndex_Clamped(minuteCandles, selection.endTimestamp)

	candles := minuteCandles.candles[candleStartIndex:candleEndIndex]
	
	orphanedPositions : [dynamic]Position

	currentTimestamp := math.max(selection.startTimestamp, minuteCandles.offset)
	
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

			for &level in activeLevels
			{
				// If level doesn't have an active position
				if level.position.entry == 0
				{
					if candle.open > level.price &&
					   candle.low < level.price
					{
						// Long entry
						level.position.entry = level.price
						level.position.entryTimestamp = currentTimestamp
						level.position.target = level.position.entry * targets[level.position.targetIndex].target
						level.position.stopLoss = level.position.entry / targets[level.position.targetIndex].stopLoss
						level.position.isShort = false
					}
					else if candle.open < level.price &&
					        candle.high > level.price
					{
						// Short entry
						level.position.entry = level.price
						level.position.entryTimestamp = currentTimestamp
						level.position.target = level.position.entry / targets[level.position.targetIndex].target
						level.position.stopLoss = level.position.entry * targets[level.position.targetIndex].stopLoss
						level.position.isShort = true
					}
				}
				
				// If level has an active position
				if level.position.entry != 0
				{
					// If target or stopLoss has been crossed by latest candle
					if level.position.isShort && (candle.high > level.position.stopLoss || candle.low < level.position.target) ||
					  !level.position.isShort && (candle.low < level.position.stopLoss || candle.high > level.position.target)
					{
						isWin := level.position.isShort && candle.low < level.position.target || \
						        !level.position.isShort && candle.high > level.position.target

						profit : f32 = 0 + BYBIT_LIMIT_FEE * 2
						loss : f32 = 0 + BYBIT_LIMIT_FEE - BYBIT_MARKET_FEE

						if level.position.isShort
						{
							profit += level.position.entry / level.position.target
							loss += level.position.entry / level.position.stopLoss
						}
						else
						{
							profit += level.position.target / level.position.entry
							loss += level.position.stopLoss / level.position.entry
						}

						pnl := profit * f32(i32(isWin)) + \
						       loss * f32(i32(!isWin))
					        	
						result := TradeResult \
						{
							entry = level.position.entry,
							entryTimestamp = level.position.entryTimestamp,
							exitTimestamp = currentTimestamp + 60,
							// TODO: targetIndex = ...
							isWin = isWin,
							pnl = pnl,
						}
					
						append(&selection.strategyResults, result)
				
						// Deactivate position
						level.position.entry = 0
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
				        
				profit : f32 = 0 + BYBIT_LIMIT_FEE * 2
				loss : f32 = 0 + BYBIT_LIMIT_FEE - BYBIT_MARKET_FEE

				if position.isShort
				{
					profit += position.entry / position.target
					loss += position.entry / position.stopLoss
				}
				else
				{
					profit += position.target / position.entry
					loss += position.stopLoss / position.entry
				}

				pnl := profit * f32(i32(isWin)) + \
				       loss * f32(i32(!isWin))
	        	
				result := TradeResult \
				{
					entry = position.entry,
					entryTimestamp = position.entryTimestamp,
					exitTimestamp = currentTimestamp + 60,
					target = position.target,
					stopLoss = position.stopLoss,
					// TODO: targetIndex = ...
					isWin = isWin,
					pnl = pnl,
				}

				append(&selection.strategyResults, result)

				unordered_remove(&orphanedPositions, index)
			}
		}

		currentTimestamp += 60
	}
}

// // Assumes closeLevels is sorted by startTimestamp
// // Returned [dynamic]Result must be freed
// Calculate :: proc(chart : Chart, selection : ^Selection, closeLevels : []CandleCloseLevel, target : f32 = 1.04, stopLoss : f32 = 0.98)
// {
// 	clear(&selection.strategyResults)
	
// 	// Sorted by descending end timestamps
// 	activeLevels : [dynamic]Level
 
// 	nextLevelIndex := 0

// 	// Determine which close levels are already active at the start timestamp
// 	{
// 		initialLevels : [dynamic]Level
		
// 		for closeLevels[nextLevelIndex].startTimestamp < selection.startTimestamp
// 		{
// 			// Only add the level if it overlaps the price range of the selection
// 			if closeLevels[nextLevelIndex].price >= selection.volumeProfile.bottomPrice &&
// 		       closeLevels[nextLevelIndex].price <= VolumeProfile_BucketToPrice(selection.volumeProfile, len(selection.volumeProfile.buckets), true)
// 			{
// 				append(&initialLevels, Level{price = closeLevels[nextLevelIndex].price, endTimestamp = u32(closeLevels[nextLevelIndex].endTimestamp)})
// 			}

// 			nextLevelIndex += 1
// 		}

// 		for _, index in initialLevels
// 		{
// 			if initialLevels[index].endTimestamp > u32(selection.startTimestamp)
// 			{
// 				append(&activeLevels, initialLevels[index])
// 			}
// 		}

// 		slice.sort_by(activeLevels[:], proc(i, j : Level) -> bool{return i.endTimestamp > j.endTimestamp})
// 	}

// 	minuteCandles := chart.candles[Timeframe.MINUTE]
// 	candleStartIndex := CandleList_TimestampToIndex_Clamped(minuteCandles, selection.startTimestamp)
// 	candleEndIndex := CandleList_TimestampToIndex_Clamped(minuteCandles, selection.endTimestamp)

// 	candles := minuteCandles.candles[candleStartIndex:candleEndIndex]
	
// 	orphanedPositions : [dynamic]Position

// 	currentTimestamp := math.max(selection.startTimestamp, minuteCandles.offset)
	
// 	for candle in candles
// 	{
// 		// Check for new active level
// 		if nextLevelIndex < len(closeLevels) &&
// 		   closeLevels[nextLevelIndex].startTimestamp < currentTimestamp
// 		{
// 			closeLevel := closeLevels[nextLevelIndex]
			
// 			insertIndex := 0

// 			for insertIndex < len(activeLevels) &&
// 			    activeLevels[insertIndex].endTimestamp > u32(closeLevel.endTimestamp)
// 			{
// 				insertIndex += 1
// 			}
		
// 			inject_at(&activeLevels, insertIndex, Level{price = closeLevel.price, endTimestamp = u32(closeLevel.endTimestamp)})

// 			nextLevelIndex += 1
// 		}

// 		if len(activeLevels) > 0
// 		{
// 			// Check for expired levels
// 			lastLevel := slice.last(activeLevels[:])
		
// 			for lastLevel.endTimestamp < u32(currentTimestamp)
// 			{
// 				// If the expired level still has an active position
// 				if lastLevel.position.entry != 0
// 				{
// 					append(&orphanedPositions, lastLevel.position)
// 				}

// 				pop(&activeLevels)

// 				if len(activeLevels) == 0
// 				{
// 					break
// 				}

// 				lastLevel = slice.last(activeLevels[:])
// 			}

// 			for _, levelIndex in activeLevels
// 			{
// 				// If level doesn't have an active position
// 				if activeLevels[levelIndex].position.entry == 0
// 				{
// 					if candle.open > activeLevels[levelIndex].price &&
// 					   candle.low < activeLevels[levelIndex].price
// 					{
// 						// Long entry
// 						activeLevels[levelIndex].position.entry = activeLevels[levelIndex].price
// 						activeLevels[levelIndex].position.entryTimestamp = currentTimestamp
// 						activeLevels[levelIndex].position.target = activeLevels[levelIndex].position.entry * target
// 						activeLevels[levelIndex].position.stopLoss = activeLevels[levelIndex].position.entry / stopLoss
// 						activeLevels[levelIndex].position.isShort = false
// 					}
// 					else if candle.open < activeLevels[levelIndex].price &&
// 					        candle.high > activeLevels[levelIndex].price
// 					{
// 						// Short entry
// 						activeLevels[levelIndex].position.entry = activeLevels[levelIndex].price
// 						activeLevels[levelIndex].position.entryTimestamp = currentTimestamp
// 						activeLevels[levelIndex].position.target = activeLevels[levelIndex].position.entry / target
// 						activeLevels[levelIndex].position.stopLoss = activeLevels[levelIndex].position.entry * stopLoss
// 						activeLevels[levelIndex].position.isShort = true
// 					}
// 				}
				
// 				// If activeLevels[levelIndex] has an active position
// 				if activeLevels[levelIndex].position.entry != 0
// 				{
// 					// If target or stopLoss has been crossed by latest candle
// 					if activeLevels[levelIndex].position.isShort && (candle.high > activeLevels[levelIndex].position.stopLoss || candle.low < activeLevels[levelIndex].position.target) ||
// 					  !activeLevels[levelIndex].position.isShort && (candle.low < activeLevels[levelIndex].position.stopLoss || candle.high > activeLevels[levelIndex].position.target)
// 					{
// 						isWin := activeLevels[levelIndex].position.isShort && candle.low < activeLevels[levelIndex].position.target || \
// 						        !activeLevels[levelIndex].position.isShort && candle.high > activeLevels[levelIndex].position.target

// 						profit : f32 = 0 + BYBIT_LIMIT_FEE * 2
// 						loss : f32 = 0 + BYBIT_LIMIT_FEE - BYBIT_MARKET_FEE

// 						if activeLevels[levelIndex].position.isShort
// 						{
// 							profit += activeLevels[levelIndex].position.entry / activeLevels[levelIndex].position.target
// 							loss += activeLevels[levelIndex].position.entry / activeLevels[levelIndex].position.stopLoss
// 						}
// 						else
// 						{
// 							profit += activeLevels[levelIndex].position.target / activeLevels[levelIndex].position.entry
// 							loss += activeLevels[levelIndex].position.stopLoss / activeLevels[levelIndex].position.entry
// 						}

// 						pnl := profit * f32(i32(isWin)) + \
// 						       loss * f32(i32(!isWin))
					        	
// 						result := Result \
// 						{
// 							entry = activeLevels[levelIndex].position.entry,
// 							entryTimestamp = activeLevels[levelIndex].position.entryTimestamp,
// 							exitTimestamp = currentTimestamp + 60,
// 							target = activeLevels[levelIndex].position.target,
// 							stopLoss = activeLevels[levelIndex].position.stopLoss,
// 							isWin = isWin,
// 							pnl = pnl,
// 						}
					
// 						append(&selection.strategyResults, result)
				
// 						// Deactivate position
// 						activeLevels[levelIndex].position.entry = 0
// 					}
// 				}
// 			}
// 		}

// 		// Reverse since elements will be removed
// 		#reverse for position, index in orphanedPositions
// 		{
// 			// If target or stopLoss has been crossed by latest candle
// 			if position.isShort && (candle.high > position.stopLoss || candle.low < position.target) ||
// 			  !position.isShort && (candle.low < position.stopLoss || candle.high > position.target)
// 			{
// 				isWin := position.isShort && candle.low < position.target || \
// 				        !position.isShort && candle.high > position.target
				        
// 				profit : f32 = 0 + BYBIT_LIMIT_FEE * 2
// 				loss : f32 = 0 + BYBIT_LIMIT_FEE - BYBIT_MARKET_FEE

// 				if position.isShort
// 				{
// 					profit += position.entry / position.target
// 					loss += position.entry / position.stopLoss
// 				}
// 				else
// 				{
// 					profit += position.target / position.entry
// 					loss += position.stopLoss / position.entry
// 				}

// 				pnl := profit * f32(i32(isWin)) + \
// 				       loss * f32(i32(!isWin))
	        	
// 				result := Result \
// 				{
// 					entry = position.entry,
// 					entryTimestamp = position.entryTimestamp,
// 					exitTimestamp = currentTimestamp + 60,
// 					target = position.target,
// 					stopLoss = position.stopLoss,
// 					isWin = isWin,
// 					pnl = pnl,
// 				}

// 				append(&selection.strategyResults, result)

// 				unordered_remove(&orphanedPositions, index)
// 			}
// 		}

// 		currentTimestamp += 60
// 	}
// }
