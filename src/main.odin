package main

import "core:fmt"
import "core:strings"
import "core:math"
import "vendor:raylib"

INITIAL_SCREEN_WIDTH :: 1440
INITIAL_SCREEN_HEIGHT :: 720

ZOOM_INDEX_COUNT :: 5
START_ZOOM_INDEX :: 2

ZOOM_THRESHOLD :: 3.0
ZOOM_INCREMENT :: 1.05

main :: proc()
{
	using raylib

	SetConfigFlags({.WINDOW_RESIZABLE})

	InitWindow(INITIAL_SCREEN_WIDTH, INITIAL_SCREEN_HEIGHT, "Trading")
	defer CloseWindow()

	screenWidth : i32 = INITIAL_SCREEN_WIDTH
	screenHeight : i32 = INITIAL_SCREEN_HEIGHT

	windowedScreenWidth : i32 = 0
	windowedScreenHeight : i32 = 0
	
    SetTargetFPS(100)
	fpsString : string

	candleData : [ZOOM_INDEX_COUNT]CandleData

	LoadCandleData(&candleData[0], "1mo")
	LoadCandleData(&candleData[1], "1w")
	LoadCandleData(&candleData[2], "1d")
	LoadCandleData(&candleData[3], "4h")
	LoadCandleData(&candleData[4], "1h")

	defer for i := 0; i < ZOOM_INDEX_COUNT; i += 1
	{
		UnloadCandleData(&candleData[i])
	}

	CreateCloseLevels(&candleData[0], PURPLE)
	CreateCloseLevels(&candleData[1], YELLOW)
	CreateCloseLevels(&candleData[2], BLUE)
	CreateCloseLevels(&candleData[3], ORANGE)

	defer for i := 0; i < 4; i += 1
	{
		DestroyCloseLevels(&candleData[i])
	}

	scaleData : ScaleData

	scaleData.zoom = 1
	scaleData.horizontalScale = f32(candleData[START_ZOOM_INDEX].candles[0].scale) / (ZOOM_THRESHOLD * 2)
	scaleData.logScale = true

	cameraPosX : f32
	cameraPosY : f32

	zoomIndex := START_ZOOM_INDEX
	zoomLevel := 0
	verticalZoomLevel : f32 = 0

	showInvalidatedLevels := false

	dragging := false
	rightDragging := false

	// Set initial camera X position to show the most recent candle on the right
	{
		candle : ^Candle = &candleData[zoomIndex].candles[candleData[zoomIndex].candleCount - 1]

		cameraPosX = f32(candle.timestamp + candle.scale) / scaleData.horizontalScale - f32(INITIAL_SCREEN_WIDTH)
	}

	cameraTimestamp : i32 = i32(f32(cameraPosX) * scaleData.horizontalScale)
	cameraEndTimestamp : i32 = i32(f32(cameraPosX + INITIAL_SCREEN_WIDTH) * scaleData.horizontalScale)

	initialVerticalScale : f32

	// Set initial vertical scale to fit all initially visible candles on screen
	{
		low : f32 = 10000000
		high : f32 = 0

		for i := 1; i < candleData[zoomIndex].candleCount; i += 1
		{
			candle : ^Candle = &candleData[zoomIndex].candles[i]

			if candle.timestamp > cameraEndTimestamp
			{
				break
			}

			if candle.timestamp + candle.scale < cameraTimestamp
			{
				continue
			}

			if candle.low < low
			{
				low = candle.low
			}

			if candle.high > high
			{
				high = candle.high
			}
		}

		middle : f32 = (math.log10(high) + math.log10(low)) / 2

		initialVerticalScale = (math.log10(high) - math.log10(low)) / (INITIAL_SCREEN_HEIGHT - 64)

		cameraPosY = -(middle / initialVerticalScale) - INITIAL_SCREEN_HEIGHT / 2
	}

	scaleData.verticalScale = initialVerticalScale

	for !WindowShouldClose()
	{
		if IsWindowResized()
		{
			newScreenWidth : i32
			newScreenHeight : i32

			if IsWindowFullscreen()
			{
				newScreenWidth = GetMonitorWidth(0)
				newScreenHeight = GetMonitorHeight(0)
				fmt.println(newScreenWidth, newScreenHeight)
			}
			else
			{
				newScreenWidth = GetScreenWidth()
				newScreenHeight = GetScreenHeight()
			}

			cameraPosX -= f32(newScreenWidth - screenWidth)

			cameraPrice := ToPrice(scaleData, cameraPosY + f32(screenHeight / 2))

			initialVerticalScale = initialVerticalScale * f32(screenHeight) / f32(newScreenHeight)
			scaleData.verticalScale = scaleData.verticalScale * f32(screenHeight) / f32(newScreenHeight)

			screenWidth = newScreenWidth
			screenHeight = newScreenHeight

			cameraPosY = ToPixelY(scaleData, cameraPrice) - f32(screenHeight / 2)
		}

		if IsKeyPressed(.F11)
		{
			ToggleFullscreen()

			if IsWindowFullscreen()
			{
				windowedScreenWidth = screenWidth
				windowedScreenHeight = screenHeight

				SetWindowSize(GetMonitorWidth(0), GetMonitorHeight(0))
			}
			else
			{
				SetWindowSize(windowedScreenWidth, windowedScreenHeight)
			}
		}

		// Camera Panning
		if IsMouseButtonPressed(.LEFT)
		{
			dragging = true
		}

		if IsMouseButtonReleased(.LEFT)
		{
			dragging = false
		}

		if dragging
		{
			cameraPosX -= GetMouseDelta().x
			cameraPosY -= GetMouseDelta().y
		}

		// Vertical Scale Adjustment
		if IsMouseButtonPressed(.RIGHT)
		{
			rightDragging = true
		}

		if IsMouseButtonReleased(.RIGHT)
		{
			rightDragging = false
		}

		if rightDragging
		{
			cameraCenterY : f32 = (cameraPosY + f32(screenHeight) / 2) * scaleData.verticalScale

			verticalZoomLevel += GetMouseDelta().y
			scaleData.verticalScale = initialVerticalScale * math.exp(verticalZoomLevel / 500)

			cameraPosY = cameraCenterY / scaleData.verticalScale - f32(screenHeight) / 2
		}

		// Debug zoom adjustment
		if IsKeyPressed(.A)
		{
			if zoomIndex < ZOOM_INDEX_COUNT - 1
			{
				zoomIndex += 1
			}
		}

		if IsKeyPressed(.S)
		{
			if zoomIndex > 0
			{
				zoomIndex -= 1
			}
		}

		if IsKeyPressed(.L)
		{
			cameraTop : f32 = ToPrice(scaleData, cameraPosY)
			cameraBottom : f32 = ToPrice(scaleData, cameraPosY + f32(screenHeight))

			cameraTimestamp : i32 = ToTimestamp(scaleData, cameraPosX)
			cameraEndTimestamp : i32 = ToTimestamp(scaleData, cameraPosX + f32(screenWidth))

			priceUpper : f32 = 0
			priceLower : f32 = 10000000

			// Draw Candles
			for i := 1; i < candleData[zoomIndex].candleCount; i += 1
			{
				candle : ^Candle = &candleData[zoomIndex].candles[i]

				if candle.timestamp > cameraEndTimestamp
				{
					break
				}

				if candle.timestamp + candle.scale < cameraTimestamp
				{
					continue
				}

				if candle.high > priceUpper
				{
					if candle.high > cameraTop
					{
						priceUpper = cameraTop
					}
					else
					{
						priceUpper = candle.high
					}
				}

				if candle.low < priceLower
				{
					if candle.low < cameraBottom
					{
						priceLower = cameraBottom
					}
					else
					{
						priceLower = candle.low
					}
				}
			}

			prePixelUpper : f32 = ToPixelY(scaleData, priceUpper)
			prePixelLower : f32 = ToPixelY(scaleData, priceLower)

			pixelOffset : f32 = prePixelUpper - cameraPosY

			scaleData.logScale = !scaleData.logScale

			postPixelUpper : f32 = ToPixelY(scaleData, priceUpper)
			postPixelLower : f32 = ToPixelY(scaleData, priceLower)

			difference : f32 = f32(postPixelLower - postPixelUpper) / f32(prePixelLower - prePixelUpper)
			
			initialVerticalScale *= difference
			scaleData.verticalScale *= difference

			cameraPosY = ToPixelY(scaleData, priceUpper) - pixelOffset
		}

		// Zooming
		if GetMouseWheelMove() != 0
		{
			zoomLevel -= int(GetMouseWheelMove())

			// Remove zoom from screen space as we adjust it
			cameraCenterX : f32 = (cameraPosX + f32(screenWidth) / 2) * scaleData.zoom
			cameraCenterY : f32 = (cameraPosY + f32(screenHeight) / 2) * scaleData.zoom

			scaleData.zoom = 1

			i := zoomLevel

			for i > 0
			{
				scaleData.zoom *= ZOOM_INCREMENT
				i -= 1
			}

			for i < 0
			{
				scaleData.zoom /= ZOOM_INCREMENT
				i += 1
			}

			zoomIndex = 0

			for zoomIndex + 1 < ZOOM_INDEX_COUNT &&
			    ToPixelX(scaleData, candleData[zoomIndex + 1].candles[0].scale) > ZOOM_THRESHOLD
			{
				zoomIndex += 1
			}

			// Re-add zoom post update
			cameraPosX = cameraCenterX / scaleData.zoom - f32(screenWidth) / 2
			cameraPosY = cameraCenterY / scaleData.zoom - f32(screenHeight) / 2
		}

		// Rendering <><><><><><><><><><><><><><><><><><><><><><><><><><><><>

        BeginDrawing()

		ClearBackground(BLACK)

		DrawRectangle(i32(-cameraPosX), 0, 1, i32(screenHeight), WHITE)

		cameraTimestamp := ToTimestamp(scaleData, cameraPosX)
		cameraEndTimestamp := ToTimestamp(scaleData, cameraPosX + f32(screenWidth))

		// Draw Candle Close Levels
		for i := 0; i < zoomIndex; i += 1
		{
			data : ^CandleData = &candleData[i]

			for j := 0; j < data.closeLevelCount; j += 1
			{
				pixelY := i32(ToPixelY(scaleData, data.closeLevels[j].price) - cameraPosY)

				if (data.closeLevels[j].endTimestamp != -1)
				{
					if (showInvalidatedLevels)
					{
						DrawLine(i32(ToPixelX(scaleData, data.closeLevels[j].startTimestamp) - cameraPosX), pixelY, i32(ToPixelX(scaleData, data.closeLevels[j].endTimestamp) - cameraPosX), pixelY, data.closeLevelColor)
					}
				}
				else
				{
					DrawLine(i32(ToPixelX(scaleData, data.closeLevels[j].startTimestamp) - cameraPosX), pixelY, screenWidth, pixelY, data.closeLevelColor)
				}
			}
		}

		// Draw HTF Candle Outlines
		zoomIndexHTF := zoomIndex - 1

		if zoomIndexHTF >= 0
		{
			for i : int = 0; i < candleData[zoomIndexHTF].candleCount; i += 1
			{
				candle : ^Candle = &candleData[zoomIndexHTF].candles[i]

				if candle.timestamp > cameraEndTimestamp
				{
					break
				}

				if candle.timestamp + candle.scale < cameraTimestamp
				{
					continue
				}

				xPos := ToPixelX(scaleData, candle.timestamp) - cameraPosX
				candleWidth := ToPixelX(scaleData, candle.scale)

				scaledOpen := ToPixelY(scaleData, candle.open)
				scaledClose := ToPixelY(scaleData, candle.close)
				scaledHigh := ToPixelY(scaleData, candle.high)
				scaledLow := ToPixelY(scaleData, candle.low)

				if scaledClose > scaledOpen
				{
					candleHeight := scaledClose - scaledOpen

					if candleHeight < 1
					{
						candleHeight = 1
					}

					color := RED

					color.a = 63

					DrawRectangleLines(i32(xPos), i32(scaledOpen - cameraPosY), i32(candleWidth), i32(candleHeight), color)
				}
				else
				{
					candleHeight := scaledOpen - scaledClose

					if candleHeight < 1
					{
						candleHeight = 1
					}

					color := GREEN

					color.a = 63

					DrawRectangleLines(i32(xPos), i32(scaledClose - cameraPosY), i32(candleWidth), i32(candleHeight), color)
				}
			}
		}

		// Draw Candles
		for i : int = 0; i < candleData[zoomIndex].candleCount; i += 1
		{
			candle : ^Candle = &candleData[zoomIndex].candles[i]

			if candle.timestamp > cameraEndTimestamp
			{
				break
			}

			if candle.timestamp + candle.scale < cameraTimestamp
			{
				continue
			}

			xPos := ToPixelX(scaleData, candle.timestamp) - cameraPosX
			candleWidth := ToPixelX(scaleData, candle.scale)

			scaledOpen := ToPixelY(scaleData, candle.open)
			scaledClose := ToPixelY(scaleData, candle.close)
			scaledHigh := ToPixelY(scaleData, candle.high)
			scaledLow := ToPixelY(scaleData, candle.low)

			if scaledClose > scaledOpen
			{
				candleHeight := scaledClose - scaledOpen

				if candleHeight < 1
				{
					candleHeight = 1
				}

				DrawRectangle(i32(xPos), i32(scaledOpen - cameraPosY), i32(candleWidth), i32(candleHeight), RED)
				DrawRectangle(i32(xPos + candleWidth / 2 - 0.5), i32(scaledHigh - cameraPosY), 1, i32(scaledLow - scaledHigh), RED)
			}
			else
			{
				candleHeight := scaledOpen - scaledClose

				if candleHeight < 1
				{
					candleHeight = 1
				}

				DrawRectangle(i32(xPos), i32(scaledClose - cameraPosY), i32(candleWidth), i32(candleHeight), GREEN)
				DrawRectangle(i32(xPos + candleWidth / 2 - 0.5), i32(scaledHigh - cameraPosY), 1, i32(scaledLow - scaledHigh), GREEN)
			}
		}

		text : [64]u8

		output : string = fmt.bprintf(text[:], "%i\x00", GetFPS())
		DrawText(strings.unsafe_string_to_cstring(output), 0, 0, 20, RAYWHITE)

		output = fmt.bprintf(text[:], "%i\x00", zoomIndex)
		DrawText(strings.unsafe_string_to_cstring(output), 0, 20, 20, RAYWHITE)

		timestamp := ToTimestamp(scaleData, f32(GetMouseX()) + cameraPosX)

		index := 0

		for i := 1; i < candleData[zoomIndex].candleCount; i += 1
		{
			if candleData[zoomIndex].candles[i].timestamp < timestamp
			{
				index += 1
			}
			else
			{
				break
			}
		}
		
		output = fmt.bprintf(text[:], "%i: %f, %f\x00", index, candleData[zoomIndex].candles[index].open, ToPixelY(scaleData, candleData[zoomIndex].candles[index].open) - cameraPosY)
		DrawText(strings.unsafe_string_to_cstring(output), 0, 40, 20, RAYWHITE)

		output = fmt.bprintf(text[:], "%f, %f\x00", cameraPosX, cameraPosY)
		DrawText(strings.unsafe_string_to_cstring(output), 0, 60, 20, RAYWHITE)

		output = fmt.bprintf(text[:], "%i, %i\x00", screenWidth, screenHeight)
		DrawText(strings.unsafe_string_to_cstring(output), 0, 80, 20, RAYWHITE)

        EndDrawing()
	}
}
