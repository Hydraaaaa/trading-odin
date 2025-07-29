package main

import "core:fmt"
import "core:math"
import "core:mem"
import rl "vendor:raylib"

PLOT_BORDER_THICKNESS :: 1

Viewport_Draw_DayOfWeek :: proc(vp : ^Viewport, chart : Chart)
{
	if vp.zoomIndex > .DAY do return
	
	// Convert current visible indices into visible day indices
	startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], vp.cameraTimestamp) - 1
	endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], vp.cameraEndTimestamp) + 1
	
	for i in startIndex ..< endIndex
	{
		startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i), vp.scaleData)
		endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 1, vp.scaleData)

		colors := [7]rl.Color{rl.RED, rl.GREEN, rl.YELLOW, rl.PURPLE, rl.BLUE, rl.GRAY, rl.WHITE}
		colors[0].a = 31; colors[1].a = 31; colors[2].a = 31; colors[3].a = 31; colors[4].a = 31; colors[5].a = 31; colors[6].a = 31;

		dayOfWeek := Timestamp_ToDayOfWeek(CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i)))

		rl.DrawRectangleRec(rl.Rectangle{startPixel - vp.camera.x, 0, endPixel - startPixel, vp.rect.height}, colors[dayOfWeek])
	}
}

Viewport_Draw_Sessions :: proc(vp : ^Viewport, chart : Chart)
{
	if vp.zoomIndex > .MINUTE_30 do return

	timeframeIncrements := TIMEFRAME_INCREMENTS
	
	// - 1 because when index goes negative, it's suddenly off by one
	startIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], vp.cameraTimestamp) - 1
	endIndex := CandleList_TimestampToIndex(chart.candles[Timeframe.DAY], vp.cameraEndTimestamp) + 1
	
	asia := rl.RED
	asia.a = 31
	london := rl.YELLOW
	london.a = 31
	newYork := rl.BLUE
	newYork.a = 31

	for i in startIndex ..< endIndex
	{
		startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
		asiaStart := Timestamp_ToPixelX(startTimestamp, vp.scaleData)
		asiaLength := Timestamp_ToPixelX(1800 * 16, vp.scaleData)
		londonStart := asiaStart + asiaLength
		londonLength := Timestamp_ToPixelX(1800 * 17, vp.scaleData)
		newYorkStart := Timestamp_ToPixelX(startTimestamp + 1800 * 27, vp.scaleData)
		newYorkLength := Timestamp_ToPixelX(1800 * 13, vp.scaleData)

		rl.DrawRectangleRec(rl.Rectangle{asiaStart - vp.camera.x, 0, asiaLength, vp.rect.height}, asia)
		rl.DrawRectangleRec(rl.Rectangle{londonStart - vp.camera.x, 0, londonLength, vp.rect.height}, london)
		rl.DrawRectangleRec(rl.Rectangle{newYorkStart - vp.camera.x, 0, newYorkLength, vp.rect.height}, newYork)
	}
}

Viewport_Draw_HTFOutlines :: proc(vp : ^Viewport, chart : Chart)
{
	zoomIndexHTF := vp.zoomIndex + Timeframe(1)

	if zoomIndexHTF < Timeframe(TIMEFRAME_COUNT)
	{
		visibleHTFCandles, visibleHTFCandlesStartIndex := CandleList_CandlesBetweenTimestamps(chart.candles[zoomIndexHTF], vp.cameraTimestamp, vp.cameraEndTimestamp)

		outlineColors := [2]rl.Color{{0, 255, 0, 63}, {255, 0, 0, 63}}

		for candle, i in visibleHTFCandles
		{
			xPos := CandleList_IndexToPixelX(chart.candles[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, vp.scaleData) - vp.camera.x
			candleWidth := CandleList_IndexToWidth(chart.candles[zoomIndexHTF], i32(i) + visibleHTFCandlesStartIndex, vp.scaleData)

			bodyPosY := Price_ToPixelY(math.max(candle.open, candle.close), vp.scaleData)
			bodyHeight := math.max(Price_ToPixelY(math.min(candle.open, candle.close), vp.scaleData) - bodyPosY, 1)

			rl.DrawRectangleLinesEx(rl.Rectangle{xPos, bodyPosY - vp.camera.y, candleWidth, bodyHeight}, 1, outlineColors[int(candle.close <= candle.open)])
		}
	}
}

Viewport_Draw_CVD :: proc(vp : ^Viewport, chart : Chart)
{
	if len(vp.visibleCandles) == 0 do return
	
	highestCloseCandle, _ := Candle_HighestClose(vp.visibleCandles)
	lowestCloseCandle, _ := Candle_LowestClose(vp.visibleCandles)

	highestClose := math.min(highestCloseCandle.close, vp.cameraTopPrice)
	lowestClose := math.max(lowestCloseCandle.close, vp.cameraBottomPrice)

	visibleDeltas := chart.candles[vp.zoomIndex].cumulativeDelta[vp.visibleCandlesStartIndex:vp.visibleCandlesStartIndex + i32(len(vp.visibleCandles))]

	if len(visibleDeltas) == 0 do return
	
	highestPixel := Price_ToPixelY(highestClose, vp.scaleData) - f32(vp.camera.y)
	lowestPixel := Price_ToPixelY(lowestClose, vp.scaleData) - f32(vp.camera.y)
	pixelRange := highestPixel - lowestPixel

	highestDelta := visibleDeltas[0]
	lowestDelta := visibleDeltas[0]

	for delta in visibleDeltas[1:]
	{
		highestDelta = math.max(highestDelta, delta)
		lowestDelta = math.min(lowestDelta, delta)
	}

	deltaRange := highestDelta - lowestDelta

	points : []rl.Vector2 = make([]rl.Vector2, len(visibleDeltas)); defer delete(points)

	for delta, i in visibleDeltas
	{
		points[i].x = f32(CandleList_IndexToPixelX(chart.candles[vp.zoomIndex], vp.visibleCandlesStartIndex + i32(i) + 1, vp.scaleData) - vp.camera.x)
		points[i].y = f32((delta - lowestDelta) / deltaRange) * pixelRange + lowestPixel
	}

	rl.DrawLineStrip(raw_data(points[:]), i32(len(visibleDeltas)), rl.Color{255, 255, 255, 191})
}

Viewport_Draw_PDVPs :: proc(vp : ^Viewport, chart : Chart)
{
	if vp.zoomIndex > .MINUTE_30 do return

	timeframeIncrements := TIMEFRAME_INCREMENTS

	startIndex := CandleList_TimestampToIndex_Clamped(chart.candles[Timeframe.DAY], vp.cameraTimestamp - timeframeIncrements[Timeframe.DAY])
	endIndex := CandleList_TimestampToIndex_Clamped(chart.candles[Timeframe.DAY], vp.cameraEndTimestamp - timeframeIncrements[Timeframe.DAY]) + 1
	
	for i in startIndex ..< endIndex
	{
		// bucketSize is 0 if a profile hasn't been loaded yet
		if chart.dailyVolumeProfiles[i].bucketSize == 0
		{
			startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i))
			endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.DAY], i32(i) + 1)
			chart.dailyVolumeProfiles[i] = VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
		}

		startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 1, vp.scaleData)
		endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.DAY], i32(i) + 2, vp.scaleData)

		VolumeProfile_Draw(chart.dailyVolumeProfiles[i], startPixel - vp.camera.x, endPixel - startPixel, vp.camera.y, vp.scaleData, 63, {.POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
	}
}

Viewport_Draw_PWVPs :: proc(vp : ^Viewport, chart : Chart)
{
	if vp.zoomIndex > .HOUR_6 do return
	
	timeframeIncrements := TIMEFRAME_INCREMENTS

	startIndex := CandleList_TimestampToIndex_Clamped(chart.candles[Timeframe.WEEK], vp.cameraTimestamp - timeframeIncrements[Timeframe.WEEK])
	endIndex := CandleList_TimestampToIndex_Clamped(chart.candles[Timeframe.WEEK], vp.cameraEndTimestamp - timeframeIncrements[Timeframe.WEEK]) + 1
	
	for i in startIndex ..< endIndex
	{
		if chart.weeklyVolumeProfiles[i].bucketSize == 0
		{
			startTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i))
			endTimestamp := CandleList_IndexToTimestamp(chart.candles[Timeframe.WEEK], i32(i) + 1)
			chart.weeklyVolumeProfiles[i] = VolumeProfile_Create(startTimestamp, endTimestamp, chart, 25)
		}

		startPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.WEEK], i32(i) + 1, vp.scaleData)
		endPixel := CandleList_IndexToPixelX(chart.candles[Timeframe.WEEK], i32(i) + 2, vp.scaleData)

		VolumeProfile_Draw(chart.weeklyVolumeProfiles[i], startPixel - vp.camera.x, endPixel - startPixel, vp.camera.y, vp.scaleData, 95, {.POC, .VAL, .VAH, .TV_VAL, .TV_VAH, .VWAP})
	}
}

Viewport_Draw_CloseLevels :: proc(vp : ^Viewport)
{
	levelsSlice := []CandleCloseLevels{vp.dailyCloseLevels}

	for closeLevels in levelsSlice
	{
		for level in closeLevels.levels
		{
			pixelY := Price_ToPixelY(level.price, vp.scaleData) - vp.camera.y

			// endX := endTimestamp == -1 ? vp.rect.width : endTimestamp
			endX := vp.rect.width * f32(i32(level.endTimestamp == -1)) + Timestamp_ToPixelX(level.endTimestamp, vp.scaleData) - vp.camera.x * f32(i32(level.endTimestamp != -1))

			rl.DrawLineV(rl.Vector2{Timestamp_ToPixelX(level.startTimestamp, vp.scaleData) - vp.camera.x, pixelY}, rl.Vector2{endX, pixelY}, closeLevels.color)
		}
	}
}

Viewport_Draw_CursorTimestampLabel :: proc(vp : ^Viewport)
{
	cursorLabelBuffer : [32]u8

	cursorDayOfWeek := Timestamp_ToDayOfWeek(vp.cursorTimestamp)
	cursorDate := Timestamp_ToDayMonthYear(vp.cursorTimestamp)

	bufferIndex := 0

	if vp.zoomIndex < .DAY
	{
		dayTimestamp := vp.cursorTimestamp % DAY
		hours   := dayTimestamp / 3600
		minutes := dayTimestamp % 3600 / 60
		fmt.bprintf(cursorLabelBuffer[:], "%i:%2i ", hours, minutes)

		if hours >= 10
		{
			bufferIndex += 6
		}
		else
		{
			bufferIndex += 5
		}
	}

	switch cursorDayOfWeek
	{
		case .MONDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Mon ")
		case .TUESDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Tue ")
		case .WEDNESDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Wed ")
		case .THURSDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Thu ")
		case .FRIDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Fri ")
		case .SATURDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Sat ")
		case .SUNDAY: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Sun ")
	}

	bufferIndex += 4

	fmt.bprintf(cursorLabelBuffer[bufferIndex:bufferIndex + 3], "%i ", cursorDate.day)

	if cursorDate.day >= 10
	{
		bufferIndex += 3
	}
	else
	{
		bufferIndex += 2
	}

	// Setting label contents
	switch cursorDate.month
	{
		case 1: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Jan ")
		case 2: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Feb ")
		case 3: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Mar ")
		case 4: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Apr ")
		case 5: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "May ")
		case 6: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Jun ")
		case 7: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Jul ")
		case 8: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Aug ")
		case 9: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Sep ")
		case 10: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Oct ")
		case 11: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Nov ")
		case 12: fmt.bprint(cursorLabelBuffer[bufferIndex:bufferIndex + 4], "Dec ")
	}

	bufferIndex += 4

	fmt.bprintf(cursorLabelBuffer[bufferIndex:], "%i\x00", cursorDate.year % 100)

	bufferIndex += 3

	pixelX := Timestamp_ToPixelX(vp.cursorTimestamp, vp.scaleData) - vp.camera.x

	width := rl.MeasureTextEx(labelFont, cstring(&cursorLabelBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
	posX := f32(pixelX) - width / 2
	posY := f32(vp.rect.height) - f32(labelHeight)

	rl.DrawRectangleRounded({posX, posY, width, f32(labelHeight)}, 0.5, 10, rl.Color{54, 58, 69, 255})
	rl.DrawTextEx(labelFont, cstring(&cursorLabelBuffer[0]), {posX + HORIZONTAL_LABEL_PADDING, posY + VERTICAL_LABEL_PADDING}, LABEL_FONT_SIZE, 0, rl.WHITE)
}

Viewport_Draw_Sidebar :: proc(vp : ^Viewport, chart : Chart)
{
	if !(.DRAW_SIDEBAR in vp.flags)
	{
		return
	}
	
	PADDING :: 8
	
	rl.DrawRectangleRec(rl.Rectangle{vp.rect.x, vp.rect.y, SIDEBAR_WIDTH, vp.rect.height}, rl.Color{0, 0, 0, 191})
	rl.DrawRectangleRec(rl.Rectangle{vp.rect.x + SIDEBAR_WIDTH, vp.rect.y, 1, vp.rect.height}, rl.Color{255, 255, 255, 63})
	
	currentY : f32 = PADDING

	// Chart
	{
		rl.DrawTextEx(headerFont, "Chart", rl.Vector2{PADDING, currentY}, HEADER_FONT_SIZE, 0, rl.WHITE)
		currentY += HEADER_FONT_SIZE
		
		CELL_WIDTH :: (SIDEBAR_WIDTH - 16) / 2
		CELL_HEIGHT :: 20
		columnNo := 0
		logScale := vp.scaleData.logScale
		lockTimeframe := .LOCK_TIMEFRAME in vp.flags
		drawDayOfWeek := .DRAW_DAY_OF_WEEK in vp.flags
		drawSessions := .DRAW_SESSIONS in vp.flags
		drawHTFOutlines := .DRAW_HTF_OUTLINES in vp.flags
		drawPrevDayVPs := .DRAW_PREV_DAY_VPS in vp.flags
		drawPrevWeekVPs := .DRAW_PREV_WEEK_VPS in vp.flags
		drawCVD := .DRAW_CVD in vp.flags
		drawCloseLevels := .DRAW_CLOSE_LEVELS in vp.flags
		
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Log Scale", &logScale); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Lock Timeframe", &lockTimeframe); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Day of Week", &drawDayOfWeek); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Sessions", &drawSessions); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Previous Day Profiles", &drawPrevDayVPs); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Previous Week Profiles", &drawPrevWeekVPs); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "CVD Line", &drawCVD); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		rl.GuiToggle(rl.Rectangle{PADDING + f32(CELL_WIDTH * columnNo), currentY, CELL_WIDTH, CELL_HEIGHT}, "Close Levels", &drawCloseLevels); currentY += f32(CELL_HEIGHT * columnNo); columnNo ~= 1
		
		if vp.scaleData.logScale != logScale do Viewport_ToggleLogScale(vp, chart)
		if (.LOCK_TIMEFRAME in vp.flags) != lockTimeframe do vp.flags ~= {.LOCK_TIMEFRAME}; Viewport_UpdateTimeframe(vp, chart)
		if (.DRAW_DAY_OF_WEEK in vp.flags) != drawDayOfWeek do vp.flags ~= {.DRAW_DAY_OF_WEEK}
		if (.DRAW_SESSIONS in vp.flags) != drawSessions do vp.flags ~= {.DRAW_SESSIONS}
		if (.DRAW_HTF_OUTLINES in vp.flags) != drawHTFOutlines do vp.flags ~= {.DRAW_HTF_OUTLINES}
		if (.DRAW_PREV_DAY_VPS in vp.flags) != drawPrevDayVPs do vp.flags ~= {.DRAW_PREV_DAY_VPS}
		if (.DRAW_PREV_WEEK_VPS in vp.flags) != drawPrevWeekVPs do vp.flags ~= {.DRAW_PREV_WEEK_VPS}
		if (.DRAW_CVD in vp.flags) != drawCVD do vp.flags ~= {.DRAW_CVD}
		if (.DRAW_CLOSE_LEVELS in vp.flags) != drawCloseLevels do vp.flags ~= {.DRAW_CLOSE_LEVELS}
	}

	// Selection
	if vp.currentSelection != nil
	{
		rl.DrawTextEx(headerFont, "Selection", rl.Vector2{PADDING, currentY}, HEADER_FONT_SIZE, 0, rl.WHITE); currentY += HEADER_FONT_SIZE
		
		// Stats
		rl.DrawTextEx(headerFont, "Selection Stats", rl.Vector2{PADDING, currentY}, HEADER_FONT_SIZE, 0, rl.WHITE); currentY += HEADER_FONT_SIZE

		// Returns new currentY
		DrawHeatmap :: proc(currentY : f32, title : cstring, heatmap : HalfHourOfWeek_Heatmap, texture : rl.Texture, isLabelPercent : bool = false) -> f32
		{
			currentY := currentY
			rl.DrawTextEx(labelFont, title, rl.Vector2{PADDING, currentY}, LABEL_FONT_SIZE, 0, rl.WHITE)
			currentY += LABEL_FONT_SIZE
			
		    plotStartX : i32 = SIDEBAR_WIDTH - PADDING - PLOT_BORDER_THICKNESS * 2 - texture.width

		    f64bucketSize := f64(heatmap.params.bucketSize)
		    f64minValue := f64(heatmap.params.minValue)
		    f64maxValue := f64(heatmap.params.maxValue)
		    f64bucketCount := f64(heatmap.bucketCount)

		    range := f64bucketSize * f64bucketCount

		    // Adjust label increment to avoid labels overlapping
		    labelIncrement := f64bucketSize * (LABEL_FONT_SIZE - 5)

		    // Round label increment to a nice number
		    increments := [3]f64{0.25, 0.5, 1}
		    incrementIndex := 0
		    incrementMultiplier : f64 = 0.001

		    for incrementMultiplier < labelIncrement
		    {
		    	incrementMultiplier *= 10
		    }

		    for increment in increments
		    {
		    	if labelIncrement < increment * incrementMultiplier
		    	{
		    		labelIncrement = increment * incrementMultiplier
		    		break
		    	}
		    }

		    labelCount := heatmap.bucketCount / int(labelIncrement / f64bucketSize)
		    
		    labelValue := f64minValue - math.mod(f64minValue, labelIncrement)

		    if labelValue < f64minValue
		    {
		        labelValue += labelIncrement
		    }

		    // Draw labels
		    textBuffer : [64]u8

		    for labelValue < f64maxValue
		    {
		        labelHeight := i32((labelValue - f64minValue) * f64bucketCount / range)
		        
		        if isLabelPercent
		        {
			        fmt.bprintf(textBuffer[:], "%.3g%%\x00", labelValue * 100)
		        }
		        else
		        {
			        fmt.bprintf(textBuffer[:], "%.5g\x00", labelValue)
		        }
        
		        labelWidth := rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0).x
		        rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), rl.Vector2{f32(plotStartX) - labelWidth - 5, currentY + 1 + f32(i32(heatmap.bucketCount) - labelHeight - LABEL_FONT_SIZE / 2)}, LABEL_FONT_SIZE, 0, rl.WHITE)
        
		        labelValue += labelIncrement
		    }

		    // Draw Heatmap
		    texturePosX := plotStartX + PLOT_BORDER_THICKNESS
		    texturePosY := currentY + 1
			rl.DrawRectangleLinesEx({f32(plotStartX), currentY, f32(texture.width + PLOT_BORDER_THICKNESS * 2), f32(texture.height + PLOT_BORDER_THICKNESS * 2)}, 1, rl.Color{255, 255, 255, 127})
		
		    asiaColor := rl.RED
		    asiaColor.a = 63
		    londonColor := rl.YELLOW
		    londonColor.a = 63
		    newYorkColor := rl.BLUE
		    newYorkColor.a = 63
    
		    columnWidth := texture.width / 336
		    
		    asiaStart := texturePosX
		    londonStart := texturePosX + columnWidth * 16
		    newYorkStart := texturePosX + columnWidth * 27

		    asiaLength := columnWidth * 16
		    londonLength := columnWidth * 17
		    newYorkLength := columnWidth * 13

			// Draw sessions
		    for day in 0 ..< 7
		    {
		        rl.DrawRectangle(asiaStart, i32(texturePosY), asiaLength, texture.height, asiaColor)
		        rl.DrawRectangle(londonStart, i32(texturePosY), londonLength, texture.height, londonColor)
		        rl.DrawRectangle(newYorkStart, i32(texturePosY), newYorkLength, texture.height, newYorkColor)
	        
		        asiaStart += columnWidth * 48
		        londonStart += columnWidth * 48
		        newYorkStart += columnWidth * 48
			}
			
			rl.BeginShaderMode(heatmapShader)
			rl.DrawTexture(texture, texturePosX, i32(currentY + 1), rl.Color{255, 255, 255, 255})
			rl.EndShaderMode()
			
			currentY += f32(heatmap.bucketCount) + 8
			
			return currentY
		}
		
		currentY = DrawHeatmap(currentY, "Price Movement", vp.currentSelection.priceMovement, vp.priceMovementTexture)
		currentY = DrawHeatmap(currentY, "Price Movement (abs)", vp.currentSelection.priceMovementAbs, vp.priceMovementAbsTexture)
		currentY = DrawHeatmap(currentY, "Price Movement (percent)", vp.currentSelection.priceMovementPercent, vp.priceMovementPercentTexture, true)
		currentY = DrawHeatmap(currentY, "Price Movement (percent+abs)", vp.currentSelection.priceMovementPercentAbs, vp.priceMovementPercentAbsTexture, true)
	}
}
