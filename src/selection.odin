package main

import "core:fmt"
import "core:math"

import "vendor:raylib"

LEVEL_CIRCLE_RADIUS :: 5
FIB_618_COLOR :: raylib.Color{255, 255, 127, 255}

LINE_SELECTION_THICKNESS :: 3

CELL_COUNT :: 2
HOTBAR_CELL_SIZE :: 32
HOTBAR_SPACING :: 1
HOTBAR_CELL_COUNT :: 2
HOTBAR_ROUNDING :: 0.25

HOTBAR_WIDTH :: HOTBAR_CELL_SIZE * HOTBAR_CELL_COUNT + HOTBAR_SPACING * (HOTBAR_CELL_COUNT + 1)
HOTBAR_HEIGHT :: HOTBAR_CELL_SIZE + HOTBAR_SPACING * 2

Tool :: enum
{
	VOLUME_PROFILE,
	FIB_RETRACEMENT,
}

ToolSet :: bit_set[Tool]

Selection :: struct
{
	startTimestamp : i32,
	endTimestamp : i32,
	high : f32,
	low  : f32,
	isUpsideDown : bool,

	tools : ToolSet,

	volumeProfile : VolumeProfile,
	volumeProfileDrawFlags : VolumeProfile_DrawFlagSet,

	draw618 : bool,

	strategyResults : [dynamic]TradeResult,
	strategyTargets : [dynamic]TradeTarget,
	
	priceMovement : HalfHourOfWeek_BoxPlot,
	priceMovementAbs : HalfHourOfWeek_BoxPlot,
	priceMovementPercent : HalfHourOfWeek_BoxPlot,
	priceMovementPercentAbs : HalfHourOfWeek_BoxPlot,
}

TradeResult :: struct
{
	entry : f32,

	entryTimestamp : i32,
	exitTimestamp : i32,

	target : f32,
	stopLoss : f32,
	pnl : f32,

	isWin : bool,
}

TradeTarget :: struct
{
	target : f32,
	stopLoss : f32,
}

SelectionHandle :: enum
{
	NONE,
	EDGE_TOPLEFT,
	EDGE_TOP,
	EDGE_TOPRIGHT,
	EDGE_LEFT,
	EDGE_RIGHT,
	EDGE_BOTTOMLEFT,
	EDGE_BOTTOM,
	EDGE_BOTTOMRIGHT,
	VOLUME_PROFILE_BODY,
	POC,
	VAL,
	VAH,
	TV_VAL,
	TV_VAH,
	VWAP,
	FIB_618,
	HOTBAR_VOLUME_PROFILE,
	HOTBAR_FIB_RETRACEMENT,
}

Selection_Destroy :: proc(selection : Selection)
{
	VolumeProfile_Destroy(selection.volumeProfile)
}

Selection_IsOverlapping :: proc{Selection_IsOverlappingPoint, Selection_IsOverlappingRect}

// Precise, used for cursor
Selection_IsOverlappingPoint :: proc(selection : Selection, posX : f32, posY : f32, scaleData : ScaleData) -> bool
{
	if !Selection_IsOverlappingRect(selection, posX, posY, 0, 0, scaleData)
	{
		return false
	}
	
	selectionStartX := Timestamp_ToPixelX(selection.startTimestamp, scaleData)
	selectionEndX := Timestamp_ToPixelX(selection.endTimestamp, scaleData)

	if .FIB_RETRACEMENT in selection.tools &&
	   selection.draw618
	{
		priceRange := selection.high - selection.low

		pixelY : f32 = ---
		
		if selection.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + selection.low, scaleData)
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + selection.low, scaleData)
		}
		
		if posX >= selectionEndX &&
		   posY >= pixelY - LINE_SELECTION_THICKNESS &&
		   posY < pixelY + LINE_SELECTION_THICKNESS
		{
			return true
		}
	}

	if .VOLUME_PROFILE in selection.tools
	{
		// If hovering the right side of the profile, compare against value area lines etc
		if posX > selectionEndX
		{
			bucketIndices := []int{selection.volumeProfile.pocIndex, selection.volumeProfile.vahIndex, selection.volumeProfile.valIndex, selection.volumeProfile.tvVahIndex, selection.volumeProfile.tvValIndex }
			drawFlags := []VolumeProfile_DrawFlag{.POC, .VAH, .VAL, .TV_VAH, .TV_VAL}

			for bucketIndex, index in bucketIndices
			{
				if drawFlags[index] not_in selection.volumeProfileDrawFlags
				{
					continue
				}
			
				bucketStartPixel := VolumeProfile_BucketToPixelY(selection.volumeProfile, bucketIndex, scaleData, true)
				bucketEndPixel := VolumeProfile_BucketToPixelY(selection.volumeProfile, bucketIndex + 1, scaleData, true)

				bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

				if posY >= bucketEndPixel && posY < bucketEndPixel + bucketThickness ||
				   bucketThickness == 1 && math.abs(posY - bucketStartPixel) < LINE_SELECTION_THICKNESS
				{
					return true
				}
			}

			// Check overlap with VWAP
			return .VWAP in selection.volumeProfileDrawFlags &&
			       math.abs(posY - Price_ToPixelY(selection.volumeProfile.vwap, scaleData)) < LINE_SELECTION_THICKNESS
		}

		// Compare against the profile itself
		if .BODY not_in selection.volumeProfileDrawFlags ||
		   !Selection_IsVolumeProfileBodyOverlappingRect(selection, posX, posY, 1, 1, scaleData)
		{
			return false
		}
	
		width := Timestamp_ToPixelX(selection.endTimestamp, scaleData) - Timestamp_ToPixelX(selection.startTimestamp, scaleData)

		bucketIndex := VolumeProfile_PixelYToBucket(selection.volumeProfile, posY, scaleData)

		volume := selection.volumeProfile.buckets[bucketIndex].buyVolume + selection.volumeProfile.buckets[bucketIndex].sellVolume

		startBucketPixel := posY
		currentBucketPixel := VolumeProfile_BucketToPixelY(selection.volumeProfile, bucketIndex + 1, scaleData)

		// If there are multiple buckets within one pixel, only draw the biggest
		for currentBucketPixel == startBucketPixel &&
			bucketIndex < len(selection.volumeProfile.buckets) - 1
		{
			bucketIndex += 1

			volume = math.max(volume, selection.volumeProfile.buckets[bucketIndex].buyVolume + selection.volumeProfile.buckets[bucketIndex].sellVolume)

			currentBucketPixel = VolumeProfile_BucketToPixelY(selection.volumeProfile, bucketIndex + 1, scaleData)
		}

		highestBucketVolume := selection.volumeProfile.buckets[selection.volumeProfile.pocIndex].buyVolume + selection.volumeProfile.buckets[selection.volumeProfile.pocIndex].sellVolume

		return posX <= selectionStartX + width * (volume / highestBucketVolume)
	}

	return false
}

// Approximate, used for culling
Selection_IsOverlappingRect :: proc(selection : Selection, posX : f32, posY : f32, width : f32, height : f32, scaleData : ScaleData) -> bool
{
	start := Timestamp_FromPixelX(posX, scaleData)
	end := Timestamp_FromPixelX(posX + width, scaleData)
	high := Price_FromPixelY(posY, scaleData)
	low := Price_FromPixelY(posY + height, scaleData)

	selectionStart := selection.startTimestamp
	selectionEnd := selection.endTimestamp + (selection.endTimestamp - selection.startTimestamp)
	selectionHigh := math.max(selection.high, selection.volumeProfile.bottomPrice + f32(len(selection.volumeProfile.buckets)) * selection.volumeProfile.bucketSize)
	selectionLow := math.min(selection.low, selection.volumeProfile.bottomPrice)

	return !(selectionHigh < low ||
	         selectionLow > high ||
	         selectionStart > end ||
	         selectionEnd < start)
}

// Approximate, used for culling  
Selection_IsVolumeProfileBodyOverlappingRect :: proc(selection : Selection, posX : f32, posY : f32, width : f32, height : f32, scaleData : ScaleData) -> bool
{
	start := Timestamp_FromPixelX(posX, scaleData)
	end := Timestamp_FromPixelX(posX + width, scaleData)
	high := Price_FromPixelY(posY, scaleData)
	low := Price_FromPixelY(posY + height, scaleData)

	profileStart := selection.startTimestamp
	profileEnd := selection.endTimestamp
	profileHigh := selection.volumeProfile.bottomPrice + f32(len(selection.volumeProfile.buckets)) * selection.volumeProfile.bucketSize
	profileLow := selection.volumeProfile.bottomPrice

	return !(profileHigh < low ||
	         profileLow > high ||
	         profileStart > end ||
	         profileEnd < start)
}

Selection_GetHotbarPos :: proc(selection : Selection, cameraX : f32, cameraY : f32, scaleData : ScaleData) -> raylib.Vector2
{
	posX := Timestamp_ToPixelX(selection.startTimestamp, scaleData)
	posY := Price_ToPixelY(selection.high, scaleData)
	width := Timestamp_ToPixelX(selection.endTimestamp, scaleData) - posX
	height := Price_ToPixelY(selection.low, scaleData) - posY
	
	HOTBAR_PADDING :: 8
	
	hotbarX : f32 = posX + width / 2 - HOTBAR_WIDTH / 2 - cameraX
	hotbarY : f32 = ---

	// If selection is too small
	if width < HOTBAR_WIDTH + HOTBAR_PADDING * 2 ||
	   height < HOTBAR_HEIGHT + HOTBAR_PADDING * 2
	{
		// Place hotbar below selection
		hotbarY = posY + height + HOTBAR_PADDING - cameraY
	}
	else
	{
		// Place hotbar inside selection
		hotbarY = posY + height - HOTBAR_HEIGHT - HOTBAR_PADDING - cameraY
		
		// Clamp to screen bounds
		hotbarX = math.clamp(hotbarX, HOTBAR_PADDING, f32(raylib.GetScreenWidth()) - HOTBAR_PADDING - HOTBAR_WIDTH - 60)
		hotbarY = math.clamp(hotbarY, HOTBAR_PADDING, f32(raylib.GetScreenHeight()) - HOTBAR_PADDING - HOTBAR_HEIGHT - labelHeight)

		// Clamp to selection bounds
		hotbarX = math.clamp(hotbarX, posX - cameraX + HOTBAR_PADDING, posX + width - cameraX - HOTBAR_WIDTH - HOTBAR_PADDING)
		hotbarY = math.clamp(hotbarY, posY - cameraY + HOTBAR_PADDING, posY + height - cameraY - HOTBAR_HEIGHT - HOTBAR_PADDING)
	}

	return raylib.Vector2{hotbarX, hotbarY}
}

Selection_HandleAt :: proc(selection : Selection, posX : f32, posY : f32, cameraX : f32, cameraY : f32, scaleData : ScaleData) -> SelectionHandle
{
	posX := posX + cameraX
	posY := posY + cameraY
	
	SQR_RADIUS :: LEVEL_CIRCLE_RADIUS * LEVEL_CIRCLE_RADIUS
	
	leftPos := Timestamp_ToPixelX(selection.startTimestamp, scaleData)
	rightPos := Timestamp_ToPixelX(selection.endTimestamp, scaleData)
	topPos := Price_ToPixelY(selection.high, scaleData)
	bottomPos := Price_ToPixelY(selection.low, scaleData)
	width := rightPos - leftPos
	height := bottomPos - topPos
	
	// Hotbar
	hotbarPos := Selection_GetHotbarPos(selection, cameraX, cameraY, scaleData)
	hotbarPos.x += cameraX
	hotbarPos.y += cameraY

	if posX >= hotbarPos.x &&
	   posX < hotbarPos.x + HOTBAR_WIDTH &&
	   posY >= hotbarPos.y &&
	   posY < hotbarPos.y + HOTBAR_HEIGHT
	{
		cellX := hotbarPos.x + HOTBAR_SPACING
		cellY := hotbarPos.y + HOTBAR_SPACING

		if posX >= cellX &&
		   posY >= cellY &&
		   posX < cellX + HOTBAR_CELL_SIZE &&
		   posY < cellY + HOTBAR_CELL_SIZE
		{
			return .HOTBAR_VOLUME_PROFILE
		}

		cellX += HOTBAR_CELL_SIZE + HOTBAR_SPACING
		
		if posX >= cellX &&
		   posY >= cellY &&
		   posX < cellX + HOTBAR_CELL_SIZE &&
		   posY < cellY + HOTBAR_CELL_SIZE
		{
			return .HOTBAR_FIB_RETRACEMENT
		}

		return .NONE
	}
	
	// Circle overlap helper values
	distX := rightPos - posX
	targetSqrDistY := SQR_RADIUS - distX * distX
	
	if .FIB_RETRACEMENT in selection.tools
	{
		levelY : f32 = ---

		priceRange := selection.high - selection.low

		if selection.isUpsideDown
		{
			levelY = Price_ToPixelY(priceRange * 0.618 + selection.low, scaleData)
		}
		else
		{
			levelY = Price_ToPixelY(priceRange * (1 - 0.618) + selection.low, scaleData)
		}

		distY := levelY - posY
		if distY * distY < targetSqrDistY { return .FIB_618 }
	}

	if .VOLUME_PROFILE in selection.tools
	{
		// Right side of profile
		levelY := Price_ToPixelY(selection.volumeProfile.vwap, scaleData)
		distY := levelY - posY
		if distY * distY < targetSqrDistY { return .VWAP }
		
		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(selection.volumeProfile, selection.volumeProfile.pocIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .POC }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(selection.volumeProfile, selection.volumeProfile.valIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .VAL }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(selection.volumeProfile, selection.volumeProfile.vahIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .VAH }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(selection.volumeProfile, selection.volumeProfile.tvValIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .TV_VAL }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(selection.volumeProfile, selection.volumeProfile.tvVahIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .TV_VAH }

		// Left side of profile
		distX = leftPos - posX
		targetSqrDistY = SQR_RADIUS - distX * distX
		
		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(selection.volumeProfile, selection.volumeProfile.pocIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .VOLUME_PROFILE_BODY }
	}

	// Corners
	if posX >= leftPos - LINE_SELECTION_THICKNESS &&
	   posX <= leftPos + LINE_SELECTION_THICKNESS &&
	   posY >= topPos - LINE_SELECTION_THICKNESS &&
	   posY <= topPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_TOPLEFT
	}

	if posX >= rightPos - LINE_SELECTION_THICKNESS &&
	   posX <= rightPos + LINE_SELECTION_THICKNESS &&
	   posY >= topPos - LINE_SELECTION_THICKNESS &&
	   posY <= topPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_TOPRIGHT
	}

	if posX >= leftPos - LINE_SELECTION_THICKNESS &&
	   posX <= leftPos + LINE_SELECTION_THICKNESS &&
	   posY >= bottomPos - LINE_SELECTION_THICKNESS &&
	   posY <= bottomPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_BOTTOMLEFT
	}

	if posX >= rightPos - LINE_SELECTION_THICKNESS &&
	   posX <= rightPos + LINE_SELECTION_THICKNESS &&
	   posY >= bottomPos - LINE_SELECTION_THICKNESS &&
	   posY <= bottomPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_BOTTOMRIGHT
	}

	// Edges
	if posX >= leftPos - LINE_SELECTION_THICKNESS &&
	   posX <= rightPos + LINE_SELECTION_THICKNESS &&
	   posY >= topPos - LINE_SELECTION_THICKNESS &&
	   posY <= topPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_TOP
	}

	if posX >= leftPos - LINE_SELECTION_THICKNESS &&
	   posX <= leftPos + LINE_SELECTION_THICKNESS &&
	   posY >= topPos - LINE_SELECTION_THICKNESS &&
	   posY <= bottomPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_LEFT
	}

	if posX >= rightPos - LINE_SELECTION_THICKNESS &&
	   posX <= rightPos + LINE_SELECTION_THICKNESS &&
	   posY >= topPos - LINE_SELECTION_THICKNESS &&
	   posY <= bottomPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_RIGHT
	}

	if posX >= leftPos - LINE_SELECTION_THICKNESS &&
	   posX <= rightPos + LINE_SELECTION_THICKNESS &&
	   posY >= bottomPos - LINE_SELECTION_THICKNESS &&
	   posY <= bottomPos + LINE_SELECTION_THICKNESS
	{
		return .EDGE_BOTTOM
	}

	return .NONE
}

Selection_Create :: proc(selection : ^Selection, chart : Chart, startTimestamp : i32, endTimestamp : i32, high : f32, low : f32)
{
	selection.startTimestamp = startTimestamp
	selection.endTimestamp = endTimestamp
	selection.high = high
	selection.low = low
	selection.isUpsideDown = false

	selection.tools = nil

	selection.volumeProfile = VolumeProfile_Create(selection.startTimestamp, selection.endTimestamp, chart, 25)
	selection.volumeProfileDrawFlags = {.BODY, .POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP}

	selection.draw618 = true

	selection.priceMovement = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp)
	selection.priceMovementAbs = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp, true)
	selection.priceMovementPercent = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp, false, true)
	selection.priceMovementPercentAbs = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp, true, true)
}

Selection_Resize :: proc(selection : ^Selection, startTimestamp : i32, endTimestamp : i32, high : f32, low : f32, isUpsideDown : bool, chart : Chart)
{
	VolumeProfile_Resize(&selection.volumeProfile, selection.startTimestamp, selection.endTimestamp, startTimestamp, endTimestamp, chart)

	selection.startTimestamp = startTimestamp
	selection.endTimestamp = endTimestamp
	selection.high = high
	selection.low = low
	selection.isUpsideDown = isUpsideDown
	
	selection.priceMovement = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp)
	selection.priceMovementAbs = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp, true)
	selection.priceMovementPercent = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp, false, true)
	selection.priceMovementPercentAbs = HalfHourOfWeek_PriceMovement(chart, startTimestamp, endTimestamp, true, true)
}

Selection_Draw :: proc(selection : Selection, cameraX : f32, cameraY : f32, scaleData : ScaleData)
{
	using raylib
	
	textBuffer : [64]u8
	
	startX := Timestamp_ToPixelX(selection.startTimestamp, scaleData)
	startY := Price_ToPixelY(selection.high, scaleData) 
	width := Timestamp_ToPixelX(selection.endTimestamp, scaleData) - startX
	height := Price_ToPixelY(selection.low, scaleData) - startY

	startX -= cameraX
	startY -= cameraY

	if selection.tools == nil
	{
		startPrice : f32 = ---
		endPrice : f32 = ---
		backgroundColor : Color = ---
		
		if selection.isUpsideDown
		{
			startPrice = selection.high
			endPrice = selection.low
			backgroundColor = RED
		}
		else
		{
			startPrice = selection.low
			endPrice = selection.high
			backgroundColor = GREEN
		}

		backgroundColor.a = 63
		priceDifference := endPrice - startPrice
		pricePercentage := (endPrice / startPrice) * 100 - 100
 		
		DrawRectangleRec(Rectangle{startX, startY, width, height}, backgroundColor)

		fmt.bprintf(textBuffer[:], "%.2f\x00", priceDifference)
		textSize := MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0)
		DrawTextEx(labelFont, cstring(&textBuffer[0]), Vector2{startX + (width - textSize.x) / 2, startY + height / 2 - textSize.y - 2}, LABEL_FONT_SIZE, 0, WHITE)
		
		fmt.bprintf(textBuffer[:], "%.2f%%\x00", pricePercentage)
		textSize = MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0)
		DrawTextEx(labelFont, cstring(&textBuffer[0]), Vector2{startX + (width - textSize.x) / 2, startY + height / 2 + 2}, LABEL_FONT_SIZE, 0, WHITE)
	}
	
	if .VOLUME_PROFILE in selection.tools
	{
		VolumeProfile_Draw(selection.volumeProfile, startX, width, cameraY, scaleData, 63, selection.volumeProfileDrawFlags & {.BODY})
		VolumeProfile_Draw(selection.volumeProfile, startX + width, width, cameraY, scaleData, 191, selection.volumeProfileDrawFlags - {.BODY})
	}

	if .FIB_RETRACEMENT in selection.tools &&
	   selection.draw618
	{
		priceRange := selection.high - selection.low

		pixelY : f32 = ---

		if selection.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + selection.low, scaleData) - cameraY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + selection.low, scaleData) - cameraY
		}

		fibStart := Vector2{startX + width, pixelY}
		fibEnd := Vector2{startX + width + width, pixelY}
		
		DrawLineV(fibStart, fibEnd, FIB_618_COLOR)
	}

	// Draw strategy results
	for result in selection.strategyResults
	{
		boxX := Timestamp_ToPixelX(result.entryTimestamp, scaleData)
		boxWidth := Timestamp_ToPixelX(result.exitTimestamp, scaleData) - boxX
		boxX -= cameraX
		
		entry := Price_ToPixelY(result.entry, scaleData) - cameraY

		colors := [2]Color{RED, GREEN}
		
		if boxWidth < 5
		{
			// Draw circle
			DrawRectangleRec(Rectangle{boxX - 1, entry - 2, 3, 5}, WHITE)
			DrawRectangleRec(Rectangle{boxX - 2, entry - 1, 5, 3}, WHITE)
			DrawRectangleRec(Rectangle{boxX - 1, entry - 1, 3, 3}, colors[int(result.isWin)])
		}
		else
		{
			// Draw position
			target := Price_ToPixelY(result.target, scaleData) - cameraY
			stopLoss := Price_ToPixelY(result.stopLoss, scaleData) - cameraY

			red := RED
			red.a = 63
			green := GREEN
			green.a = 63

			// Long
			if result.target > result.stopLoss
			{
				boxHeight := entry - target
				DrawRectangleRec(Rectangle{boxX, target, boxWidth, boxHeight}, green)

				boxHeight = stopLoss - entry
				DrawRectangleRec(Rectangle{boxX, entry, boxWidth, boxHeight}, red)
	 		}
			else // Short
			{
				boxHeight := entry - stopLoss
				DrawRectangleRec(Rectangle{boxX, stopLoss, boxWidth, boxHeight}, red)

				boxHeight = target - entry
				DrawRectangleRec(Rectangle{boxX, entry, boxWidth, boxHeight}, green)
			}

			outlineY := math.min(stopLoss, target)
			outlineHeight := math.max(target, stopLoss) - outlineY

			DrawRectangleLinesEx(Rectangle{boxX, outlineY, boxWidth, outlineHeight}, 1, colors[int(result.isWin)])
		}
	}

	// Draw PNL
	if len(selection.strategyResults) > 0
	{
		wins : f32 = f32(int(selection.strategyResults[0].isWin))
		losses : f32 = f32(int(!selection.strategyResults[0].isWin))
		pnl : f32 = 1

		topY := Price_ToPixelY(selection.high, scaleData) - cameraY
		bottomY := Price_ToPixelY(selection.low, scaleData) - cameraY

		tradeStart := Vector2 \
		{ \
			Timestamp_ToPixelX(selection.strategyResults[0].exitTimestamp, scaleData) - cameraX, \
			topY + (bottomY - topY) * (1 - pnl) \
		}

		for result in selection.strategyResults[1:]
		{
			wins += f32(int(result.isWin))
			losses += f32(int(!result.isWin))

			pnl *= result.pnl
			
			tradeEnd := Vector2 \
			{ \
				Timestamp_ToPixelX(result.exitTimestamp, scaleData) - cameraX, \
				topY + (bottomY - topY) * (1 - pnl) \
			}

			DrawLineV(tradeStart, tradeEnd, WHITE)

			tradeStart = tradeEnd
		}

		fmt.bprintf(textBuffer[:], "PNL: %.2f%%\x00", pnl * 100)
		offsetY := MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0).y / 2
		DrawTextEx(labelFont, cstring(&textBuffer[0]), Vector2{tradeStart.x + 2, tradeStart.y - offsetY}, LABEL_FONT_SIZE, 0, WHITE)
	}
}

Selection_DrawHandles :: proc(selection : Selection, cameraX : f32, cameraY : f32, scaleData : ScaleData)
{
	using raylib
	
	posX := Timestamp_ToPixelX(selection.startTimestamp, scaleData)
	posY := Price_ToPixelY(selection.high, scaleData)
	width := Timestamp_ToPixelX(selection.endTimestamp, scaleData) - posX
	height := Price_ToPixelY(selection.low, scaleData) - posY
	DrawRectangleLinesEx(Rectangle{posX - cameraX, posY - cameraY, width, height}, 1, {255, 255, 255, 255})

	if .VOLUME_PROFILE in selection.tools
	{
		DrawCircleV(Vector2{posX - cameraX, VolumeProfile_BucketToPixelY(selection.volumeProfile, selection.volumeProfile.pocIndex, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, VOLUME_PROFILE_BUY_COLOR)
		DrawCircleV(Vector2{posX + width - cameraX, VolumeProfile_BucketToPixelY(selection.volumeProfile, selection.volumeProfile.pocIndex, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, POC_COLOR)
		DrawCircleV(Vector2{posX + width - cameraX, VolumeProfile_BucketToPixelY(selection.volumeProfile, selection.volumeProfile.valIndex, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, VAL_COLOR)
		DrawCircleV(Vector2{posX + width - cameraX, VolumeProfile_BucketToPixelY(selection.volumeProfile, selection.volumeProfile.vahIndex, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, VAH_COLOR)
		DrawCircleV(Vector2{posX + width - cameraX, VolumeProfile_BucketToPixelY(selection.volumeProfile, selection.volumeProfile.tvValIndex, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, TV_VAL_COLOR)
		DrawCircleV(Vector2{posX + width - cameraX, VolumeProfile_BucketToPixelY(selection.volumeProfile, selection.volumeProfile.tvVahIndex, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, TV_VAH_COLOR)
		DrawCircleV(Vector2{posX + width - cameraX, Price_ToPixelY(selection.volumeProfile.vwap, scaleData) - cameraY}, LEVEL_CIRCLE_RADIUS, VWAP_COLOR)
	}
	
	if .FIB_RETRACEMENT in selection.tools
	{
		priceRange := selection.high - selection.low

		pixelY : f32 = ---

		if selection.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + selection.low, scaleData) - cameraY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + selection.low, scaleData) - cameraY
		}

		DrawCircleV(Vector2{posX + width - cameraX, pixelY}, LEVEL_CIRCLE_RADIUS, FIB_618_COLOR)
	}

	// Hotbar
	HOTBAR_COLOR :: raylib.Color{30, 34, 45, 255}
	HOTBAR_SELECTED_COLOR :: raylib.Color{42, 46, 57, 255}
	
	hotbarPos := Selection_GetHotbarPos(selection, cameraX, cameraY, scaleData)

	DrawRectangleRounded({hotbarPos.x, hotbarPos.y, HOTBAR_WIDTH, HOTBAR_HEIGHT}, HOTBAR_ROUNDING, 16, HOTBAR_COLOR)

	cell := Vector2{hotbarPos.x + HOTBAR_SPACING, hotbarPos.y + HOTBAR_SPACING}

	if .VOLUME_PROFILE in selection.tools
	{
		DrawRectangleRounded({cell.x, cell.y, HOTBAR_CELL_SIZE, HOTBAR_CELL_SIZE}, HOTBAR_ROUNDING, 16, HOTBAR_SELECTED_COLOR)
	}

	DrawTextureV(volumeProfileIcon, cell, WHITE)

	cell.x += HOTBAR_CELL_SIZE + HOTBAR_SPACING

	if .FIB_RETRACEMENT in selection.tools
	{
		DrawRectangleRounded({cell.x, cell.y, HOTBAR_CELL_SIZE, HOTBAR_CELL_SIZE}, HOTBAR_ROUNDING, 16, HOTBAR_SELECTED_COLOR)
	}
	
	DrawTextureV(fibRetracementIcon, cell, WHITE)
}
