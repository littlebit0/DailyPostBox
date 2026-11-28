import assert from "node:assert/strict";
import test from "node:test";
import { decodeCalendarText, findCalendarPart } from "../src/mail/ImapReceiver.js";
import { parseCalendarInvite } from "../src/mail/calendarInvite.js";

test("calendar part is decoded with its declared charset", () => {
  const ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nSUMMARY:Réunion\r\nDTSTART:20261201T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
  const latin1 = Buffer.from(ics, "latin1");
  assert.equal(parseCalendarInvite(decodeCalendarText(latin1, "ISO-8859-1"))?.summary, "Réunion");
  assert.equal(decodeCalendarText(Buffer.from("é"), undefined), "é");
  assert.equal(decodeCalendarText(Buffer.from("é"), "x-unknown"), "é");
});

test("calendar discovery skips attached messages but keeps attached ics", () => {
  const structure = {
    type: "multipart/mixed",
    childNodes: [
      { type: "text/plain", part: "1" },
      {
        type: "message/rfc822",
        part: "2",
        disposition: "attachment",
        childNodes: [{ type: "text/calendar", part: "2.1" }]
      },
      { type: "text/calendar", part: "3", disposition: "attachment" }
    ]
  };
  assert.equal(findCalendarPart(structure as never)?.part, "3");
  assert.equal(findCalendarPart({ type: "multipart/mixed", childNodes: [structure.childNodes[1]] } as never), null);
});
