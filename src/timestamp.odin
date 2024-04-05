package main

// The number of seconds between 1970 and 2010
TIMESTAMP_2010 :: 1_262_304_000
DAY :: 86400

Timestamp_ToPixelX :: proc(timestamp : i32, scaleData : ScaleData) -> i32
{
	return i32(f64(timestamp) / (scaleData.horizontalScale * scaleData.zoom))
}

Timestamp_FromPixelX :: proc(pixelX : i32, scaleData : ScaleData) -> i32
{
	return i32(f64(pixelX) * scaleData.horizontalScale * scaleData.zoom)
}

Timestamp_ToDayMonthYear :: proc(timestamp : i32) -> DayMonthYear
{
    // TODO Investigate
	timestamp := timestamp // - TIMESTAMP_2010, likely related to the loading, may need this to be factored in in the historical data conversation

	date : DayMonthYear = {1, 1, 2010}

	for
	{
        // If divisible by 4, leap year
        yearLength : i32 = 31_536_000

        if date.year % 4 == 0
        {
            yearLength = 31_622_400 
        }

        if timestamp < yearLength
        {
            break
        }

        timestamp -= yearLength
        date.year += 1
	}

    // Months in milliseconds
    days28 :: DAY * 28
    days29 :: DAY * 29
    days30 :: DAY * 30
    days31 :: DAY * 31

    // 0 at start to make this 1 indexed to match incoming values
    months : [13]i32 = {0, days31, days28, days31, days30, days31, days30, days31, days31, days30, days31, days30, days31}

    // Leap year, set February to 29 days
    if date.year % 4 == 0
    {
        months[2] = days29
    }

    for timestamp >= months[date.month]
    {
        timestamp -= months[date.month]
        date.month += 1
    }

	date.day += int(timestamp) / DAY

	return date
}
