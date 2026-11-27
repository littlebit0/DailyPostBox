import assert from "node:assert/strict";
import test from "node:test";
import { parseCalendarInvite } from "../src/mail/calendarInvite.js";

const wrap = (event: string, method = "REQUEST") =>
  `BEGIN:VCALENDAR\r\nMETHOD:${method}\r\nBEGIN:VEVENT\r\n${event}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;

test("parses UTC event with folded lines and escapes", () => {
  const invite = parseCalendarInvite(
    wrap(
      "SUMMARY:Weekly\\, sync\r\n with team\r\nDTSTART:20261201T090000Z\r\nDTEND:20261201T100000Z\r\nLOCATION:Room 1\\nFloor 2\r\nORGANIZER;CN=\"Kim, A\":mailto:a@example.test"
    )
  );
  assert.deepEqual(invite, {
    method: "REQUEST",
    summary: "Weekly, syncwith team",
    start: "2026-12-01T09:00:00Z",
    end: "2026-12-01T10:00:00Z",
    allDay: false,
    location: "Room 1\nFloor 2",
    organizer: "Kim, A",
    recurring: false
  });
});

test("converts TZID times to UTC", () => {
  const invite = parseCalendarInvite(
    wrap("SUMMARY:x\r\nDTSTART;TZID=Asia/Seoul:20261201T090000\r\nDTEND;TZID=America/New_York:20261201T100000")
  );
  assert.equal(invite?.start, "2026-12-01T00:00:00Z");
  assert.equal(invite?.end, "2026-12-01T15:00:00Z");
});

test("handles DST in TZID conversion", () => {
  const invite = parseCalendarInvite(
    wrap("SUMMARY:x\r\nDTSTART;TZID=America/New_York:20260701T090000")
  );
  assert.equal(invite?.start, "2026-07-01T13:00:00Z");
});

test("all-day, recurring, unknown zone, organizer fallback", () => {
  const allDay = parseCalendarInvite(
    wrap("SUMMARY:Holiday\r\nDTSTART;VALUE=DATE:20261225\r\nRRULE:FREQ=YEARLY\r\nORGANIZER:mailto:b@example.test")
  );
  assert.equal(allDay?.allDay, true);
  assert.equal(allDay?.start, "2026-12-25");
  assert.equal(allDay?.recurring, true);
  assert.equal(allDay?.organizer, "b@example.test");

  const unknown = parseCalendarInvite(wrap("DTSTART;TZID=Nowhere/Land:20261201T090000"));
  assert.equal(unknown?.start, "2026-12-01T09:00:00");
});

test("returns null for unusable input", () => {
  assert.equal(parseCalendarInvite("garbage"), null);
  assert.equal(parseCalendarInvite(wrap("SUMMARY:no start")), null);
  assert.equal(parseCalendarInvite(wrap("DTSTART:notadate")), null);
});

test("resolves DST gaps and overlaps per RFC 5545", () => {
  // Overlap: 02:30 occurs twice in Berlin; the first (earlier UTC) occurrence wins.
  const overlap = parseCalendarInvite(wrap("DTSTART;TZID=Europe/Berlin:20261025T023000"));
  assert.equal(overlap?.start, "2026-10-25T00:30:00Z");
  // Gap: 02:30 does not exist in New York; interpret with the offset before the gap.
  const gap = parseCalendarInvite(wrap("DTSTART;TZID=America/New_York:20260308T023000"));
  assert.equal(gap?.start, "2026-03-08T07:30:00Z");
});

test("derives end from DURATION when DTEND is absent", () => {
  const utc = parseCalendarInvite(wrap("DTSTART:20261201T090000Z\r\nDURATION:PT1H30M"));
  assert.equal(utc?.end, "2026-12-01T10:30:00Z");

  // Day durations are nominal: same wall-clock time across the DST change.
  const zoned = parseCalendarInvite(
    wrap("DTSTART;TZID=America/New_York:20261031T090000\r\nDURATION:P1DT1H")
  );
  assert.equal(zoned?.end, "2026-11-01T15:00:00Z");

  const floating = parseCalendarInvite(wrap("DTSTART:20261201T230000\r\nDURATION:PT2H"));
  assert.equal(floating?.end, "2026-12-02T01:00:00");

  const allDay = parseCalendarInvite(wrap("DTSTART;VALUE=DATE:20261231\r\nDURATION:P1W"));
  assert.equal(allDay?.end, "2027-01-07");

  const bad = parseCalendarInvite(wrap("DTSTART:20261201T090000Z\r\nDURATION:soon"));
  assert.equal(bad?.end, null);
});

test("ignores properties of nested components such as VALARM", () => {
  const invite = parseCalendarInvite(
    `BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:X\r\nBEGIN:STANDARD\r\nDTSTART:19701025T030000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nMETHOD:REQUEST\r\n` +
      "BEGIN:VEVENT\r\nDTSTART:20261201T090000Z\r\n" +
      "BEGIN:VALARM\r\nTRIGGER:-PT15M\r\nDURATION:PT5M\r\nREPEAT:2\r\nSUMMARY:Alarm\r\nDESCRIPTION:Reminder\r\nLOCATION:Nowhere\r\nEND:VALARM\r\n" +
      "SUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
  );
  assert.equal(invite?.start, "2026-12-01T09:00:00Z");
  assert.equal(invite?.end, null);
  assert.equal(invite?.summary, "Meeting");
  assert.equal(invite?.location, null);
  assert.equal(invite?.method, "REQUEST");
});

test("RDATE-only event counts as recurring", () => {
  const invite = parseCalendarInvite(
    wrap("SUMMARY:Series\r\nDTSTART:20261201T090000Z\r\nRDATE:20261208T090000Z,20261215T090000Z")
  );
  assert.equal(invite?.recurring, true);
});
