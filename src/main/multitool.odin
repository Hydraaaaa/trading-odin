package main

import "core:fmt"
import "core:math"

import "vendor:raylib"

LEVEL_CIRCLE_RADIUS :: 5
FIB_618_COLOR :: raylib.Color{255, 255, 127, 255}

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

Multitool :: struct
{
	startTimestamp : i32,
	endTimestamp : i32,
	high : f32,
	low  : f32,
	isUpsideDown : bool,

	tools : ToolSet,

    volumeProfile : VolumeProfile,
    volumeProfileDrawFlags : VolumeProfile_DrawFlagSet,

	strategyResults : [dynamic]Result,
}

MultitoolHandle :: enum
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

Multitool_Destroy :: proc(multitool : Multitool)
{
    VolumeProfile_Destroy(multitool.volumeProfile)
}

Multitool_IsOverlapping :: proc{Multitool_IsOverlappingPoint, Multitool_IsOverlappingRect}

// Precise, used for cursor
Multitool_IsOverlappingPoint :: proc(multitool : Multitool, posX : i32, posY : i32, scaleData : ScaleData) -> bool
{
	if !Multitool_IsOverlappingRect(multitool, posX, posY, 0, 0, scaleData)
	{
		return false
	}

	multitoolStartPosX := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	multitoolEndPosX := Timestamp_ToPixelX(multitool.endTimestamp, scaleData)

	// If hovering the right side of the profile, compare against value area lines etc
	if posX > multitoolEndPosX
	{
		bucketIndices := []int{multitool.volumeProfile.pocIndex, multitool.volumeProfile.vahIndex, multitool.volumeProfile.valIndex, multitool.volumeProfile.tvVahIndex, multitool.volumeProfile.tvValIndex }

		for index in bucketIndices
		{
			bucketStartPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, index, scaleData)
			bucketEndPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, index + 1, scaleData)

			bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

			if posY >= bucketEndPixel && posY < bucketEndPixel + bucketThickness ||
			   bucketThickness == 1 && math.abs(posY - bucketStartPixel) < 3
			{
				return true
			}
		}

		// Check overlap with VWAP
		return math.abs(posY - Price_ToPixelY(multitool.volumeProfile.vwap, scaleData)) < 3
	}

	// Compare against the profile itself

	width := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - Timestamp_ToPixelX(multitool.startTimestamp, scaleData)

	bucketIndex := VolumeProfile_PixelYToBucket(multitool.volumeProfile, posY, scaleData)

	volume := multitool.volumeProfile.buckets[bucketIndex].buyVolume + multitool.volumeProfile.buckets[bucketIndex].sellVolume

	startBucketPixel := posY
	currentBucketPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, bucketIndex + 1, scaleData)

	// If there are multiple buckets within one pixel, only draw the biggest
	for currentBucketPixel == startBucketPixel &&
		bucketIndex < len(multitool.volumeProfile.buckets) - 1
	{
		bucketIndex += 1

		volume = math.max(volume, multitool.volumeProfile.buckets[bucketIndex].buyVolume + multitool.volumeProfile.buckets[bucketIndex].sellVolume)

		currentBucketPixel = VolumeProfile_BucketToPixelY(multitool.volumeProfile, bucketIndex + 1, scaleData)
	}

	highestBucketVolume := multitool.volumeProfile.buckets[multitool.volumeProfile.pocIndex].buyVolume + multitool.volumeProfile.buckets[multitool.volumeProfile.pocIndex].sellVolume

	return posX <= multitoolStartPosX + i32(f32(width) * (volume / highestBucketVolume))
}

// Approximate, used for culling
Multitool_IsOverlappingRect :: proc(multitool : Multitool, posX : i32, posY : i32, width : i32, height : i32, scaleData : ScaleData) -> bool
{
	startTimestamp := Timestamp_FromPixelX(posX, scaleData)
	endTimestamp := Timestamp_FromPixelX(posX + width, scaleData)
	high := Price_FromPixelY(posY, scaleData)
	low := Price_FromPixelY(posY + height, scaleData)

	profileHigh := multitool.volumeProfile.bottomPrice + f32(len(multitool.volumeProfile.buckets)) * multitool.volumeProfile.bucketSize
	profileLow := multitool.volumeProfile.bottomPrice

	// TODO: Depends on if VolumeProfile is active
	return profileHigh >= low &&
	       profileLow <= high &&
	       multitool.startTimestamp <= endTimestamp &&
	       multitool.endTimestamp + (multitool.endTimestamp - multitool.startTimestamp) >= startTimestamp
}

Multitool_Draw :: proc(multitool : Multitool, cameraPosX : i32, cameraPosY : i32, scaleData : ScaleData)
{
	using raylib
	
	textBuffer : [64]u8
	
	startX := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	startY := Price_ToPixelY(multitool.high, scaleData) 
	width := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - startX
	height := Price_ToPixelY(multitool.low, scaleData) - startY

	startX -= cameraPosX
	startY -= cameraPosY

	if multitool.tools == nil
	{
		startPrice : f32 = ---
		endPrice : f32 = ---
		backgroundColor : Color = ---
		
		if multitool.isUpsideDown
		{
			startPrice = multitool.high
			endPrice = multitool.low
			backgroundColor = RED
		}
		else
		{
			startPrice = multitool.low
			endPrice = multitool.high
			backgroundColor = GREEN
		}

		backgroundColor.a = 63
		priceDifference := endPrice - startPrice
		pricePercentage := (endPrice / startPrice) * 100 - 100
 		
		DrawRectangle(startX, startY, width, height, backgroundColor)

		fmt.bprintf(textBuffer[:], "%.2f\x00", priceDifference)
		textSize := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
		DrawTextEx(font, cstring(&textBuffer[0]), Vector2{f32(startX) + (f32(width) - textSize.x) / 2, f32(startY + height / 2) - textSize.y - 2}, FONT_SIZE, 0, WHITE)
		
		fmt.bprintf(textBuffer[:], "%.2f%%\x00", pricePercentage)
		textSize = MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
		DrawTextEx(font, cstring(&textBuffer[0]), Vector2{f32(startX) + (f32(width) - textSize.x) / 2, f32(startY + height / 2) + 2}, FONT_SIZE, 0, WHITE)
	}
	
	if .VOLUME_PROFILE in multitool.tools
	{
		VolumeProfile_Draw(multitool.volumeProfile, startX, width, cameraPosY, scaleData, 63, multitool.volumeProfileDrawFlags & {.BODY})
		VolumeProfile_Draw(multitool.volumeProfile, startX + width, width, cameraPosY, scaleData, 191, multitool.volumeProfileDrawFlags - {.BODY})
	}

	if .FIB_RETRACEMENT in multitool.tools
	{
		priceRange := multitool.high - multitool.low

		fibStartX := startX + width - cameraPosX
		fibEndX := startX + width + width - cameraPosX

		pixelY : i32 = ---

		if multitool.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData) - cameraPosY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData) - cameraPosY
		}
		
		DrawLine(fibStartX, pixelY, fibEndX, pixelY, FIB_618_COLOR)
	}

	// Draw strategy results
	for result in multitool.strategyResults
	{
		boxX := Timestamp_ToPixelX(result.entryTimestamp, scaleData)
		boxWidth := Timestamp_ToPixelX(result.exitTimestamp, scaleData) - boxX
		boxX -= cameraPosX

		if boxWidth == 0
		{
			continue
		}

		target := Price_ToPixelY(result.target, scaleData)
		entry := Price_ToPixelY(result.entry, scaleData)
		stopLoss := Price_ToPixelY(result.stopLoss, scaleData)

		red := RED
		red.a = 63
		green := GREEN
		green.a = 63

		// Long
		if result.target > result.stopLoss
		{
			boxY := target - cameraPosY
			boxHeight := entry - target

			DrawRectangle(boxX, boxY, boxWidth, boxHeight, green)

			boxY = entry - cameraPosY
			boxHeight = stopLoss - entry
			
			DrawRectangle(boxX, boxY, boxWidth, boxHeight, red)
 		}
		else // Short
		{
			boxY := stopLoss - cameraPosY
			boxHeight := entry - stopLoss

			DrawRectangle(boxX, boxY, boxWidth, boxHeight, red)

			boxY = entry - cameraPosY
			boxHeight = target - entry
			
			DrawRectangle(boxX, boxY, boxWidth, boxHeight, green)
		}
	}

	// Draw strategy winrate
	if len(multitool.strategyResults) > 0
	{
		wins : f32 = f32(int(multitool.strategyResults[0].isWin))
		losses : f32 = f32(int(!multitool.strategyResults[0].isWin))
		winrate : f32 = wins / (wins + losses)

		topY := Price_ToPixelY(multitool.high, scaleData) - cameraPosY
		bottomY := Price_ToPixelY(multitool.low, scaleData) - cameraPosY
		
		tradeStartX := Timestamp_ToPixelX(multitool.strategyResults[0].exitTimestamp, scaleData) - cameraPosX
		tradeStartY := topY + i32(f32(bottomY - topY) * (1 - winrate))

		for _, index in multitool.strategyResults[1:]
		{
			wins += f32(int(multitool.strategyResults[index].isWin))
			losses += f32(int(!multitool.strategyResults[index].isWin))
			winrate = wins / (wins + losses)

			tradeEndX := Timestamp_ToPixelX(multitool.strategyResults[index].exitTimestamp, scaleData) - cameraPosX
			tradeEndY := topY + i32(f32(bottomY - topY) * (1 - winrate))

			DrawLine(tradeStartX, tradeStartY, tradeEndX, tradeEndY, WHITE)

			tradeStartX = tradeEndX
			tradeStartY = tradeEndY
		}

		fmt.bprintf(textBuffer[:], "%.2f%%\x00", winrate)
		offsetY := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0).y / 2
		DrawTextEx(font, cstring(&textBuffer[0]), Vector2{f32(tradeStartX + 2), f32(tradeStartY) - offsetY}, FONT_SIZE, 0, WHITE)
	}
}

Multitool_DrawHandles :: proc(multitool : Multitool, cameraPosX : i32, cameraPosY : i32, scaleData : ScaleData)
{
	using raylib
	
	posX := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	posY := Price_ToPixelY(multitool.high, scaleData)
	width := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - posX
	height := Price_ToPixelY(multitool.low, scaleData) - posY
	DrawRectangleLines(posX - cameraPosX, posY - cameraPosY, width, height, {255, 255, 255, 255})

	if .VOLUME_PROFILE in multitool.tools
	{
		DrawCircle(posX - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.pocIndex, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, VOLUME_PROFILE_BUY_COLOR)
		DrawCircle(posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.pocIndex, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, POC_COLOR)
		DrawCircle(posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.valIndex, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, VAL_COLOR)
		DrawCircle(posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.vahIndex, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, VAH_COLOR)
		DrawCircle(posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.tvValIndex, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, TV_VAL_COLOR)
		DrawCircle(posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.tvVahIndex, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, TV_VAH_COLOR)
		DrawCircle(posX + width - cameraPosX, Price_ToPixelY(multitool.volumeProfile.vwap, scaleData) - cameraPosY, LEVEL_CIRCLE_RADIUS, VWAP_COLOR)
	}
	
	if .FIB_RETRACEMENT in multitool.tools
	{
		priceRange := multitool.high - multitool.low

		pixelY : i32 = ---

		if multitool.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData) - cameraPosY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData) - cameraPosY
		}

		DrawCircle(posX + width - cameraPosX, pixelY, LEVEL_CIRCLE_RADIUS, {255, 255, 127, 255})
	}

	// Hotbar
	HOTBAR_COLOR :: raylib.Color{30, 34, 45, 255}
	HOTBAR_SELECTED_COLOR :: raylib.Color{42, 46, 57, 255}

	hotbarX := posX + width / 2 - HOTBAR_WIDTH / 2 - cameraPosX
	hotbarY := posY + height - HOTBAR_HEIGHT - 8 - cameraPosY

	DrawRectangleRounded({f32(hotbarX), f32(hotbarY), HOTBAR_WIDTH, HOTBAR_HEIGHT}, HOTBAR_ROUNDING, 16, HOTBAR_COLOR)

	cellX := hotbarX + HOTBAR_SPACING
	cellY := hotbarY + HOTBAR_SPACING

	if .VOLUME_PROFILE in multitool.tools
	{
		DrawRectangleRounded({f32(cellX), f32(cellY), HOTBAR_CELL_SIZE, HOTBAR_CELL_SIZE}, HOTBAR_ROUNDING, 16, HOTBAR_SELECTED_COLOR)
	}

	DrawTexture(volumeProfileIcon, cellX, cellY, WHITE)

	cellX += HOTBAR_CELL_SIZE + HOTBAR_SPACING

	if .FIB_RETRACEMENT in multitool.tools
	{
		DrawRectangleRounded({f32(cellX), f32(cellY), HOTBAR_CELL_SIZE, HOTBAR_CELL_SIZE}, HOTBAR_ROUNDING, 16, HOTBAR_SELECTED_COLOR)
	}
	
	DrawTexture(fibRetracementIcon, cellX, cellY, WHITE)
}

Multitool_HandleAt :: proc(multitool : Multitool, posX : i32, posY : i32, scaleData : ScaleData) -> MultitoolHandle
{
	SQR_RADIUS :: LEVEL_CIRCLE_RADIUS * LEVEL_CIRCLE_RADIUS
	
	leftPos := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	rightPos := Timestamp_ToPixelX(multitool.endTimestamp, scaleData)
	topPos := Price_ToPixelY(multitool.high, scaleData)
	bottomPos := Price_ToPixelY(multitool.low, scaleData)
	width := rightPos - leftPos
	height := bottomPos - topPos
	
	// Hotbar
	hotbarX := leftPos + width / 2 - HOTBAR_WIDTH / 2
	hotbarY := topPos + height - HOTBAR_HEIGHT - 8

	if posX >= leftPos &&
	   posX < rightPos &&
	   posY >= topPos &&
	   posY < bottomPos
	{
		cellX := hotbarX + HOTBAR_SPACING
		cellY := hotbarY + HOTBAR_SPACING

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

	if .VOLUME_PROFILE in multitool.tools
	{
		// Right side of profile
		levelY := Price_ToPixelY(multitool.volumeProfile.vwap, scaleData)
		distY := levelY - posY
		if distY * distY < targetSqrDistY { return .VWAP }
		
		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.pocIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .POC }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.valIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .VAL }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.vahIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .VAH }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.tvValIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .TV_VAL }

		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.tvVahIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .TV_VAH }

		// Left side of profile
		distX = leftPos - posX
		targetSqrDistY = SQR_RADIUS - distX * distX
		
		levelY = Price_ToPixelY(VolumeProfile_BucketToPrice(multitool.volumeProfile, multitool.volumeProfile.pocIndex), scaleData)
		distY = levelY - posY
		if distY * distY < targetSqrDistY { return .VOLUME_PROFILE_BODY }

	}

	if .FIB_RETRACEMENT in multitool.tools
	{
		levelY : i32 = ---

		priceRange := multitool.high - multitool.low

		if multitool.isUpsideDown
		{
			levelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData)
		}
		else
		{
			levelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData)
		}

		distY := levelY - posY
		if distY * distY < targetSqrDistY { return .FIB_618 }
	}

	EDGE_THICKNESS :: 3

	// Corners
	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= leftPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= topPos + EDGE_THICKNESS
	{
		return .EDGE_TOPLEFT
	}

	if posX >= rightPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= topPos + EDGE_THICKNESS
	{
		return .EDGE_TOPRIGHT
	}

	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= leftPos + EDGE_THICKNESS &&
	   posY >= bottomPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .EDGE_BOTTOMLEFT
	}

	if posX >= rightPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= bottomPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .EDGE_BOTTOMRIGHT
	}

	// Edges
	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= topPos + EDGE_THICKNESS
	{
		return .EDGE_TOP
	}

	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= leftPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .EDGE_LEFT
	}

	if posX >= rightPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= topPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .EDGE_RIGHT
	}

	if posX >= leftPos - EDGE_THICKNESS &&
	   posX <= rightPos + EDGE_THICKNESS &&
	   posY >= bottomPos - EDGE_THICKNESS &&
	   posY <= bottomPos + EDGE_THICKNESS
	{
		return .EDGE_BOTTOM
	}

	return .NONE
}
