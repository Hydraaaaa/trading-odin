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

	draw618 : bool,

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
Multitool_IsOverlappingPoint :: proc(multitool : Multitool, posX : f32, posY : f32, scaleData : ScaleData) -> bool
{
	if !Multitool_IsOverlappingRect(multitool, posX, posY, 1, 1, scaleData)
	{
		return false
	}
	
	multitoolStartPosX := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	multitoolEndPosX := Timestamp_ToPixelX(multitool.endTimestamp, scaleData)

	if .FIB_RETRACEMENT in multitool.tools &&
	   multitool.draw618
	{
		priceRange := multitool.high - multitool.low

		pixelY : f32 = ---
		
		if multitool.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData)
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData)
		}
		
		if posX >= multitoolEndPosX &&
		   posY >= pixelY - LINE_SELECTION_THICKNESS &&
		   posY < pixelY + LINE_SELECTION_THICKNESS
		{
			return true
		}
	}

	if .VOLUME_PROFILE in multitool.tools
	{
		// If hovering the right side of the profile, compare against value area lines etc
		if posX > multitoolEndPosX
		{
			bucketIndices := []int{multitool.volumeProfile.pocIndex, multitool.volumeProfile.vahIndex, multitool.volumeProfile.valIndex, multitool.volumeProfile.tvVahIndex, multitool.volumeProfile.tvValIndex }
			drawFlags := []VolumeProfile_DrawFlag{.POC, .VAH, .VAL, .TV_VAH, .TV_VAL}

			for bucketIndex, index in bucketIndices
			{
				if drawFlags[index] not_in multitool.volumeProfileDrawFlags
				{
					continue
				}
			
				bucketStartPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, bucketIndex, scaleData, true)
				bucketEndPixel := VolumeProfile_BucketToPixelY(multitool.volumeProfile, bucketIndex + 1, scaleData, true)

				bucketThickness := math.max(bucketStartPixel - bucketEndPixel, 1)

				if posY >= bucketEndPixel && posY < bucketEndPixel + bucketThickness ||
				   bucketThickness == 1 && math.abs(posY - bucketStartPixel) < LINE_SELECTION_THICKNESS
				{
					return true
				}
			}

			// Check overlap with VWAP
			return .VWAP in multitool.volumeProfileDrawFlags &&
			       math.abs(posY - Price_ToPixelY(multitool.volumeProfile.vwap, scaleData)) < LINE_SELECTION_THICKNESS
		}

		// Compare against the profile itself
		if .BODY not_in multitool.volumeProfileDrawFlags ||
		   !Multitool_IsVolumeProfileBodyOverlappingRect(multitool, posX, posY, 1, 1, scaleData)
		{
			return false
		}
	
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

		return posX <= multitoolStartPosX + width * (volume / highestBucketVolume)
	}

	return false
}

// Approximate, used for culling
Multitool_IsOverlappingRect :: proc(multitool : Multitool, posX : f32, posY : f32, width : f32, height : f32, scaleData : ScaleData) -> bool
{
	start := Timestamp_FromPixelX(posX, scaleData)
	end := Timestamp_FromPixelX(posX + width, scaleData)
	high := Price_FromPixelY(posY, scaleData)
	low := Price_FromPixelY(posY + height, scaleData)

	multitoolStart := multitool.startTimestamp
	multitoolEnd := multitool.endTimestamp + (multitool.endTimestamp - multitool.startTimestamp)
	multitoolHigh := math.max(multitool.high, multitool.volumeProfile.bottomPrice + f32(len(multitool.volumeProfile.buckets)) * multitool.volumeProfile.bucketSize)
	multitoolLow := math.min(multitool.low, multitool.volumeProfile.bottomPrice)

	return !(multitoolHigh < low ||
	         multitoolLow > high ||
	         multitoolStart > end ||
	         multitoolEnd < start)
}

// Approximate, used for culling  
Multitool_IsVolumeProfileBodyOverlappingRect :: proc(multitool : Multitool, posX : f32, posY : f32, width : f32, height : f32, scaleData : ScaleData) -> bool
{
	start := Timestamp_FromPixelX(posX, scaleData)
	end := Timestamp_FromPixelX(posX + width, scaleData)
	high := Price_FromPixelY(posY, scaleData)
	low := Price_FromPixelY(posY + height, scaleData)

	profileStart := multitool.startTimestamp
	profileEnd := multitool.endTimestamp
	profileHigh := multitool.volumeProfile.bottomPrice + f32(len(multitool.volumeProfile.buckets)) * multitool.volumeProfile.bucketSize
	profileLow := multitool.volumeProfile.bottomPrice

	return !(profileHigh < low ||
	         profileLow > high ||
	         profileStart > end ||
	         profileEnd < start)
}

Multitool_Draw :: proc(multitool : Multitool, cameraPosX : f32, cameraPosY : f32, scaleData : ScaleData)
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
 		
		DrawRectangleRec(Rectangle{startX, startY, width, height}, backgroundColor)

		fmt.bprintf(textBuffer[:], "%.2f\x00", priceDifference)
		textSize := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
		DrawTextEx(font, cstring(&textBuffer[0]), Vector2{startX + (width - textSize.x) / 2, startY + height / 2 - textSize.y - 2}, FONT_SIZE, 0, WHITE)
		
		fmt.bprintf(textBuffer[:], "%.2f%%\x00", pricePercentage)
		textSize = MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0)
		DrawTextEx(font, cstring(&textBuffer[0]), Vector2{startX + (width - textSize.x) / 2, startY + height / 2 + 2}, FONT_SIZE, 0, WHITE)
	}
	
	if .VOLUME_PROFILE in multitool.tools
	{
		VolumeProfile_Draw(multitool.volumeProfile, startX, width, cameraPosY, scaleData, 63, multitool.volumeProfileDrawFlags & {.BODY})
		VolumeProfile_Draw(multitool.volumeProfile, startX + width, width, cameraPosY, scaleData, 191, multitool.volumeProfileDrawFlags - {.BODY})
	}

	if .FIB_RETRACEMENT in multitool.tools &&
	   multitool.draw618
	{
		priceRange := multitool.high - multitool.low

		pixelY : f32 = ---

		if multitool.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData) - cameraPosY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData) - cameraPosY
		}

		fibStart := Vector2{startX + width, pixelY}
		fibEnd := Vector2{startX + width + width, pixelY}
		
		DrawLineV(fibStart, fibEnd, FIB_618_COLOR)
	}

	// Draw strategy results
	for result in multitool.strategyResults
	{
		boxX := Timestamp_ToPixelX(result.entryTimestamp, scaleData)
		boxWidth := Timestamp_ToPixelX(result.exitTimestamp, scaleData) - boxX
		boxX -= cameraPosX
		
		entry := Price_ToPixelY(result.entry, scaleData) - cameraPosY

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
			target := Price_ToPixelY(result.target, scaleData) - cameraPosY
			stopLoss := Price_ToPixelY(result.stopLoss, scaleData) - cameraPosY

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

	// Draw strategy winrate
	if len(multitool.strategyResults) > 0
	{
		wins : f32 = f32(int(multitool.strategyResults[0].isWin))
		losses : f32 = f32(int(!multitool.strategyResults[0].isWin))
		winrate : f32 = wins / (wins + losses)

		topY := Price_ToPixelY(multitool.high, scaleData) - cameraPosY
		bottomY := Price_ToPixelY(multitool.low, scaleData) - cameraPosY
		
		tradeStart := Vector2 \
		{ \
			Timestamp_ToPixelX(multitool.strategyResults[0].exitTimestamp, scaleData) - cameraPosX, \
			topY + (bottomY - topY) * (1 - winrate) \
		}

		for _, index in multitool.strategyResults[1:]
		{
			wins += f32(int(multitool.strategyResults[index].isWin))
			losses += f32(int(!multitool.strategyResults[index].isWin))
			winrate = wins / (wins + losses)

			tradeEnd := Vector2 \
			{ \
				Timestamp_ToPixelX(multitool.strategyResults[index].exitTimestamp, scaleData) - cameraPosX, \
				topY + (bottomY - topY) * (1 - winrate) \
			}

			DrawLineV(tradeStart, tradeEnd, WHITE)

			tradeStart = tradeEnd
		}

		fmt.bprintf(textBuffer[:], "%.2f%%\x00", winrate)
		offsetY := MeasureTextEx(font, cstring(&textBuffer[0]), FONT_SIZE, 0).y / 2
		DrawTextEx(font, cstring(&textBuffer[0]), Vector2{tradeStart.x + 2, tradeStart.y - offsetY}, FONT_SIZE, 0, WHITE)
	}
}

Multitool_DrawHandles :: proc(multitool : Multitool, cameraPosX : f32, cameraPosY : f32, scaleData : ScaleData)
{
	using raylib
	
	posX := Timestamp_ToPixelX(multitool.startTimestamp, scaleData)
	posY := Price_ToPixelY(multitool.high, scaleData)
	width := Timestamp_ToPixelX(multitool.endTimestamp, scaleData) - posX
	height := Price_ToPixelY(multitool.low, scaleData) - posY
	DrawRectangleLinesEx(Rectangle{posX - cameraPosX, posY - cameraPosY, width, height}, 1, {255, 255, 255, 255})

	if .VOLUME_PROFILE in multitool.tools
	{
		DrawCircleV(Vector2{posX - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.pocIndex, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, VOLUME_PROFILE_BUY_COLOR)
		DrawCircleV(Vector2{posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.pocIndex, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, POC_COLOR)
		DrawCircleV(Vector2{posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.valIndex, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, VAL_COLOR)
		DrawCircleV(Vector2{posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.vahIndex, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, VAH_COLOR)
		DrawCircleV(Vector2{posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.tvValIndex, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, TV_VAL_COLOR)
		DrawCircleV(Vector2{posX + width - cameraPosX, VolumeProfile_BucketToPixelY(multitool.volumeProfile, multitool.volumeProfile.tvVahIndex, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, TV_VAH_COLOR)
		DrawCircleV(Vector2{posX + width - cameraPosX, Price_ToPixelY(multitool.volumeProfile.vwap, scaleData) - cameraPosY}, LEVEL_CIRCLE_RADIUS, VWAP_COLOR)
	}
	
	if .FIB_RETRACEMENT in multitool.tools
	{
		priceRange := multitool.high - multitool.low

		pixelY : f32 = ---

		if multitool.isUpsideDown
		{
			pixelY = Price_ToPixelY(priceRange * 0.618 + multitool.low, scaleData) - cameraPosY
		}
		else
		{
			pixelY = Price_ToPixelY(priceRange * (1 - 0.618) + multitool.low, scaleData) - cameraPosY
		}

		DrawCircleV(Vector2{posX + width - cameraPosX, pixelY}, LEVEL_CIRCLE_RADIUS, FIB_618_COLOR)
	}

	// Hotbar
	HOTBAR_COLOR :: raylib.Color{30, 34, 45, 255}
	HOTBAR_SELECTED_COLOR :: raylib.Color{42, 46, 57, 255}
	HOTBAR_PADDING :: 8

	hotbarX : f32 = posX + width / 2 - HOTBAR_WIDTH / 2 - cameraPosX
	hotbarY : f32 = ---

	// If multitool is too small
	if width < HOTBAR_WIDTH + HOTBAR_PADDING * 2 ||
	   height < HOTBAR_HEIGHT + HOTBAR_PADDING * 2
	{
		// Place hotbar below multitool
		hotbarY = posY + height + HOTBAR_PADDING - cameraPosY
	}
	else
	{
		// Place hotbar inside multitool
		hotbarY = posY + height - HOTBAR_HEIGHT - HOTBAR_PADDING - cameraPosY
		
		// Clamp to screen bounds
		hotbarX = math.clamp(hotbarX, HOTBAR_PADDING, f32(GetScreenWidth()) - HOTBAR_PADDING - HOTBAR_WIDTH - 60)
		hotbarY = math.clamp(hotbarY, HOTBAR_PADDING, f32(GetScreenHeight()) - HOTBAR_PADDING - HOTBAR_HEIGHT - labelHeight)

		// Clamp to multitool bounds
		hotbarX = math.clamp(hotbarX, posX - cameraPosX + HOTBAR_PADDING, posX + width - cameraPosX - HOTBAR_WIDTH - HOTBAR_PADDING)
		hotbarY = math.clamp(hotbarY, posY - cameraPosY + HOTBAR_PADDING, posY + height - cameraPosY - HOTBAR_HEIGHT - HOTBAR_PADDING)
	}

	DrawRectangleRounded({hotbarX, hotbarY, HOTBAR_WIDTH, HOTBAR_HEIGHT}, HOTBAR_ROUNDING, 16, HOTBAR_COLOR)

	cell := Vector2{hotbarX + HOTBAR_SPACING, hotbarY + HOTBAR_SPACING}

	if .VOLUME_PROFILE in multitool.tools
	{
		DrawRectangleRounded({cell.x, cell.y, HOTBAR_CELL_SIZE, HOTBAR_CELL_SIZE}, HOTBAR_ROUNDING, 16, HOTBAR_SELECTED_COLOR)
	}

	DrawTextureV(volumeProfileIcon, cell, WHITE)

	cell.x += HOTBAR_CELL_SIZE + HOTBAR_SPACING

	if .FIB_RETRACEMENT in multitool.tools
	{
		DrawRectangleRounded({cell.x, cell.y, HOTBAR_CELL_SIZE, HOTBAR_CELL_SIZE}, HOTBAR_ROUNDING, 16, HOTBAR_SELECTED_COLOR)
	}
	
	DrawTextureV(fibRetracementIcon, cell, WHITE)
}

Multitool_HandleAt :: proc(multitool : Multitool, posX : f32, posY : f32, scaleData : ScaleData) -> MultitoolHandle
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

	if posX >= hotbarX &&
	   posX < hotbarX + HOTBAR_WIDTH &&
	   posY >= hotbarY &&
	   posY < hotbarY + HOTBAR_HEIGHT
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
	
	if .FIB_RETRACEMENT in multitool.tools
	{
		levelY : f32 = ---

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
