package main

import "core:fmt"
import "core:math"
import "core:slice"
import rl "vendor:raylib"

SIDEBAR_WIDTH :: 400

ViewportFlags :: enum
{
	LOCK_TIMEFRAME,
	DRAW_DAY_OF_WEEK,
	DRAW_SESSIONS,
	DRAW_HTF_OUTLINES,
	DRAW_CVD,
	DRAW_PREV_DAY_VPS,
	DRAW_PREV_WEEK_VPS,
	DRAW_CLOSE_LEVELS,
	DRAW_SIDEBAR,
}

ViewportFlagsSet :: bit_set[ViewportFlags]

Viewport :: struct
{
	// Position + Scale
	rect : rl.Rectangle,
	scaleData : ScaleData,
	camera : rl.Vector2,

	unzoomedVerticalScale : f64,
	zoomIndex : Timeframe, // Determines which timeframe of candles to index
	zoomLevel : int, // Number of scroll wheel increments performed
	verticalZoomLevel : f32, // Number of pixels dragged during vertical zoom adjustment
	
	cameraTimestamp : i32,
	cameraEndTimestamp : i32,
	cameraTopPrice : f32,
	cameraBottomPrice : f32,

	// Visible candles
	visibleCandles : []Candle,
	visibleCandlesStartIndex : i32,

	highestCandle, lowestCandle : Candle,
	highestCandleIndex, lowestCandleIndex : i32,
	
	// Hover
	cursorTimestamp : i32,
	cursorCandleIndex : i32,
	cursorCandle : Candle,
	isCursorSnapped : bool,
	cursorSnapPrice : f32,
	
	// LMB
	leftDragging : bool,
	selectedHandle : SelectionHandle,
	hasMouseMovedSelection : bool,
	mouseSelectionStartTimestamp : i32,
	mouseSelectionStartCandleIndex : i32,
	mouseSelectionStartZoomIndex : Timeframe,
	mouseSelectionStartPrice : f32,
	
	// RMB
	rightDragging : bool,
	rightDraggingStartPrice : f32,

	// Selections
	selections : [dynamic]Selection,
	currentSelection : ^Selection,
	hoveredSelection : ^Selection,
	currentSelectionIndex : int,
	hoveredSelectionIndex : int,

	// Drawing
	dailyCloseLevels : CandleCloseLevels,
	weeklyCloseLevels : CandleCloseLevels,
	monthlyCloseLevels : CandleCloseLevels,
	
	highlows005 : [dynamic]HighLow,
	startsHigh005 : bool,
	fibResults005 : FibResults,
	highlows01 : [dynamic]HighLow,
	startsHigh01 : bool,
	fibResults01 : FibResults,
	highlows02 : [dynamic]HighLow,
	startsHigh02 : bool,
	fibResults02 : FibResults,
	highlows05 : [dynamic]HighLow,
	startsHigh05 : bool,
	fibResults05 : FibResults,
	
	highlowsChris : [dynamic]HighLow,
	startsHighChris : bool,
	
	flags : ViewportFlagsSet,
}

Viewport_Init :: proc(vp : ^Viewport, chart : Chart, rect : rl.Rectangle)
{
	vp.rect = rect
	
	vp.scaleData.horizontalZoom = 1
	vp.scaleData.verticalZoom = 1
	vp.scaleData.horizontalScale = f64(CandleList_IndexToDuration(chart.candles[START_ZOOM_INDEX], 0) / (ZOOM_THRESHOLD * 2))
	vp.scaleData.logScale = true
	
	vp.zoomIndex = START_ZOOM_INDEX
	vp.zoomLevel = 0
	vp.verticalZoomLevel = 0
	
	vp.camera.x = f32(f64(CandleList_IndexToTimestamp(chart.candles[vp.zoomIndex], i32(len(chart.candles[vp.zoomIndex].candles)))) / vp.scaleData.horizontalScale) - vp.rect.width + 100
	
	vp.cameraTimestamp = i32(f64(vp.camera.x) * vp.scaleData.horizontalScale)
	vp.cameraEndTimestamp = i32(f64(vp.camera.x + vp.rect.width) * vp.scaleData.horizontalScale)
	
	// Slice of all candles that currently fit within the width of the viewport
	vp.visibleCandles, vp.visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(chart.candles[vp.zoomIndex], vp.cameraTimestamp, vp.cameraEndTimestamp)
	
	highestCandle, highestCandleIndex := Candle_HighestHigh(vp.visibleCandles)
	lowestCandle, lowestCandleIndex := Candle_LowestLow(vp.visibleCandles)

	// Set vertical scale to fit all initially visible candles on screen
	high := highestCandle.high
	low := lowestCandle.low

	middle : f32 = (math.log10(high) + math.log10(low)) / 2

	vp.unzoomedVerticalScale = f64(math.log10(high) - math.log10(low)) / (INITIAL_SCREEN_HEIGHT - 64)
	vp.scaleData.verticalScale = vp.unzoomedVerticalScale

	vp.camera.y = f32(-(f64(middle) / vp.scaleData.verticalScale) - INITIAL_SCREEN_HEIGHT / 2)

	vp.cameraTopPrice = Price_FromPixelY(vp.camera.y, vp.scaleData)
	vp.cameraBottomPrice = Price_FromPixelY(vp.camera.y + vp.rect.height, vp.scaleData)
	
	vp.highestCandleIndex += vp.visibleCandlesStartIndex
	vp.lowestCandleIndex += vp.visibleCandlesStartIndex
	vp.isCursorSnapped = false

	vp.selectedHandle = .NONE
	vp.hasMouseMovedSelection = false

	vp.flags = {.DRAW_HTF_OUTLINES, .DRAW_CVD, .DRAW_SESSIONS, .DRAW_PREV_DAY_VPS}
	
	vp.dailyCloseLevels = CandleCloseLevels_Create(chart.candles[Timeframe.DAY], rl.SKYBLUE)
	vp.weeklyCloseLevels = CandleCloseLevels_Create(chart.candles[Timeframe.WEEK], rl.YELLOW)
	vp.monthlyCloseLevels = CandleCloseLevels_Create(chart.candles[Timeframe.MONTH], rl.YELLOW)
	
	vp.highlows005, vp.startsHigh005 = HighLow_Generate(chart.candles[Timeframe.MINUTE], 0.005)
	vp.fibResults005 = CalcFibs(chart, vp.highlows005[:], vp.startsHigh005)
	vp.highlows01, vp.startsHigh01 = HighLow_Generate(chart.candles[Timeframe.MINUTE], 0.01)
	vp.fibResults01 = CalcFibs(chart, vp.highlows01[:], vp.startsHigh01)
	vp.highlows02, vp.startsHigh02 = HighLow_Generate(chart.candles[Timeframe.MINUTE], 0.02)
	vp.fibResults02 = CalcFibs(chart, vp.highlows02[:], vp.startsHigh02)
	vp.highlows05, vp.startsHigh05 = HighLow_Generate(chart.candles[Timeframe.MINUTE], 0.05)
	vp.fibResults05 = CalcFibs(chart, vp.highlows05[:], vp.startsHigh05)
	
	vp.highlowsChris, vp.startsHighChris = HighLow_Generate(chart.candles[Timeframe.HOUR], 0.5)
}

Viewport_Destroy :: proc(vp : Viewport)
{
	defer for selection in vp.selections
	{
		Selection_Destroy(selection)
	}

	CandleCloseLevels_Destroy(vp.dailyCloseLevels)
	CandleCloseLevels_Destroy(vp.weeklyCloseLevels)
	CandleCloseLevels_Destroy(vp.monthlyCloseLevels)
}

Viewport_Resize :: proc(vp : ^Viewport, newRect : rl.Rectangle)
{
	cameraPrice : f32 = Price_FromPixelY(vp.camera.y + vp.rect.height / 2, vp.scaleData)

	vp.unzoomedVerticalScale *= f64(vp.rect.height) / f64(newRect.height)
	vp.scaleData.verticalScale *= f64(vp.rect.height) / f64(newRect.height)

	vp.camera.x -= newRect.width - vp.rect.width
	vp.camera.y = Price_ToPixelY(cameraPrice, vp.scaleData) - newRect.height / 2
	
	vp.rect.width = newRect.width
	vp.rect.height = newRect.height
}

Viewport_Update :: proc(vp : ^Viewport, chart : Chart)
{
	hoveredHandle := SelectionHandle.NONE

	// TODO: Hover least recently selected selection when multiple are hovered
	vp.hoveredSelection = nil
	vp.hoveredSelectionIndex = -1

	if f32(rl.GetMouseX()) > vp.rect.x + f32(i32(.DRAW_SIDEBAR in vp.flags)) * SIDEBAR_WIDTH
	{
		if vp.currentSelection != nil
		{
			hoveredHandle = Selection_HandleAt(vp.currentSelection^, f32(rl.GetMouseX()), f32(rl.GetMouseY()), vp.camera.x, vp.camera.y, vp.scaleData)
		}

		if hoveredHandle == .NONE
		{
			// Reverse order to match visual order
			for i := len(vp.selections) - 1; i >= 0; i -= 1
			{
				if Selection_IsOverlapping(vp.selections[i], f32(rl.GetMouseX()) + vp.camera.x, f32(rl.GetMouseY()) + vp.camera.y, vp.scaleData)
				{
					vp.hoveredSelection = &vp.selections[i]
					vp.hoveredSelectionIndex = i
					break
				}
			}
		}
	}

	// Update candle under cursor
	// We add one pixel to the cursor's position, as all of the candles' timestamps get rounded down when converted
	// As we are doing the opposite conversion, the mouse will always be less than or equal to the candles
	vp.cursorTimestamp = Timestamp_FromPixelX(f32(rl.GetMouseX()) + vp.camera.x + 1, vp.scaleData)
	vp.cursorCandleIndex = CandleList_TimestampToIndex_Clamped(chart.candles[vp.zoomIndex], vp.cursorTimestamp)
	vp.cursorCandle = chart.candles[vp.zoomIndex].candles[vp.cursorCandleIndex]
	
	cursor : rl.MouseCursor = ---
	
	#partial switch(hoveredHandle)
	{
		case .EDGE_TOPLEFT, .EDGE_BOTTOMRIGHT: cursor = .RESIZE_NWSE
		case .EDGE_TOP, .EDGE_BOTTOM:          cursor = .RESIZE_NS
		case .EDGE_TOPRIGHT, .EDGE_BOTTOMLEFT: cursor = .RESIZE_NESW
		case .EDGE_LEFT, .EDGE_RIGHT:          cursor = .RESIZE_EW
			
		case .NONE: cursor = .DEFAULT
		case: cursor = .POINTING_HAND
	}

	if vp.hoveredSelection != nil && !vp.hasMouseMovedSelection
	{
		cursor = .POINTING_HAND
	}
	
	if rl.IsMouseButtonPressed(.LEFT) &&
	   hoveredHandle != .HOTBAR_VOLUME_PROFILE &&
	   hoveredHandle != .HOTBAR_FIB_RETRACEMENT &&
	   f32(rl.GetMouseX()) > vp.rect.x + f32(i32(.DRAW_SIDEBAR in vp.flags)) * SIDEBAR_WIDTH
	{
		vp.leftDragging = true
	
		vp.hasMouseMovedSelection = false

		vp.mouseSelectionStartTimestamp = vp.cursorTimestamp
		vp.mouseSelectionStartCandleIndex = vp.cursorCandleIndex
		vp.mouseSelectionStartZoomIndex = vp.zoomIndex
		vp.mouseSelectionStartPrice = vp.cursorSnapPrice

		if !rl.IsKeyDown(.LEFT_SHIFT)
		{
			vp.selectedHandle = hoveredHandle
		
			#partial switch vp.selectedHandle
			{
				case .EDGE_TOPLEFT:
				{
					vp.mouseSelectionStartPrice = vp.currentSelection.low
					vp.mouseSelectionStartTimestamp = vp.currentSelection.endTimestamp
					vp.mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, vp.currentSelection.endTimestamp)
					vp.mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[vp.mouseSelectionStartZoomIndex], vp.currentSelection.endTimestamp) - 1
				}
				case .EDGE_TOPRIGHT:
				{
					vp.mouseSelectionStartPrice = vp.currentSelection.low
					vp.mouseSelectionStartTimestamp = vp.currentSelection.startTimestamp
					vp.mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, vp.currentSelection.startTimestamp)
					vp.mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[vp.mouseSelectionStartZoomIndex], vp.currentSelection.startTimestamp)
				}
				case .EDGE_BOTTOMLEFT:
				{
					vp.mouseSelectionStartPrice = vp.currentSelection.high
					vp.mouseSelectionStartTimestamp = vp.currentSelection.endTimestamp
					vp.mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, vp.currentSelection.endTimestamp)
					vp.mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[vp.mouseSelectionStartZoomIndex], vp.currentSelection.endTimestamp) - 1
				}
				case .EDGE_BOTTOMRIGHT:
				{
					vp.mouseSelectionStartPrice = vp.currentSelection.high
					vp.mouseSelectionStartTimestamp = vp.currentSelection.startTimestamp
					vp.mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, vp.currentSelection.startTimestamp)
					vp.mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[vp.mouseSelectionStartZoomIndex], vp.currentSelection.startTimestamp)
				}
				case .EDGE_TOP:
				{
					vp.mouseSelectionStartPrice = vp.currentSelection.low
				}
				case .EDGE_LEFT:
				{
					vp.mouseSelectionStartTimestamp = vp.currentSelection.endTimestamp
					vp.mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, vp.currentSelection.endTimestamp)
					vp.mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[vp.mouseSelectionStartZoomIndex], vp.currentSelection.endTimestamp) - 1
				}
				case .EDGE_RIGHT:
				{
					vp.mouseSelectionStartTimestamp = vp.currentSelection.startTimestamp
					vp.mouseSelectionStartZoomIndex = Chart_TimestampToTimeframe(chart, vp.currentSelection.startTimestamp)
					vp.mouseSelectionStartCandleIndex = CandleList_TimestampToIndex(chart.candles[vp.mouseSelectionStartZoomIndex], vp.currentSelection.startTimestamp)
				}
				case .EDGE_BOTTOM:
				{
					vp.mouseSelectionStartPrice = vp.currentSelection.high
				}
			}
		}
		else
		{
			vp.mouseSelectionStartTimestamp = CandleList_IndexToTimestamp(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
			vp.selectedHandle = .EDGE_TOPRIGHT

			if vp.currentSelection != nil &&
			   vp.currentSelection.tools == nil
			{
				unordered_remove(&vp.selections, vp.currentSelectionIndex)
			}
		
			append(&vp.selections, Selection{})
			vp.currentSelection = &vp.selections[len(vp.selections) - 1]
			vp.currentSelectionIndex = len(vp.selections) - 1

			Selection_Create(vp.currentSelection, \
			                 chart, \
			                 vp.mouseSelectionStartTimestamp, \
			                 vp.mouseSelectionStartTimestamp + CandleList_IndexToDuration(chart.candles[vp.zoomIndex], \
			                 vp.cursorCandleIndex), \
			                 vp.cursorSnapPrice, \
			                 vp.cursorSnapPrice)
		}
	}

	if rl.IsMouseButtonReleased(.LEFT)
	{
		vp.leftDragging = false
		
		if !vp.hasMouseMovedSelection
		{
			#partial switch hoveredHandle
			{
				case .POC: vp.currentSelection.volumeProfileDrawFlags ~= {.POC}
				case .VAL: vp.currentSelection.volumeProfileDrawFlags ~= {.VAL}
				case .VAH: vp.currentSelection.volumeProfileDrawFlags ~= {.VAH}
				case .TV_VAL: vp.currentSelection.volumeProfileDrawFlags ~= {.TV_VAL}
				case .TV_VAH: vp.currentSelection.volumeProfileDrawFlags ~= {.TV_VAH}
				case .VWAP: vp.currentSelection.volumeProfileDrawFlags ~= {.VWAP}
				case .VOLUME_PROFILE_BODY: vp.currentSelection.volumeProfileDrawFlags ~= {.BODY}
				case .FIB_618: vp.currentSelection.draw618 = !vp.currentSelection.draw618
				case .HOTBAR_VOLUME_PROFILE:
				{
					if rl.IsKeyDown(.LEFT_SHIFT)
					{
						vp.currentSelection.tools ~= {.VOLUME_PROFILE}
					}
					else
					{
						vp.currentSelection.tools = {.VOLUME_PROFILE}
					}
				}
				case .HOTBAR_FIB_RETRACEMENT:
				{
					if rl.IsKeyDown(.LEFT_SHIFT)
					{
						vp.currentSelection.tools ~= {.FIB_RETRACEMENT}
					}
					else
					{
						vp.currentSelection.tools = {.FIB_RETRACEMENT}
					}
				}
				case .NONE:
				{
					if vp.currentSelection != nil &&
					   vp.currentSelection.tools == nil
					{
						unordered_remove(&vp.selections, vp.currentSelectionIndex)
					}
			
					vp.currentSelection = vp.hoveredSelection
					vp.currentSelectionIndex = vp.hoveredSelectionIndex
				}
			}
		}

		vp.selectedHandle = .NONE
		vp.hasMouseMovedSelection = false
	}

	mouseDelta := rl.GetMouseDelta()

	#partial switch vp.selectedHandle
	{
		case .EDGE_TOPRIGHT, .EDGE_BOTTOMLEFT: cursor = .RESIZE_NESW
		case .EDGE_TOPLEFT, .EDGE_BOTTOMRIGHT: cursor = .RESIZE_NWSE
		case .EDGE_LEFT, .EDGE_RIGHT: cursor = .RESIZE_EW
		case .EDGE_TOP, .EDGE_BOTTOM: cursor = .RESIZE_NS
	}

	if vp.leftDragging &&
	   (mouseDelta.x != 0 ||
	    mouseDelta.y != 0)
	{
		vp.hasMouseMovedSelection = true

		#partial switch vp.selectedHandle
		{
			case .EDGE_TOPLEFT, .EDGE_TOPRIGHT, .EDGE_BOTTOMLEFT, .EDGE_BOTTOMRIGHT:
			{
				cursorCandleTimestamp := CandleList_IndexToTimestamp(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
				newStartTimestamp : i32 = ---
				newEndTimestamp : i32 = ---

				isUpsideDown := vp.currentSelection.isUpsideDown

				if cursorCandleTimestamp >= vp.mouseSelectionStartTimestamp
				{
					#partial switch vp.selectedHandle
					{
						case .EDGE_TOPLEFT: vp.selectedHandle = .EDGE_TOPRIGHT; vp.mouseSelectionStartTimestamp -= CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
						case .EDGE_BOTTOMLEFT: vp.selectedHandle = .EDGE_BOTTOMRIGHT; vp.mouseSelectionStartTimestamp -= CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex);
					}
					
					newStartTimestamp = vp.mouseSelectionStartTimestamp
					newEndTimestamp = cursorCandleTimestamp + CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
				}
				else
				{
					#partial switch vp.selectedHandle
					{
						case .EDGE_TOPRIGHT: vp.selectedHandle = .EDGE_TOPLEFT; vp.mouseSelectionStartTimestamp += CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
						case .EDGE_BOTTOMRIGHT: vp.selectedHandle = .EDGE_BOTTOMLEFT; vp.mouseSelectionStartTimestamp += CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
					}
					
					newStartTimestamp = cursorCandleTimestamp
					newEndTimestamp = vp.mouseSelectionStartTimestamp
				}

				// Check for flipping of coordinates
				isBottomEdge := vp.selectedHandle == .EDGE_BOTTOMLEFT || vp.selectedHandle == .EDGE_BOTTOMRIGHT

				if (vp.mouseSelectionStartPrice < vp.cursorSnapPrice) == isBottomEdge
				{
					isUpsideDown = !vp.currentSelection.isUpsideDown
					
					#partial switch vp.selectedHandle
					{
						case .EDGE_BOTTOMLEFT: vp.selectedHandle = .EDGE_TOPLEFT
						case .EDGE_BOTTOMRIGHT: vp.selectedHandle = .EDGE_TOPRIGHT
						case .EDGE_TOPLEFT: vp.selectedHandle = .EDGE_BOTTOMLEFT
						case .EDGE_TOPRIGHT: vp.selectedHandle = .EDGE_BOTTOMRIGHT
					}
				}

				high := math.max(vp.mouseSelectionStartPrice, vp.cursorSnapPrice)
				low := math.min(vp.mouseSelectionStartPrice, vp.cursorSnapPrice)

				Selection_Resize(vp.currentSelection, newStartTimestamp, newEndTimestamp, high, low, isUpsideDown, chart)
			}
			case .EDGE_LEFT, .EDGE_RIGHT:
			{
				cursorCandleTimestamp := CandleList_IndexToTimestamp(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
				newStartTimestamp : i32 = ---
				newEndTimestamp : i32 = ---

				if cursorCandleTimestamp >= vp.mouseSelectionStartTimestamp
				{
					if vp.selectedHandle == .EDGE_LEFT
					{
						vp.selectedHandle = .EDGE_RIGHT
						vp.mouseSelectionStartTimestamp -= CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
					}
					
					newStartTimestamp = vp.mouseSelectionStartTimestamp
					newEndTimestamp = cursorCandleTimestamp + CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
				}
				else
				{
					if vp.selectedHandle == .EDGE_RIGHT
					{
						vp.selectedHandle = .EDGE_LEFT
						vp.mouseSelectionStartTimestamp += CandleList_IndexToDuration(chart.candles[vp.zoomIndex], vp.cursorCandleIndex)
					}
					
					newStartTimestamp = cursorCandleTimestamp
					newEndTimestamp = vp.mouseSelectionStartTimestamp
				}


				Selection_Resize(vp.currentSelection, newStartTimestamp, newEndTimestamp, vp.currentSelection.high, vp.currentSelection.low, vp.currentSelection.isUpsideDown, chart)
			}
			case .EDGE_TOP, .EDGE_BOTTOM:
			{
				isUpsideDown := vp.currentSelection.isUpsideDown
				
				// Check for a flipping of coordinates
				if vp.mouseSelectionStartPrice < vp.cursorSnapPrice &&
				   vp.selectedHandle == .EDGE_BOTTOM
				{
					isUpsideDown = false
					vp.selectedHandle = .EDGE_TOP
				}
				else if vp.mouseSelectionStartPrice > vp.cursorSnapPrice &&
				        vp.selectedHandle == .EDGE_TOP
				{
					isUpsideDown = true
					vp.selectedHandle = .EDGE_BOTTOM
				}
				
				high := math.max(vp.mouseSelectionStartPrice, vp.cursorSnapPrice)
				low := math.min(vp.mouseSelectionStartPrice, vp.cursorSnapPrice)

				Selection_Resize(vp.currentSelection, vp.currentSelection.startTimestamp, vp.currentSelection.endTimestamp, high, low, isUpsideDown, chart)
			}
			case:
			{
				vp.hasMouseMovedSelection = true

				vp.camera.x -= mouseDelta.x
				vp.camera.y -= mouseDelta.y
			}
		}
	}

	rl.SetMouseCursor(cursor)
	
	// Vertical Scale Adjustment
	if rl.IsMouseButtonPressed(.RIGHT)
	{
		vp.rightDragging = true
		vp.rightDraggingStartPrice = Price_FromPixelY(vp.camera.y + vp.rect.height / 2, vp.scaleData)
	}

	if rl.IsMouseButtonReleased(.RIGHT)
	{
		vp.rightDragging = false
	}

	if vp.rightDragging
	{
		vp.verticalZoomLevel += rl.GetMouseDelta().y
		vp.scaleData.verticalScale = vp.unzoomedVerticalScale * math.exp(f64(vp.verticalZoomLevel) / 500)

		vp.camera.y = Price_ToPixelY(vp.rightDraggingStartPrice, vp.scaleData) - vp.rect.height / 2
	}

	// Zooming
	if rl.GetMouseWheelMove() != 0
	{
		vp.zoomLevel -= int(rl.GetMouseWheelMove())

		// Remove zoom from screen space as we adjust it
		cameraCenterX : f64 = (f64(vp.camera.x) + f64(vp.rect.width) / 2) * vp.scaleData.horizontalZoom
		cameraCenterY : f64 = (f64(vp.camera.y) + f64(vp.rect.height) / 2) * vp.scaleData.verticalZoom

		vp.scaleData.horizontalZoom = 1
		vp.scaleData.verticalZoom = 1

		i := vp.zoomLevel

		for i > 0
		{
			vp.scaleData.horizontalZoom *= HORIZONTAL_ZOOM_INCREMENT
			vp.scaleData.verticalZoom *= VERTICAL_ZOOM_INCREMENT
			i -= 1
		}

		for i < 0
		{
			vp.scaleData.horizontalZoom /= HORIZONTAL_ZOOM_INCREMENT
			vp.scaleData.verticalZoom /= VERTICAL_ZOOM_INCREMENT
			i += 1
		}

		Viewport_UpdateTimeframe(vp, chart)

		// Re-add zoom post update
		vp.camera.x = f32(cameraCenterX / vp.scaleData.horizontalZoom - f64(vp.rect.width) / 2)
		vp.camera.y = f32(cameraCenterY / vp.scaleData.verticalZoom - f64(vp.rect.height) / 2)
	}

	// Update visibleCandles
	vp.cameraTimestamp = Timestamp_FromPixelX(vp.camera.x, vp.scaleData)
	vp.cameraEndTimestamp = Timestamp_FromPixelX(vp.camera.x + vp.rect.width, vp.scaleData)
	vp.visibleCandles, vp.visibleCandlesStartIndex = CandleList_CandlesBetweenTimestamps(chart.candles[vp.zoomIndex], vp.cameraTimestamp, vp.cameraEndTimestamp)
	vp.highestCandle, vp.highestCandleIndex = Candle_HighestHigh(vp.visibleCandles)
	vp.lowestCandle, vp.lowestCandleIndex = Candle_LowestLow(vp.visibleCandles)

	vp.highestCandleIndex += vp.visibleCandlesStartIndex
	vp.lowestCandleIndex += vp.visibleCandlesStartIndex

	vp.cameraTopPrice = Price_FromPixelY(vp.camera.y, vp.scaleData)
	vp.cameraBottomPrice = Price_FromPixelY(vp.camera.y + vp.rect.height, vp.scaleData)

	if rl.IsKeyPressed(.L)
	{
		Viewport_ToggleLogScale(vp, chart)
	}
	
	if rl.IsKeyPressed(.T) &&
	   vp.currentSelection != nil
	{
		targets := [2]TradeTarget \
		{ \
			TradeTarget{1.02, 1.02}, \
			TradeTarget{1.04, 1.00} \
		}
		
		Calculate(chart, vp.currentSelection, vp.dailyCloseLevels.levels[:], targets[:])
	}

	if rl.IsKeyPressed(.TAB)
	{
		vp.flags ~= {.DRAW_SIDEBAR}
	}

	if rl.IsKeyPressed(.DELETE) &&
	   vp.currentSelection != nil
	{
		unordered_remove(&vp.selections, vp.currentSelectionIndex)

		vp.currentSelection = nil
		vp.currentSelectionIndex = -1
	}
	
	if rl.IsKeyPressed(.C) do vp.flags ~= {.DRAW_CVD}
	if rl.IsKeyPressed(.M) do vp.flags ~= {.DRAW_DAY_OF_WEEK}
	if rl.IsKeyPressed(.S) do vp.flags ~= {.DRAW_SESSIONS}
	if rl.IsKeyPressed(.Q) do vp.flags ~= {.DRAW_CLOSE_LEVELS}
	if rl.IsKeyPressed(.D) do vp.flags ~= {.DRAW_PREV_DAY_VPS}
	if rl.IsKeyPressed(.W) do vp.flags ~= {.DRAW_PREV_WEEK_VPS}
	if rl.IsKeyPressed(.H) do vp.flags ~= {.DRAW_HTF_OUTLINES}

	// Snap cursor to nearest OHLC value
	{
		SNAP_PIXELS :: 32

		mouseY := f32(rl.GetMouseY())

		high := Price_ToPixelY(vp.cursorCandle.high, vp.scaleData) - vp.camera.y
		low := Price_ToPixelY(vp.cursorCandle.low, vp.scaleData) - vp.camera.y

		midHighPrice := math.max(vp.cursorCandle.open, vp.cursorCandle.close)
		midLowPrice := math.min(vp.cursorCandle.open, vp.cursorCandle.close)
		midHigh := Price_ToPixelY(midHighPrice, vp.scaleData) - vp.camera.y
		midLow := Price_ToPixelY(midLowPrice, vp.scaleData) - vp.camera.y

		highestSnap := high - SNAP_PIXELS
		lowestSnap := low + SNAP_PIXELS

		if mouseY >= highestSnap &&
		   mouseY <= lowestSnap
		{
			// Midpoints (in pixels)
			highMidHigh := (high + midHigh) / 2
			midHighMidLow := (midHigh + midLow) / 2
			midLowLow := (midLow + low) / 2

			if mouseY < highMidHigh
			{
				mouseY = high
				vp.cursorSnapPrice = vp.cursorCandle.high
			}
			else if mouseY < midHighMidLow
			{
				mouseY = midHigh
				vp.cursorSnapPrice = midHighPrice
			}
			else if mouseY < midLowLow
			{
				mouseY = midLow
				vp.cursorSnapPrice = midLowPrice
			}
			else
			{
				mouseY = low
				vp.cursorSnapPrice = vp.cursorCandle.low
			}

			vp.isCursorSnapped = true
		}
		else
		{
			vp.cursorSnapPrice = Price_FromPixelY(mouseY + vp.camera.y, vp.scaleData)
		}
	}
}

Viewport_Draw :: proc(vp : ^Viewport, chart : Chart)
{
	// Used for label bars
	MIN_ALPHA :: 10
	MAX_ALPHA :: 19
	ALPHA_RANGE :: MAX_ALPHA - MIN_ALPHA

	// Generate price labels
	// Draw lines before candles are drawn
	// Draw labels after candles are drawn
	PriceLabel :: struct
	{
		price : f32,
		textBuffer : [32]u8, // Much larger buffer than timestamp labels, as log scale can balloon the prices, and memecoins, if ever implemented, use huge decimals
		width : f32,
		color : rl.Color,
	}

	priceLabels : [dynamic]PriceLabel
	reserve(&priceLabels, 32)

	priceLabelSpacing : f32 = labelHeight + 6

	MIN_DECIMAL :: 0.01
	MAX_PRICE_DIFFERENCE : f32 : 1_000_000_000

	if vp.scaleData.logScale
	{
		// These are the only four linear scale increments, once these are exhausted, the values are multiplied by 10 and recycled
		priceIncrements : [4]f32 = {1, 2.5, 5, 10}

		topLabelPrice := Price_FromPixelY(vp.camera.y - labelHeight / 2, vp.scaleData)
		priceDifference := math.min(Price_FromPixelY(vp.camera.y - labelHeight / 2 - priceLabelSpacing, vp.scaleData) - topLabelPrice, MAX_PRICE_DIFFERENCE)

		currentMagnitude := MAX_PRICE_DIFFERENCE

		for currentMagnitude > priceDifference
		{
			currentMagnitude *= 0.1
		}

		normalizedDifference := priceDifference / currentMagnitude

		for i in 1 ..< len(priceIncrements)
		{
			if normalizedDifference < priceIncrements[i]
			{
				topLabelPrice = topLabelPrice - math.mod(topLabelPrice, priceIncrements[i] * currentMagnitude)
				break
			}
		}

		append(&priceLabels, PriceLabel{})
		label := &priceLabels[len(priceLabels) - 1]

		label.price = topLabelPrice
		fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
		label.width = rl.MeasureTextEx(labelFont, cstring(&label.textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
		label.color = rl.Color{255, 255, 255, MAX_ALPHA}

		prevPrice := topLabelPrice
		prevPixel := Price_ToPixelY(prevPrice, vp.scaleData)

		for prevPixel < vp.camera.y + vp.rect.height
		{
			currentPrice := Price_FromPixelY(prevPixel + priceLabelSpacing, vp.scaleData)
			priceDifference = prevPrice - currentPrice

			// Price_FromPixelY can sometimes return +inf, which crashes the program without this break
			if currentPrice > MAX_PRICE_DIFFERENCE
			{
				break
			}

			for currentMagnitude > priceDifference
			{
				currentMagnitude *= 0.1
			}

			normalizedDifference = priceDifference / currentMagnitude

			for i in 1 ..< len(priceIncrements)
			{
				if normalizedDifference < priceIncrements[i]
				{
					currentPrice = currentPrice - math.mod(currentPrice, priceIncrements[i] * currentMagnitude)
					break
				}
			}

			append(&priceLabels, PriceLabel{})
			label := &priceLabels[len(priceLabels) - 1]

			label.price = currentPrice
			fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
			label.width = rl.MeasureTextEx(labelFont, cstring(&label.textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
			label.color = rl.Color{255, 255, 255, MAX_ALPHA}

			prevPixel = Price_ToPixelY(currentPrice, vp.scaleData)
			prevPrice = currentPrice
		}
	}
	else
	{
		priceIncrements : [4]f32 = {1, 2, 2.5, 5}

		// Linear scaling
		// Do everything multiplied by the minimum decimal so that the minimum value is 1
		// This way everything can be done in integers and we can avoid precision errors

		priceLabelSpacing /= MIN_DECIMAL

		pixelPriceIncrement := abs(Price_ToPixelY(1, vp.scaleData) - Price_ToPixelY(0, vp.scaleData))

		// Will need to reference a minimum size value in the scenario of memecoins or alt pairs with BTC
		priceIncrementMultiplier : f32 = 1
		priceIncrementIndex := 0

		// Can we math this out?
		for pixelPriceIncrement * priceIncrementMultiplier * slice.last(priceIncrements[:]) < priceLabelSpacing
		{
			priceIncrementMultiplier *= 10
		}

		for pixelPriceIncrement * priceIncrementMultiplier * priceIncrements[priceIncrementIndex] < priceLabelSpacing
		{
			priceIncrementIndex += 1
		}

		priceIncrement := i32(priceIncrementMultiplier * priceIncrements[priceIncrementIndex])

		screenTopPrice := i32(Price_FromPixelY(vp.camera.y, vp.scaleData) / MIN_DECIMAL)
		screenBottomPrice := i32(Price_FromPixelY(vp.camera.y + vp.rect.height, vp.scaleData) / MIN_DECIMAL)

		// Round to the nearest increment (which lies above the screen border)
		currentPrice := screenTopPrice + priceIncrement - screenTopPrice % priceIncrement
		lastPrice := i32(screenBottomPrice - priceIncrement)

		for currentPrice > lastPrice
		{
			append(&priceLabels, PriceLabel{})
			label := &priceLabels[len(priceLabels) - 1]

			label.price = f32(currentPrice) / 100
			fmt.bprintf(label.textBuffer[:], "%.2f\x00", label.price)
			label.width = rl.MeasureTextEx(labelFont, cstring(&label.textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2

			significantIncrementTest := label.price / (f32(priceIncrementMultiplier) / 10)

			if significantIncrementTest == f32(i32(significantIncrementTest))
			{
				label.color = rl.Color{255, 255, 255, MAX_ALPHA}
			}
			else
			{
				label.color = rl.Color{255, 255, 255, MIN_ALPHA}
			}

			currentPrice -= priceIncrement
		}
	}

	// Draw Price Lines
	for label in priceLabels
	{
		pixelY := Price_ToPixelY(label.price, vp.scaleData) - vp.camera.y

		rl.DrawRectangleRec(rl.Rectangle{0, pixelY, vp.rect.width - label.width, 1}, label.color)
	}

	// Generate timestamp labels
	// Draw lines before candles are drawn
	// Draw labels after candles are drawn
	pixelTimestampIncrement := Timestamp_FromPixelX(1, vp.scaleData)

	TimestampLabel :: struct
	{
		timestamp : i32,
		textBuffer : [8]u8,
		color : rl.Color,
	}

	timestampLabels : [dynamic]TimestampLabel
	reserve(&timestampLabels, 32)

	DAY_TIMESTAMP :: 2880
	DAY31_TIMESTAMP :: 75_000

	switch pixelTimestampIncrement
	{
		case 0 ..< DAY_TIMESTAMP: // Times + Days
		{
			INCREMENT_COUNT :: 9
			incrementRequirements : [INCREMENT_COUNT]i32 = \
			{ \
				0, \
				DAY_TIMESTAMP / 2880, \
				DAY_TIMESTAMP / 576, \
				DAY_TIMESTAMP / 192, \
				DAY_TIMESTAMP / 96, \
				DAY_TIMESTAMP / 48, \
				DAY_TIMESTAMP / 16, \
				DAY_TIMESTAMP / 8, \
				DAY_TIMESTAMP / 4 \
			}

			increments : [INCREMENT_COUNT + 1]i32 = \
			{ \
				60, \
				300, \
				900, \
				1800, \
				3600, \
				10_800, \
				21_600, \
				43_200, \
				86_400, \
				86_400 \
			} // Extra 86_400 to conveniently handle [index + 1] query

			incrementIndex : int = INCREMENT_COUNT - 1

			for pixelTimestampIncrement < incrementRequirements[incrementIndex]
			{
				incrementIndex -= 1
			}

			// Round the current timestamp
			// As these are ints, the decimal value will be lost in the division, leading to a perfect increment
			currentTimestamp := (vp.cameraTimestamp / increments[incrementIndex]) * increments[incrementIndex]

			prevTimestamp : i32 = 0

			for prevTimestamp < vp.cameraEndTimestamp
			{
				append(&timestampLabels, TimestampLabel{})

				label := &timestampLabels[len(timestampLabels) - 1]

				label.color = rl.WHITE

				currentDate := Timestamp_ToDayMonthYear(currentTimestamp)

				label.timestamp = currentTimestamp

				dayTimestamp := currentTimestamp % DAY

				// Setting label contents
				if dayTimestamp == 0 // Days
				{
					if currentDate.day == 1 // Months
					{
						switch currentDate.month
						{
							case 2: fmt.bprintf(label.textBuffer[:], "Feb\x00")
							case 3: fmt.bprintf(label.textBuffer[:], "Mar\x00")
							case 4: fmt.bprintf(label.textBuffer[:], "Apr\x00")
							case 5: fmt.bprintf(label.textBuffer[:], "May\x00")
							case 6: fmt.bprintf(label.textBuffer[:], "Jun\x00")
							case 7: fmt.bprintf(label.textBuffer[:], "Jul\x00")
							case 8: fmt.bprintf(label.textBuffer[:], "Aug\x00")
							case 9: fmt.bprintf(label.textBuffer[:], "Sep\x00")
							case 10: fmt.bprintf(label.textBuffer[:], "Oct\x00")
							case 11: fmt.bprintf(label.textBuffer[:], "Nov\x00")
							case 12: fmt.bprintf(label.textBuffer[:], "Dec\x00")
							case: fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.year)
						}
					}
					else
					{
						fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.day)
					}
				}
				else
				{
					hours   := dayTimestamp / 3600
					minutes := dayTimestamp % 3600 / 60
					fmt.bprintf(label.textBuffer[:], "%i:%2i", hours, minutes)
				}

				// Fading out smaller increments
				if incrementIndex == INCREMENT_COUNT - 1
				{
					if currentDate.day != 1
					{
						label.color.a = u8((1 - f32(pixelTimestampIncrement) / DAY_TIMESTAMP) * ALPHA_RANGE) + MIN_ALPHA
					}
					else
					{
						label.color.a = MAX_ALPHA
					}
				}
				else // Fading out days in favour of months
				{
					if currentTimestamp % increments[incrementIndex + 1] != 0 &&
					   incrementRequirements[incrementIndex] != incrementRequirements[incrementIndex + 1]
					{
						label.color.a = u8((1 - (f32(pixelTimestampIncrement) - f32(incrementRequirements[incrementIndex])) / (f32(incrementRequirements[incrementIndex + 1]) - f32(incrementRequirements[incrementIndex]))) * ALPHA_RANGE) + MIN_ALPHA
					}
					else
					{
						label.color.a = MAX_ALPHA
					}
				}

				prevTimestamp = currentTimestamp

				currentTimestamp += increments[incrementIndex]
			}
		}
		case:
		{
			currentDate := Timestamp_ToDayMonthYear(vp.cameraTimestamp)
			currentDate.day = 1

			INCREMENT_COUNT :: 4

			// Values for detemining how many months to increment for each label
			incrementRequirements : [INCREMENT_COUNT]i32 = {0, DAY31_TIMESTAMP, DAY31_TIMESTAMP * 3, DAY31_TIMESTAMP * 6}
			increments : [INCREMENT_COUNT + 1]int = {1, 3, 6, 12, 12} // Extra 12 to conveniently handle [index + 1] query

			incrementIndex : int = INCREMENT_COUNT - 1

			for pixelTimestampIncrement < incrementRequirements[incrementIndex]
			{
				incrementIndex -= 1
			}

			// Get each month within the current increment steps, but make sure that the increments are offset from January
			// This ensures year numbers are included
			monthOffset := currentDate.month % increments[incrementIndex]

			if monthOffset == 0
			{
				monthOffset = increments[incrementIndex]
			}

			currentDate.month += 1 - monthOffset

			for currentDate.month < 1
			{
				currentDate.year -= 1
				currentDate.month += 12
			}

			prevTimestamp : i32 = 0
			currentTimestamp := DayMonthYear_ToTimestamp(currentDate)

			for prevTimestamp < vp.cameraEndTimestamp
			{
				append(&timestampLabels, TimestampLabel{})

				label := &timestampLabels[len(timestampLabels) - 1]

				label.color = rl.WHITE

				if currentDate.month % increments[incrementIndex + 1] != 1
				{
					if incrementRequirements[incrementIndex] != incrementRequirements[incrementIndex + 1]
					{
						label.color.a = u8((1 - (f32(pixelTimestampIncrement) - f32(incrementRequirements[incrementIndex])) / (f32(incrementRequirements[incrementIndex + 1]) - f32(incrementRequirements[incrementIndex]))) * ALPHA_RANGE) + MIN_ALPHA
					}
					else
					{
						label.color.a = MAX_ALPHA
					}
				}
				else
				{
					label.color.a = MAX_ALPHA
				}

				label.timestamp = currentTimestamp

				switch currentDate.month
				{
					case 2: fmt.bprintf(label.textBuffer[:], "Feb\x00")
					case 3: fmt.bprintf(label.textBuffer[:], "Mar\x00")
					case 4: fmt.bprintf(label.textBuffer[:], "Apr\x00")
					case 5: fmt.bprintf(label.textBuffer[:], "May\x00")
					case 6: fmt.bprintf(label.textBuffer[:], "Jun\x00")
					case 7: fmt.bprintf(label.textBuffer[:], "Jul\x00")
					case 8: fmt.bprintf(label.textBuffer[:], "Aug\x00")
					case 9: fmt.bprintf(label.textBuffer[:], "Sep\x00")
					case 10: fmt.bprintf(label.textBuffer[:], "Oct\x00")
					case 11: fmt.bprintf(label.textBuffer[:], "Nov\x00")
					case 12: fmt.bprintf(label.textBuffer[:], "Dec\x00")
					case: fmt.bprintf(label.textBuffer[:], "%i\x00", currentDate.year)
				}

				prevTimestamp = currentTimestamp
				currentDate.month += increments[incrementIndex]

				if currentDate.month > 12
				{
					currentDate.year += 1
					currentDate.month -= 12
				}

				currentTimestamp = DayMonthYear_ToTimestamp(currentDate)
			}
		}
	}

	// Draw Time Axis Lines
	timeAxisLineHeight := vp.rect.height - labelHeight

	for label in timestampLabels
	{
		pixelX := Timestamp_ToPixelX(label.timestamp, vp.scaleData) - vp.camera.x

		rl.DrawRectangleRec(rl.Rectangle{pixelX, 0, 1, timeAxisLineHeight}, label.color)
	}

	if .DRAW_DAY_OF_WEEK in vp.flags do Viewport_Draw_DayOfWeek(vp, chart)
	if .DRAW_SESSIONS in vp.flags do Viewport_Draw_Sessions(vp, chart)
	if .DRAW_HTF_OUTLINES in vp.flags do Viewport_Draw_HTFOutlines(vp, chart)

	// [0] = green, [1] = red
	candleColors := [2]rl.Color{{0, 255, 0, 255}, {255, 0, 0, 255}}

	// Draw Candles
	for candle, i in vp.visibleCandles
	{
		xPos := CandleList_IndexToPixelX(chart.candles[vp.zoomIndex], i32(i) + vp.visibleCandlesStartIndex, vp.scaleData) - vp.camera.x
		candleWidth := CandleList_IndexToWidth(chart.candles[vp.zoomIndex], i32(i) + vp.visibleCandlesStartIndex, vp.scaleData)

		bodyPosY := Price_ToPixelY(math.max(candle.open, candle.close), vp.scaleData)
		bodyHeight := math.max(Price_ToPixelY(math.min(candle.open, candle.close), vp.scaleData) - bodyPosY, 1)

		wickPosY := Price_ToPixelY(candle.high, vp.scaleData)
		wickHeight := Price_ToPixelY(candle.low, vp.scaleData) - wickPosY

		rl.DrawRectangleRec(rl.Rectangle{xPos, bodyPosY - vp.camera.y, candleWidth, bodyHeight}, candleColors[int(candle.close <= candle.open)]) // Body
		rl.DrawRectangleRec(rl.Rectangle{xPos + f32(candleWidth) / 2 - 0.5, wickPosY - vp.camera.y, 1, wickHeight}, candleColors[int(candle.close <= candle.open)]) // Wick
	}

	// Draw Highs/Lows
	prevHighlow := vp.highlowsChris[0]
	prevPosX := Timestamp_ToPixelX(vp.highlowsChris[0].timestamp, vp.scaleData)

	for highlow in vp.highlowsChris[1:]
	{
		posX := Timestamp_ToPixelX(highlow.timestamp, vp.scaleData)
		
		if posX > vp.camera.x && prevPosX < vp.camera.x + vp.rect.width
		{
			start := rl.Vector2{prevPosX - vp.camera.x, Price_ToPixelY(prevHighlow.price, vp.scaleData) - vp.camera.y}
			end := rl.Vector2{posX - vp.camera.x, Price_ToPixelY(highlow.price, vp.scaleData) - vp.camera.y}
			rl.DrawLineV(start, end, rl.WHITE)
		}

		prevHighlow = highlow
		prevPosX = posX
	}

	if .DRAW_CVD in vp.flags do Viewport_Draw_CVD(vp, chart)
	if .DRAW_PREV_DAY_VPS in vp.flags do Viewport_Draw_PDVPs(vp, chart)
	if .DRAW_PREV_WEEK_VPS in vp.flags do Viewport_Draw_PWVPs(vp, chart)
	if .DRAW_CLOSE_LEVELS in vp.flags do Viewport_Draw_CloseLevels(vp)

	for selection in vp.selections
	{
		if Selection_IsOverlapping(selection, vp.camera.x, vp.camera.y, vp.rect.width, vp.rect.height, vp.scaleData)
		{
			Selection_Draw(selection, vp.camera.x, vp.camera.y, vp.scaleData)
		}
	}

	if vp.hoveredSelection != nil
	{
		posX := Timestamp_ToPixelX(vp.hoveredSelection.startTimestamp, vp.scaleData)
		posY := Price_ToPixelY(vp.hoveredSelection.high, vp.scaleData)
		width := Timestamp_ToPixelX(vp.hoveredSelection.endTimestamp, vp.scaleData) - posX
		height := Price_ToPixelY(vp.hoveredSelection.low, vp.scaleData) - posY
		rl.DrawRectangleLinesEx(rl.Rectangle{posX - vp.camera.x, posY - vp.camera.y, width, height}, 1, {255, 255, 255, 127})
	}

	if vp.currentSelection != nil
	{
		Selection_DrawHandles(vp.currentSelection^, vp.camera.x, vp.camera.y, vp.scaleData)
	}

	// Draw Crosshair
	{
		mouseY := f32(rl.GetMouseY())

		crosshairColor := rl.WHITE
		crosshairColor.a = 127

		for i : f32 = 0; i < vp.rect.width; i += 3
		{
			rl.DrawPixelV(rl.Vector2{i, mouseY}, crosshairColor)
		}

		posX : f32 = CandleList_IndexToPixelX(chart.candles[vp.zoomIndex], vp.cursorCandleIndex, vp.scaleData) - vp.camera.x
		candleWidth : f32 = CandleList_IndexToWidth(chart.candles[vp.zoomIndex], vp.cursorCandleIndex, vp.scaleData)

		for i : f32 = 0; i < vp.rect.height; i += 3
		{
			rl.DrawPixelV(rl.Vector2{posX + candleWidth / 2 - 0.5, i}, crosshairColor)
		}
	}

	// Draw current price line
	lastCandle := slice.last(chart.candles[vp.zoomIndex].candles[:])
	priceY := Price_ToPixelY(lastCandle.close, vp.scaleData) - vp.camera.y - f32(i32(lastCandle.close < lastCandle.open))
	priceColor := candleColors[int(lastCandle.close < lastCandle.open)]

	for i : f32 = 0; i < vp.rect.width; i += 3
	{
		rl.DrawPixelV(rl.Vector2{i, priceY}, priceColor)
	}

	textBuffer : [64]u8 = ---

	textRect : rl.Vector2 = ---
	labelPosX : f32 = ---
	labelPosY : f32 = ---

	// Highest Candle
	if vp.cursorCandleIndex != vp.highestCandleIndex ||
	   vp.cursorSnapPrice != vp.highestCandle.high
    {
		fmt.bprintf(textBuffer[:], "%.2f\x00", vp.highestCandle.high)
		textRect = rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0)
		candleCenterOffset := f32(CandleList_IndexToWidth(chart.candles[vp.zoomIndex], vp.highestCandleIndex, vp.scaleData)) / 2 - 0.5
		
		labelPosX = f32(CandleList_IndexToPixelX(chart.candles[vp.zoomIndex], vp.highestCandleIndex, vp.scaleData) - vp.camera.x) - textRect.x / 2 + candleCenterOffset
		labelPosX = math.clamp(labelPosX, 2, f32(vp.rect.width) - textRect.x - 2)

		labelPosY = f32(Price_ToPixelY(vp.highestCandle.high, vp.scaleData) - vp.camera.y) - textRect.y - VERTICAL_LABEL_PADDING

		rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {labelPosX, labelPosY}, LABEL_FONT_SIZE, 0, rl.WHITE)
    }

	// Lowest Candle
	if vp.cursorCandleIndex != vp.lowestCandleIndex ||
	   vp.cursorSnapPrice != vp.lowestCandle.low
    {
		fmt.bprintf(textBuffer[:], "%.2f\x00", vp.lowestCandle.low)
		textRect = rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0)
		candleCenterOffset := f32(CandleList_IndexToWidth(chart.candles[vp.zoomIndex], vp.lowestCandleIndex, vp.scaleData)) / 2 - 0.5
		labelPosX = f32(CandleList_IndexToPixelX(chart.candles[vp.zoomIndex], vp.lowestCandleIndex, vp.scaleData) - vp.camera.x) - textRect.x / 2 + candleCenterOffset
		labelPosX = math.clamp(labelPosX, 2, f32(vp.rect.width) - textRect.x - 2)

		labelPosY = f32(Price_ToPixelY(vp.lowestCandle.low, vp.scaleData) - vp.camera.y) + VERTICAL_LABEL_PADDING

		rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {labelPosX, labelPosY}, LABEL_FONT_SIZE, 0, rl.WHITE)
	}

	// "Downloading" text
	if chart.isDownloading
	{
		lastCandleIndex := i32(len(chart.candles[vp.zoomIndex].candles)) - 1

		// If last candle is visible
		if lastCandleIndex == vp.visibleCandlesStartIndex + i32(len(vp.visibleCandles)) - 1
		{
			posX := f32(Timestamp_ToPixelX(DayMonthYear_ToTimestamp(chart.dateToDownload), vp.scaleData) - vp.camera.x) + 2
			posY := f32(Price_ToPixelY(chart.candles[vp.zoomIndex].candles[lastCandleIndex].close, vp.scaleData) - vp.camera.y) - rl.MeasureTextEx(labelFont, "W\x00", LABEL_FONT_SIZE, 0).y / 2
			fmt.bprint(textBuffer[:], "Downloading\x00")
			rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {posX, posY}, LABEL_FONT_SIZE, 0, rl.WHITE)
		}
	}

	labelBackground := rl.Color{0, 0, 0, 127}

	if vp.isCursorSnapped
	{
		fmt.bprintf(textBuffer[:], "%.2f\x00", vp.cursorSnapPrice)

		width := rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2

		posX := f32(CandleList_IndexToPixelX(chart.candles[vp.zoomIndex], vp.cursorCandleIndex, vp.scaleData) - vp.camera.x) - width
		posY := f32(Price_ToPixelY(vp.cursorSnapPrice, vp.scaleData) - vp.camera.y) - f32(labelHeight) / 2

		if posX + HORIZONTAL_LABEL_PADDING < 0
		{
			posX += width + f32(CandleList_IndexToWidth(chart.candles[vp.zoomIndex], vp.cursorCandleIndex, vp.scaleData))
		}

		rl.DrawRectangleRounded({posX, posY, width, f32(labelHeight)}, 0.5, 10, labelBackground)
		rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {posX + HORIZONTAL_LABEL_PADDING, posY + VERTICAL_LABEL_PADDING}, LABEL_FONT_SIZE, 0, rl.WHITE)
	}
	else
	{
		fmt.bprintf(textBuffer[:], "%.2f\x00", Price_FromPixelY(f32(rl.GetMouseY()) + vp.camera.y, vp.scaleData))

		width := rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2

		posX := f32(rl.GetMouseX()) - width
		posY := f32(rl.GetMouseY()) - f32(labelHeight) / 2

		if posX + HORIZONTAL_LABEL_PADDING < 0
		{
			posX += width + f32(rl.GetMouseX())
		}

		rl.DrawRectangleRounded({posX, posY, width, f32(labelHeight)}, 0.5, 10, labelBackground)
		rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {posX + HORIZONTAL_LABEL_PADDING, posY + VERTICAL_LABEL_PADDING}, LABEL_FONT_SIZE, 0, rl.WHITE)
	}
	
	// FPS
	fmt.bprintf(textBuffer[:], "%i\x00", rl.GetFPS())
	rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {vp.rect.x, vp.rect.y}, LABEL_FONT_SIZE, 0, rl.WHITE)

	// Zoom Index
	fmt.bprint(textBuffer[:], vp.zoomIndex, "\x00")
	rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {vp.rect.x, vp.rect.y + LABEL_FONT_SIZE}, LABEL_FONT_SIZE, 0, rl.WHITE)

	// Draw Price Labels
	for i in 0 ..< len(priceLabels)
	{
		pixelY := Price_ToPixelY(priceLabels[i].price, vp.scaleData) - vp.camera.y

		labelPosX = f32(vp.rect.width) - f32(priceLabels[i].width)
		labelPosY = f32(pixelY) - f32(labelHeight) / 2

		rl.DrawRectangleRounded({labelPosX, labelPosY, f32(priceLabels[i].width), f32(labelHeight)}, 0.5, 10, labelBackground)
		rl.DrawTextEx(labelFont, cstring(&priceLabels[i].textBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, LABEL_FONT_SIZE, 0, rl.WHITE)
	}

	// Draw current price label
	{
		fmt.bprintf(textBuffer[:], "%.2f\x00", lastCandle.close)

		labelWidth := rl.MeasureTextEx(labelFont, cstring(&textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
		labelPosX = f32(vp.rect.width) - labelWidth
		labelPosY = f32(priceY) - f32(labelHeight) / 2

		rl.DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, priceColor)
		rl.DrawTextEx(labelFont, cstring(&textBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, LABEL_FONT_SIZE, 0, rl.WHITE)
	}

	// Draw Timestamp Labels
	for i in 0 ..< len(timestampLabels)
	{
		pixelX := Timestamp_ToPixelX(timestampLabels[i].timestamp, vp.scaleData) - vp.camera.x

		labelWidth := rl.MeasureTextEx(labelFont, cstring(&timestampLabels[i].textBuffer[0]), LABEL_FONT_SIZE, 0).x + HORIZONTAL_LABEL_PADDING * 2
		labelPosX = f32(pixelX) - labelWidth / 2
		labelPosY = f32(vp.rect.height) - f32(labelHeight)

		labelColor := timestampLabels[i].color
		labelColor.a = 255

		rl.DrawRectangleRounded({labelPosX, labelPosY, labelWidth, f32(labelHeight)}, 0.5, 10, labelBackground)
		rl.DrawTextEx(labelFont, cstring(&timestampLabels[i].textBuffer[0]), {labelPosX + HORIZONTAL_LABEL_PADDING, labelPosY + VERTICAL_LABEL_PADDING}, LABEL_FONT_SIZE, 0, labelColor)
	}

	Viewport_Draw_CursorTimestampLabel(vp)
	Viewport_Draw_Sidebar(vp, chart)

	HEIGHT :: 800
	// for result, x in vp.fibResults005.data
	// {
	// 	rl.DrawRectangle(i32(x), i32(vp.rect.height) - result, 1, result, rl.PINK)
	// }

	// for result, x in vp.fibResults01.data
	// {
	// 	rl.DrawRectangle(i32(x), i32(vp.rect.height) - result, 1, result, rl.GREEN)
	// }

	// for result, x in vp.fibResults02.data
	// {
	// 	rl.DrawRectangle(i32(x), i32(vp.rect.height) - result, 1, result, rl.RED)
	// }

	// for result, x in vp.fibResults05.data
	// {
	// 	rl.DrawRectangle(i32(x), i32(vp.rect.height) - result, 1, result, rl.YELLOW)
	// }

	// rl.DrawRectangle(i32(0.382 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.GREEN)
	// rl.DrawRectangle(i32(0.618 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.YELLOW)
	// rl.DrawRectangle(i32(0.7 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.YELLOW)
	// rl.DrawRectangle(i32(1 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.GRAY)
	// rl.DrawRectangle(i32(1.272 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.RED)
	// rl.DrawRectangle(i32(1.3414 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.GREEN)
	// rl.DrawRectangle(i32(1.618 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.YELLOW)
	// rl.DrawRectangle(i32(1.688 / vp.fibResults01.increment), i32(vp.rect.height) - HEIGHT, 1, HEIGHT, rl.ORANGE)
	
	clear(&timestampLabels)
}

Viewport_ToggleLogScale :: proc(vp : ^Viewport, chart : Chart)
{
	priceUpper : f32 = 0
	priceLower : f32 = 10000000

	// Rescale Candles
	for candle in vp.visibleCandles
	{
		priceUpper = math.max(priceUpper, candle.high)
		priceLower = math.min(priceLower, candle.low)
	}

	priceUpper = math.min(priceUpper, vp.cameraTopPrice)
	priceLower = math.max(priceLower, vp.cameraBottomPrice)

	prePixelUpper : f32 = Price_ToPixelY(priceUpper, vp.scaleData)
	prePixelLower : f32 = Price_ToPixelY(priceLower, vp.scaleData)

	pixelOffset : f32 = prePixelUpper - vp.camera.y

	vp.scaleData.logScale = !vp.scaleData.logScale

	postPixelUpper : f32 = Price_ToPixelY(priceUpper, vp.scaleData)
	postPixelLower : f32 = Price_ToPixelY(priceLower, vp.scaleData)

	difference : f64 = f64(postPixelLower - postPixelUpper) / f64(prePixelLower - prePixelUpper)

	vp.unzoomedVerticalScale *= difference
	vp.scaleData.verticalScale *= difference

	vp.camera.y = Price_ToPixelY(priceUpper, vp.scaleData) - pixelOffset
}

Viewport_UpdateTimeframe :: proc(vp : ^Viewport, chart : Chart)
{
	if .LOCK_TIMEFRAME not_in vp.flags
	{
		vp.zoomIndex = Timeframe(TIMEFRAME_COUNT - 1)

		for int(vp.zoomIndex) > 0 &&
		    CandleList_IndexToWidth(chart.candles[vp.zoomIndex - Timeframe(1)], 0, vp.scaleData) > ZOOM_THRESHOLD
		{
			vp.zoomIndex -= Timeframe(1)
		}
	}
}
