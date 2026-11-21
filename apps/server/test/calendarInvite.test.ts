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
