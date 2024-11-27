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

	positionSize : f32,
	
	isShort : bool,
}

Exit :: struct
{
	exit : f32,
	exitTimestamp : f32,
}

SampleStrategy_Run :: proc()
{
	
}
