import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/message/snooze_options.dart';

void main() {
  test('snooze presets', () {
    final wednesday = DateTime(2026, 11, 25, 14, 30);
    expect(snoozeTonight(wednesday), DateTime(2026, 11, 25, 18));
    expect(
      snoozeTomorrowMorning(DateTime(2026, 11, 30, 20)),
      DateTime(2026, 12, 1, 9),
    );
    expect(snoozeNextWeek(wednesday), DateTime(2026, 11, 30, 9));
    // Monday and Sunday both go to the following Monday.
    expect(
      snoozeNextWeek(DateTime(2026, 11, 23, 8)),
      DateTime(2026, 11, 30, 9),
    );
    expect(
      snoozeNextWeek(DateTime(2026, 11, 29, 8)),
      DateTime(2026, 11, 30, 9),
    );
  });

  testWidgets('wake refresh fires after wakeAt', (tester) async {
    var calls = 0;
    final now = DateTime(2026, 11, 25, 12);
    scheduleSnoozeWakeRefresh(
      now.add(const Duration(hours: 1)),
      () => calls++,
      now: now,
    );
    await tester.pump(const Duration(hours: 1));
    expect(calls, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
  });
}
