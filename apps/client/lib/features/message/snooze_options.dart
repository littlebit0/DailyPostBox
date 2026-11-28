import 'dart:async';

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

/// Runs [refresh] shortly after [wakeAt] so the woken message reappears even
/// when the user stays on the mailbox. shortcut: in-memory only, lost on app
/// restart (the next launch fetches the list anyway).
Timer scheduleSnoozeWakeRefresh(
  DateTime wakeAt,
  void Function() refresh, {
  DateTime? now,
}) {
  final delay = wakeAt.difference(now ?? DateTime.now());
  return Timer(
    (delay.isNegative ? Duration.zero : delay) + const Duration(seconds: 2),
    refresh,
  );
}
