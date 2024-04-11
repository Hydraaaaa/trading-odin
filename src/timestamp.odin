package main

DayOfWeek :: enum
{
    MONDAY,
    TUESDAY,
    WEDNESDAY,
    THURSDAY,
    FRIDAY,
    SATURDAY,
    SUNDAY
}

// The number of seconds between 1970 and 2010
TIMESTAMP_2010 :: 1_262_304_000
DAY :: 86400
FOUR_YEARS :: DAY * 1461

// The number of days between 2010 and each month leading up to December 2014
MONTHLY_INCREMENTS : [48]i32 : \
{ \
	0, DAY * 31, DAY * 59, DAY * 90, DAY * 120, DAY * 151, DAY * 181, DAY * 212, DAY * 243, DAY * 273, DAY * 304, DAY * 334, \
    DAY * 365, DAY * 396, DAY * 424, DAY * 455, DAY * 485, DAY * 516, DAY * 546, DAY * 577, DAY * 608, DAY * 638, DAY * 669, DAY * 699, \
    DAY * 730, DAY * 761, DAY * 790, DAY * 821, DAY * 851, DAY * 882, DAY * 912, DAY * 943, DAY * 974, DAY * 1004, DAY * 1035, DAY * 1065, \
    DAY * 1096, DAY * 1127, DAY * 1155, DAY * 1186, DAY * 1216, DAY * 1247, DAY * 1277, DAY * 1308, DAY * 1339, DAY * 1369, DAY * 1400, DAY * 1430, \
}

DAYS_PER_MONTH : [48]int = \
{ \
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, \
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, \
    31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, \
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, \
}

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
	timestamp := timestamp

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

Timestamp_ToDayOfWeek :: proc(timestamp : i32) -> DayOfWeek
{
    return DayOfWeek((timestamp + DAY * 4) / DAY % 7)
}