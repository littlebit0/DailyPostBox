/// Preset wake times, in the device's local time zone.
DateTime snoozeTonight(DateTime now) =>
    DateTime(now.year, now.month, now.day, 18);

DateTime snoozeTomorrowMorning(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1, 9);

/// Next Monday 09:00 (a full week ahead when today is Monday).
DateTime snoozeNextWeek(DateTime now) {
  final days = (8 - now.weekday) % 7;
  return DateTime(now.year, now.month, now.day + (days == 0 ? 7 : days), 9);
}
