package main

DayMonthYear :: struct
{
    day : int,
    month : int,
    year : int,
}

DayMonthYear_ToTimestamp :: proc(date : DayMonthYear) -> i32
{
    timestamp : i32 = 0

	startYear := 2010

    for startYear < date.year
    {
		if startYear % 4 == 0
		{
            timestamp += 31_622_400
        }
        else
        {
            timestamp += 31_536_000
        }

        startYear += 1
    }

    for startMonth in 1 ..< date.month
    {
		switch startMonth
		{
			case 4, 6, 9, 11: timestamp += DAY * 30
			case 2: timestamp += startYear % 4 == 0 ? DAY * 29 : DAY * 28
			case: timestamp += DAY * 31
		}
    }

	timestamp += i32(date.day - 1) * DAY

    return timestamp
}

DayMonthYear_AddDays :: proc(date : DayMonthYear, days : int) -> DayMonthYear
{
    // 0 at the start to make this 1 indexed, and match incoming values
    months : [13]int = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

    date : DayMonthYear = {date.day + days, date.month, date.year}

    for date.day > months[date.month]
    {
        date.day -= months[date.month]
        date.month += 1

        if date.month > 12
        {
            date.month = 1
            date.year += 1
        }
    }

	return date
}